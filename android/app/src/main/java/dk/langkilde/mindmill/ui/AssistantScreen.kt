package dk.langkilde.mindmill.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SuggestionChip
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dk.langkilde.mindmill.remote.ConnectionState
import dk.langkilde.mindmill.remote.RemoteException
import dk.langkilde.mindmill.remote.jsonOf
import dk.langkilde.mindmill.remote.obj
import dk.langkilde.mindmill.remote.text
import dk.langkilde.mindmill.remote.userMessage
import kotlinx.coroutines.launch

private val examples = listOf(
    "What needs me today?",
    "Start my next meeting on the Mac and transcribe it",
    "Make a factory for the bugs in this project",
    "What did we decide about login?",
)

/**
 * The Mac's general assistant: a Plan session that can do anything Mindmill can. For when the user doesn't know where
 * something is. On a Mac without `assistant.open` the first message starts an ordinary Plan session instead.
 */
@Composable
fun AssistantScreen(nav: Nav) {
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    val conn by app.connection.state.collectAsState()
    val connected = conn is ConnectionState.Connected
    var session by remember { mutableStateOf(app.assistantSession) }
    var problem by remember { mutableStateOf<String?>(null) }
    var olderMac by remember { mutableStateOf(false) }
    var opening by remember { mutableStateOf(false) }
    var attempt by remember { mutableIntStateOf(0) }

    suspend fun open(fresh: Boolean) {
        opening = true
        problem = null
        try {
            val r = app.call("assistant.open", jsonOf("scope" to app.currentScope, "new" to (if (fresh) true else null)))
            val id = r.obj("session")?.text("id") ?: r.text("session") ?: r.text("id")
            if (id == null) problem = "The Mac didn't open the assistant." else {
                session = id
                app.assistantSession = id
                if (fresh) app.done("Started a new conversation.")
            }
        } catch (e: RemoteException) {
            if (e.isUnknownMethod) olderMac = true else problem = e.userMessage()
        } catch (e: Exception) {
            problem = e.userMessage()
        } finally {
            opening = false
        }
    }

    LaunchedEffect(connected, attempt) { if (connected && session == null && !olderMac) open(false) }

    fun startFallback(text: String) {
        scope.launch {
            try {
                val r = app.call("session.new", jsonOf("space" to "plan", "title" to "Ask Mindmill", "scope" to app.currentScope, "message" to text))
                r.text("id")?.let { session = it; app.assistantSession = it }
            } catch (e: Exception) {
                app.done("Not sent: ${e.userMessage()}", error = true)
            }
        }
    }

    fun sendNow(text: String) {
        val id = session ?: return startFallback(text)
        scope.launch {
            try {
                app.call("session.send", jsonOf("id" to id, "text" to text))
            } catch (e: Exception) {
                app.done("Not sent: ${e.userMessage()}", error = true)
            }
        }
    }

    val header: @Composable (Int) -> Unit = { asked ->
        ChipFlow(Modifier.padding(top = 4.dp)) {
            AssistChip(
                onClick = { scope.launch { if (olderMac) { session = null; app.assistantSession = null } else open(true) } },
                label = { Text("New conversation") },
                leadingIcon = { Icon(Icons.Default.Add, contentDescription = null) },
            )
            AssistChip(
                onClick = { nav.go(Screen.Voice) },
                label = { Text("Talk instead") },
                leadingIcon = { Icon(Icons.Default.Mic, contentDescription = null) },
            )
            AssistChip(
                onClick = { nav.go(Screen.AllActions()) },
                label = { Text("All actions") },
                leadingIcon = { Icon(Icons.AutoMirrored.Filled.OpenInNew, contentDescription = null) },
            )
        }
        if (olderMac) {
            NoticeBar(
                "The Mac's Mindmill has no assistant yet. Update it on the Mac; until then your question starts a Plan session.",
                Modifier.padding(vertical = 6.dp),
            )
        }
        if (asked == 0) {
            Text(
                "Ask for anything Mindmill can do: start a meeting, find a decision, change a factory, answer a question. " +
                    "It asks before anything risky; answer it here.",
                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(vertical = 8.dp),
            )
            SectionTitle("Try")
            ChipFlow {
                examples.forEach { e -> SuggestionChip(onClick = { sendNow(e) }, label = { Text(e) }) }
            }
        }
    }

    Column(Modifier.fillMaxSize()) {
        val id = session
        when {
            id != null -> ChatPane(id, emptyText = "Ask something to begin.", placeholder = "Ask Mindmill…") { asked -> header(asked) }
            olderMac -> {
                Column(Modifier.weight(1f).fillMaxWidth()) { header(0) }
                Composer(enabled = connected, placeholder = "Ask Mindmill…", onSend = ::startFallback, draftKey = "assistant")
            }
            else -> {
                Column(Modifier.weight(1f).fillMaxWidth()) {
                    header(0)
                    when {
                        problem != null -> ErrorState(problem!!, onRetry = { attempt++ })
                        !connected -> WaitingForMac { app.connection.retryNow() }
                        opening -> Loading(text = "Opening the assistant…")
                    }
                }
            }
        }
    }
}
