package dk.langkilde.mindmill.ui

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.BiasAlignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import dk.langkilde.mindmill.remote.ChatItem
import dk.langkilde.mindmill.remote.ChatLog
import dk.langkilde.mindmill.remote.ConnectionState
import dk.langkilde.mindmill.remote.jsonOf
import dk.langkilde.mindmill.remote.text
import dk.langkilde.mindmill.remote.userMessage
import dk.langkilde.mindmill.voice.ContinuousRecognizer
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.Locale

/** Speech to text for a text field: one utterance at a time, on the phone. */
class Dictation {
    var listening by mutableStateOf(false)
        internal set
    var partial by mutableStateOf("")
        internal set
    internal var startFn: () -> Unit = {}
    internal var stopFn: () -> Unit = {}
    fun toggle() = if (listening) stopFn() else startFn()
}

@Composable
fun rememberDictation(onText: (String) -> Unit): Dictation {
    val app = LocalApp.current
    val context = LocalContext.current
    val d = remember { Dictation() }
    val recognizer = remember {
        ContinuousRecognizer(context, object : ContinuousRecognizer.Listener {
            override fun onPartial(text: String) { d.partial = text }
            override fun onFinal(text: String) {
                d.partial = ""
                if (text.isNotBlank()) onText(text)
                d.stopFn()
            }
            override fun onProblem(message: String) {
                d.listening = false
                d.partial = ""
                app.done(message, error = true)
            }
        })
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        if (ok) { d.listening = true; recognizer.start(Locale.getDefault()) } else app.done("Mindmill needs the microphone for dictation.", error = true)
    }
    d.startFn = {
        when {
            app.voice.ui.value.active -> app.done("End the voice conversation first: both need the microphone.", error = true)
            app.meeting.isLive -> app.done("A meeting is recording on the phone: it has the microphone.", error = true)
            context.hasPermission(Manifest.permission.RECORD_AUDIO) -> { d.listening = true; recognizer.start(Locale.getDefault()) }
            else -> permission.launch(Manifest.permission.RECORD_AUDIO)
        }
    }
    d.stopFn = { d.listening = false; d.partial = ""; recognizer.stop() }
    DisposableEffect(Unit) { onDispose { recognizer.release() } }
    return d
}

/** A message box with dictation and send; [onSend] gets the trimmed text. */
@Composable
fun Composer(
    enabled: Boolean,
    onSend: (String) -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String = "Message",
    draftKey: String = "",
) {
    var draft by rememberSaveable(draftKey) { mutableStateOf("") }
    val dictation = rememberDictation { said -> draft = listOf(draft.trimEnd(), said).filter { it.isNotBlank() }.joinToString(" ") }
    Column(modifier.fillMaxWidth().padding(vertical = 6.dp)) {
        if (dictation.listening) {
            Text(dictation.partial.ifBlank { "Listening…" }, style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(bottom = 4.dp))
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                draft, { draft = it }, placeholder = { Text(placeholder) },
                modifier = Modifier.weight(1f), maxLines = 6, shape = RoundedCornerShape(20.dp),
            )
            IconButton(onClick = { dictation.toggle() }) {
                Icon(
                    if (dictation.listening) Icons.Default.Stop else Icons.Default.Mic,
                    contentDescription = if (dictation.listening) "Stop dictation" else "Dictate",
                    tint = if (dictation.listening) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            FilledIconButton(
                enabled = enabled && draft.isNotBlank(),
                onClick = {
                    val text = draft.trim()
                    draft = ""
                    if (dictation.listening) dictation.toggle()
                    onSend(text)
                },
                colors = IconButtonDefaults.filledIconButtonColors(),
            ) { Icon(Icons.AutoMirrored.Filled.Send, contentDescription = "Send") }
        }
    }
}

/**
 * One session's chat: loads with `session.get`, follows `session.changed`, and sends with `session.send`. [header]
 * goes above the messages (inside the list, so it scrolls away on a small screen).
 */
@Composable
fun ChatPane(
    id: String,
    emptyText: String,
    modifier: Modifier = Modifier,
    placeholder: String = "Message",
    onTitle: (String) -> Unit = {},
    header: @Composable ColumnScope.(userMessages: Int) -> Unit = {},
) {
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    val conn by app.connection.state.collectAsState()
    val log = remember(id) { ChatLog() }
    var version by remember(id) { mutableIntStateOf(0) }
    var loaded by remember(id) { mutableStateOf(false) }
    var problem by remember(id) { mutableStateOf<String?>(null) }
    val lock = remember(id) { Mutex() }
    val listState = rememberLazyListState()

    suspend fun fetch() = lock.withLock {
        try {
            val since = log.since
            val r = app.call("session.get", jsonOf("id" to id, "since" to since))
            if (log.apply(r, since)) log.apply(app.call("session.get", jsonOf("id" to id, "since" to 0)), 0)
            log.title?.let(onTitle)
            problem = null
        } catch (e: Exception) {
            problem = e.userMessage()
        }
        loaded = true
        version++
    }

    LaunchedEffect(id, conn is ConnectionState.Connected) { if (conn is ConnectionState.Connected) fetch() }
    LaunchedEffect(id) {
        app.events.collect { e ->
            if (e.name == "session.changed" && e.data.text("id") == id) fetch()
        }
    }
    val items = remember(version) { log.items }
    LaunchedEffect(items.size, log.busy) { if (items.isNotEmpty()) listState.animateScrollToItem(items.size) }

    Column(modifier.fillMaxSize()) {
        LazyColumn(Modifier.weight(1f).fillMaxWidth(), state = listState, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            item { Column(Modifier.fillMaxWidth()) { header(items.count { it.role == "user" }) } }
            if (!loaded) item { SkeletonRows(3) }
            else if (items.isEmpty()) item { ListEmptyState(emptyText) }
            itemsIndexed(items) { _, m -> ChatBubble(m) }
            if (log.busy) {
                item {
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 4.dp)) {
                        CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                        Text("Working…", style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(start = 8.dp))
                    }
                }
            }
        }
        problem?.let { ErrorState(it, onRetry = { scope.launch { fetch() } }, compact = true) }
        Composer(
            enabled = true, placeholder = placeholder, draftKey = id,
            onSend = { text ->
                log.addPending(text)
                version++
                scope.launch {
                    try {
                        app.call("session.send", jsonOf("id" to id, "text" to text))
                        fetch()
                    } catch (e: Exception) {
                        log.dropPending(text)
                        version++
                        app.done("Not sent: ${e.userMessage()}", error = true)
                    }
                }
            },
        )
    }
}

@Composable
fun ChatBubble(m: ChatItem) = ChatBubble(m.role, m.text, m.pending)

@Composable
fun ChatBubble(role: String, text: String, pending: Boolean = false) {
    val mine = role == "user"
    val quiet = role == "status" || role == "tool"
    val color = when {
        mine -> MaterialTheme.colorScheme.primaryContainer
        role == "error" -> MaterialTheme.colorScheme.errorContainer
        quiet -> MaterialTheme.colorScheme.surfaceVariant
        else -> MaterialTheme.colorScheme.surfaceContainerHigh
    }
    Box(Modifier.fillMaxWidth(), contentAlignment = if (mine) BiasAlignment(1f, 0f) else BiasAlignment(-1f, 0f)) {
        Surface(
            color = color, shape = RoundedCornerShape(14.dp),
            modifier = Modifier.padding(start = if (mine) 40.dp else 0.dp, end = if (mine) 0.dp else 24.dp),
        ) {
            Column(Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) {
                if (role == "tool") Text("Did", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary)
                SelectionContainer {
                    Text(
                        if (quiet) AnnotatedString(text) else markdownish(text),
                        style = if (quiet) MaterialTheme.typography.bodySmall else MaterialTheme.typography.bodyMedium,
                        color = if (pending) MaterialTheme.colorScheme.onSurfaceVariant else androidx.compose.ui.graphics.Color.Unspecified,
                    )
                }
                if (pending) Text("Sending…", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

/** Basic Markdown for chat: headings, **bold**, `code`, and bullets; the rest stays plain text. */
fun markdownish(text: String): AnnotatedString = buildAnnotatedString {
    val lines = text.lines()
    var inCode = false
    lines.forEachIndexed { i, raw ->
        if (raw.trimStart().startsWith("```")) {
            inCode = !inCode
            return@forEachIndexed
        }
        if (inCode) {
            withStyle(SpanStyle(fontFamily = FontFamily.Monospace)) { append(raw) }
        } else {
            var line = raw
            val heading = Regex("^#{1,6}\\s+").find(line)
            if (heading != null) {
                withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { inline(line.removeRange(heading.range)) }
            } else {
                Regex("^(\\s*)[-*]\\s+").find(line)?.let { m -> line = m.groupValues[1] + "• " + line.substring(m.range.last + 1) }
                inline(line)
            }
        }
        if (i < lines.lastIndex) append('\n')
    }
}

private fun AnnotatedString.Builder.inline(s: String) {
    val pattern = Regex("\\*\\*(.+?)\\*\\*|`([^`]+)`")
    var at = 0
    for (m in pattern.findAll(s)) {
        append(s.substring(at, m.range.first))
        val bold = m.groups[1]?.value
        if (bold != null) withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(bold) }
        else withStyle(SpanStyle(fontFamily = FontFamily.Monospace)) { append(m.groups[2]?.value.orEmpty()) }
        at = m.range.last + 1
    }
    append(s.substring(at))
}
