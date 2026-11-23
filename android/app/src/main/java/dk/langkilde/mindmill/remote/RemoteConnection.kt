package dk.langkilde.mindmill.remote

import dk.langkilde.mindmill.store.PairingStore
import dk.langkilde.mindmill.store.StoredPairing
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonObject
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.util.concurrent.TimeUnit
import kotlin.coroutines.coroutineContext

data class Scope(val id: String, val title: String)

data class HelloInfo(
    val name: String,
    val version: Int,
    val brain: String,
    val scope: String?,
    val scopes: List<Scope>,
    val sections: List<String>,
) {
    companion object {
        fun parse(o: JsonObject) = HelloInfo(
            name = o.string("name") ?: "Mac",
            version = o.int("version") ?: 1,
            brain = o.string("brain") ?: "Claude",
            scope = o.string("scope"),
            scopes = o.objects("scopes").mapNotNull { s -> s.text("id")?.let { Scope(it, s.string("title") ?: it) } },
            sections = o.strings("sections"),
        )
    }
}

/**
 * The one WebSocket to the Mac: tries the paired hosts in order, says hello with the device token, and reconnects
 * with backoff when the socket drops. [ConnectionMachine] decides what to show and how long to wait.
 */
class RemoteConnection(private val store: PairingStore, private val scope: CoroutineScope) {
    val rpc = RpcChannel()

    private val _state = MutableStateFlow<ConnectionState>(
        store.loadPairing()?.let { ConnectionState.Connecting(it.macName, null, 0, false) } ?: ConnectionState.NotPaired,
    )
    val state: StateFlow<ConnectionState> = _state

    private var loop: Job? = null
    @Volatile private var link: Link? = null
    private val wake = Channel<Unit>(Channel.CONFLATED)
    private var cachedClient: Pair<String, OkHttpClient>? = null
    private var machine: ConnectionMachine? = null

    /** False while Android says there is no network at all; set by the app's network callback. */
    @Volatile var networkAvailable = true
        private set

    val hello: HelloInfo? get() = (state.value as? ConnectionState.Connected)?.hello

    val pairedMacName: String? get() = machine?.macName ?: store.loadPairing()?.macName

    fun start() {
        if (loop?.isActive == true) return
        val pairing = store.loadPairing() ?: run { _state.value = ConnectionState.NotPaired; return }
        loop = scope.launch { runLoop(pairing) }
    }

    fun stop() {
        loop?.cancel()
        loop = null
        closeLink()
    }

    /** Try again now instead of waiting out the backoff. Does nothing while connected. */
    fun retryNow() {
        when (state.value) {
            is ConnectionState.Unauthorized, is ConnectionState.Connected -> return
            else -> if (loop?.isActive != true) start() else wake.trySend(Unit)
        }
    }

    /** The app came to the foreground: start the backoff over and try now. */
    fun onForeground() {
        machine?.reset()
        retryNow()
        if (state.value is ConnectionState.Connected) scope.launch { checkAlive() }
    }

    fun onNetworkChanged(available: Boolean) {
        networkAvailable = available
        if (!available) return
        machine?.reset()
        if (state.value is ConnectionState.Connected) scope.launch { checkAlive() } else retryNow()
    }

    /** After a network change the socket may be dead without knowing it: ask, and drop it if the Mac doesn't answer. */
    private suspend fun checkAlive() {
        val l = link ?: return
        try {
            rpc.call("state", timeoutMs = 5_000)
        } catch (e: RemoteException) {
            if (link === l && e.code != ErrorCodes.UNKNOWN_METHOD) closeLink()
        }
    }

    /** Waits up to [timeoutMs] for a connection; false when there is none by then. */
    suspend fun awaitConnected(timeoutMs: Long): Boolean {
        if (state.value is ConnectionState.Connected && rpc.isOpen) return true
        retryNow()
        return withTimeoutOrNull(timeoutMs) { state.first { it is ConnectionState.Connected || it is ConnectionState.NotPaired } }
            ?.let { it is ConnectionState.Connected } ?: false
    }

    fun forget() {
        stop()
        store.clearPairing()
        machine = null
        _state.value = ConnectionState.NotPaired
    }

    suspend fun refreshState() {
        val current = state.value as? ConnectionState.Connected ?: return
        val info = HelloInfo.parse(rpc.call("state"))
        _state.value = current.copy(hello = info)
    }

    /** Pairs with the code shown on the Mac, stores what's needed to come back, and connects. */
    suspend fun pair(invite: PairingInvite, code: String, deviceName: String): StoredPairing {
        stop()
        val problems = mutableListOf<ConnectionProblem>()
        val opened = openFirst(invite.hosts, invite.port, invite.fingerprint, problems, report = null)
            ?: throw PairingFailed(ConnectionProblem.mostTelling(problems) ?: ConnectionProblem(ConnectionProblem.Kind.TIMEOUT), invite.name)
        try {
            val r = rpc.call("pair", jsonOf("code" to code.trim(), "name" to deviceName), 15_000)
            val token = r.string("token")?.takeIf { it.isNotEmpty() }
                ?: throw RemoteException(ErrorCodes.FAILED, "The Mac didn't send a device token.")
            val p = StoredPairing(invite.name, invite.hosts, invite.port, invite.fingerprint, token, opened.second)
            store.savePairing(p)
            return p
        } finally {
            closeLink()
            if (store.loadPairing() != null) start()
        }
    }

    private suspend fun runLoop(initial: StoredPairing) {
        var pairing = initial
        val m = machine?.takeIf { it.macName == pairing.macName } ?: ConnectionMachine(pairing.macName).also { machine = it }
        while (coroutineContext.isActive) {
            val problem: ConnectionProblem
            if (!networkAvailable) {
                problem = ConnectionProblem(ConnectionProblem.Kind.NO_NETWORK)
            } else {
                _state.value = m.trying(pairing.lastHost)
                val problems = mutableListOf<ConnectionProblem>()
                val opened = openFirst(pairing.orderedHosts, pairing.port, pairing.fingerprint, problems) { host -> _state.value = m.trying(host) }
                if (opened != null) {
                    val (l, host) = opened
                    try {
                        val hello = rpc.call("hello", jsonOf("token" to pairing.token), 10_000)
                        if (host != pairing.lastHost) {
                            pairing = pairing.copy(lastHost = host)
                            store.savePairing(pairing)
                        }
                        _state.value = m.connected(host, HelloInfo.parse(hello))
                        l.closed.await()
                        problems += ConnectionProblem(ConnectionProblem.Kind.DROPPED)
                    } catch (e: RemoteException) {
                        if (e.isUnauthorized) {
                            closeLink()
                            _state.value = ConnectionState.Unauthorized(
                                "${pairing.macName} doesn't know this phone any more. Pair again to connect.",
                            )
                            return
                        }
                        problems += ConnectionProblem(ConnectionProblem.Kind.OTHER, e.userMessage())
                    }
                }
                problem = if (opened != null) problems.last() else ConnectionProblem.mostTelling(problems)
                    ?: ConnectionProblem(ConnectionProblem.Kind.TIMEOUT)
            }
            closeLink()
            val (st, delay) = m.failed(problem, System.currentTimeMillis())
            _state.value = st
            withTimeoutOrNull(delay) { wake.receive() }
        }
    }

    private suspend fun openFirst(
        hosts: List<String>, port: Int, fingerprint: String, problems: MutableList<ConnectionProblem>,
        report: ((String) -> Unit)?,
    ): Pair<Link, String>? {
        val client = clientFor(fingerprint) ?: run {
            problems += ConnectionProblem(ConnectionProblem.Kind.CERTIFICATE)
            return null
        }
        for (host in hosts) {
            report?.invoke(host)
            val l = Link()
            link = l
            val url = "wss://${if (':' in host) "[$host]" else host}:$port/"
            l.socket = client.newWebSocket(Request.Builder().url(url).build(), l)
            val ok = withTimeoutOrNull(4_000) { runCatching { l.opened.await() }.isSuccess } ?: false
            if (ok) {
                rpc.sender = { text -> l.socket?.send(text) ?: false }
                rpc.binarySender = { bytes -> l.socket?.send(bytes.toByteString()) ?: false }
                return l to host
            }
            problems += l.problem ?: ConnectionProblem(ConnectionProblem.Kind.TIMEOUT)
            if (link === l) link = null
            l.socket?.cancel()
        }
        return null
    }

    private fun clientFor(fingerprint: String): OkHttpClient? {
        cachedClient?.let { (fp, c) -> if (fp == fingerprint) return c }
        val tm = runCatching { PinnedTrustManager(fingerprint) }.getOrNull() ?: return null
        val c = OkHttpClient.Builder()
            .connectTimeout(3, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .pingInterval(20, TimeUnit.SECONDS)
            .sslSocketFactory(tm.socketFactory(), tm)
            .hostnameVerifier { _, _ -> true }
            .build()
        cachedClient = fingerprint to c
        return c
    }

    private fun closeLink() {
        val l = link ?: return
        link = null
        rpc.failAll()
        l.socket?.close(1000, null)
        l.closed.complete(Unit)
    }

    private inner class Link : WebSocketListener() {
        var socket: WebSocket? = null
        val opened = CompletableDeferred<Unit>()
        val closed = CompletableDeferred<Unit>()
        @Volatile var problem: ConnectionProblem? = null

        override fun onOpen(webSocket: WebSocket, response: Response) {
            opened.complete(Unit)
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            if (link === this) rpc.onText(text)
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            if (link === this) rpc.onBinary(bytes.toByteArray())
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(1000, null)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = ended()

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            problem = ConnectionProblem.from(t)
            opened.completeExceptionally(t)
            ended()
        }

        private fun ended() {
            if (link === this) rpc.failAll()
            closed.complete(Unit)
        }
    }
}

/** Pairing couldn't reach the Mac at all. */
class PairingFailed(val problem: ConnectionProblem, val macName: String) : Exception(problem.message(macName))
