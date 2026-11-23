package dk.langkilde.mindmill.ui

import android.content.Intent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import dk.langkilde.mindmill.remote.ActionOutcome
import dk.langkilde.mindmill.remote.int
import dk.langkilde.mindmill.remote.jsonOf
import dk.langkilde.mindmill.remote.obj
import dk.langkilde.mindmill.remote.objects
import dk.langkilde.mindmill.remote.string
import dk.langkilde.mindmill.remote.text
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject

@Composable
fun HomeScreen(nav: Nav) {
    val app = LocalApp.current
    val settings by app.settings.collectAsState()
    val cards by app.reviewCards.collectAsState()
    val (state, retry) = rememberLoad(settings.scope) { app.runAction("overview", jsonOf("scope" to app.currentScope)) }
    val (meetings, _) = rememberLoad(settings.scope) {
        runCatching { app.runAction("calendar.upcoming", jsonOf("days" to 1)) }.getOrNull()?.takeIf { it.ok }
    }
    RefreshList(state.refreshing, retry) {
        item { AskCard(nav) }
        item {
            ChipFlow(Modifier.padding(top = 8.dp)) {
                AssistChip(onClick = { nav.go(Screen.Voice) }, label = { Text("Talk") },
                    leadingIcon = { Icon(Icons.Default.Mic, contentDescription = null) })
                AssistChip(onClick = { nav.go(Screen.MacMeeting) }, label = { Text("Meeting on the Mac") })
                AssistChip(onClick = { nav.go(Screen.LiveMeeting) }, label = { Text(if (app.meeting.isLive) "Back to the phone meeting" else "Record on this phone") })
                AssistChip(onClick = { nav.tab(Screen.Sessions(Mode.PLAN.id)) }, label = { Text("New session") })
                AssistChip(onClick = { nav.go(Screen.AllActions()) }, label = { Text("All actions") })
            }
        }
        meetings.value?.let { m -> item { NextMeetingCard(m.data, nav) } }
        item {
            SectionTitle("What needs you")
            LoadStatus(state, retry)
        }
        val outcome = state.value
        if (outcome != null) {
            val d = outcome.data
            item {
                if (outcome.status == ActionOutcome.Status.FAILED) ErrorState(outcome.speech, retry, compact = true)
                else Text(outcome.speech, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.padding(vertical = 8.dp))
            }
            fun count(k: String) = d.int(k) ?: 0
            val rows = buildList {
                if (count("proposedFacts") > 0) add(Triple("Proposed facts", count("proposedFacts"), Screen.Facts(proposed = true)))
                if (count("followupsMine") > 0) add(Triple("Follow-ups on you", count("followupsMine"), Screen.Followups("mine")))
                if (count("followupsWaiting") > 0) add(Triple("Waiting on others", count("followupsWaiting"), Screen.Followups("waiting")))
                if (count("workItems") > 0) add(Triple("Your work items", count("workItems"), Screen.Backlog))
                if (count("factoryQuestions") > 0) add(Triple("Factory questions", count("factoryQuestions"), Screen.Factories))
                if (count("factoriesRunning") > 0) add(Triple("Factories running", count("factoriesRunning"), Screen.Factories))
                if (cards.isNotEmpty()) add(Triple("Ready for review", cards.size, Screen.Test))
            }
            if (rows.isEmpty() && outcome.ok) item { EmptyState("Nothing waits for you right now.") }
            items(rows) { (label, n, screen) ->
                ListRow(label, onClick = { nav.go(screen) },
                    trailing = { CountBadge(n) })
            }
            val waiting = d.objects("sessionsWaiting").map(SessionInfo::parse)
            if (waiting.isNotEmpty()) {
                item { SectionTitle("Sessions waiting for you") }
                items(waiting) { s ->
                    ListRow(s.title, subtitle = "${s.space.replaceFirstChar { it.uppercase() }} · ${s.state}",
                        onClick = { nav.go(Screen.SessionChat(s.id, s.title)) })
                }
            }
        }
    }
}

/** Build's overview, like My Work on the Mac: sessions waiting for you, your work items, pull requests. */
@Composable
fun MyWorkScreen(nav: Nav) {
    val app = LocalApp.current
    val settings by app.settings.collectAsState()
    var tick by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) { app.events.collect { if (it.name == "session.changed") tick++ } }
    val (sessions, retrySessions) = rememberLoad(trigger = tick) { app.call("sessions.list").objects("sessions").map(SessionInfo::parse) }
    val (work, retryWork) = rememberLoad(settings.scope) {
        app.call("tracker.items", jsonOf("scope" to app.currentScope, "mine" to true)).objects("items").map(WorkItem::parse)
    }
    val waiting = sessions.value.orEmpty().filter { it.space == "build" && it.needsYou && !it.archived }
    val running = sessions.value.orEmpty().filter { it.space == "build" && (it.busy || it.state == "working") && !it.archived }
    RefreshList(sessions.refreshing || work.refreshing, { retrySessions(); retryWork() }) {
        item {
            ChipFlow(Modifier.padding(top = 4.dp)) {
                AssistChip(onClick = { nav.tab(Screen.Sessions(Mode.BUILD.id)) }, label = { Text("New session") })
                AssistChip(onClick = { nav.go(Screen.Factories) }, label = { Text("Factories") })
                AssistChip(onClick = { nav.go(Screen.Test) }, label = { Text("Test") })
                AssistChip(onClick = { nav.go(Screen.PullRequests) }, label = { Text("Pull requests") })
            }
            SectionTitle("Sessions waiting for you")
            LoadStatus(sessions, retrySessions, skeletonRows = 2)
            if (sessions.value != null && waiting.isEmpty()) ListEmptyState("No Build session waits for you.")
        }
        items(waiting, key = { "w-" + it.id }) { s ->
            ListRow(s.title, subtitle = SessionGroups.stateTitle(s.state), onClick = { nav.go(Screen.SessionChat(s.id, s.title)) })
        }
        if (running.isNotEmpty()) {
            item { SectionTitle("Working now") }
            items(running, key = { "r-" + it.id }) { s ->
                ListRow(s.title, subtitle = s.updatedText, onClick = { nav.go(Screen.SessionChat(s.id, s.title)) })
            }
        }
        item {
            SectionTitle("Your work items")
            LoadStatus(work, retryWork, skeletonRows = 3)
            if (work.value?.isEmpty() == true) ListEmptyState("Nothing is assigned to you.")
        }
        items(work.value.orEmpty(), key = { "i-" + it.id }) { w ->
            ListRow(
                "#${w.id} ${w.title}",
                subtitle = listOf(w.type, w.state, w.sprintName).filter { it.isNotBlank() }.joinToString(" · "),
                onClick = { nav.go(Screen.WorkItemDetail(w.raw)) },
            )
        }
    }
}

@Composable
fun CountBadge(n: Int) {
    val (bg, fg) = readableContainer()
    Surface(color = bg, contentColor = fg, shape = RoundedCornerShape(10.dp)) {
        Text("$n", style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp))
    }
}

@Composable
private fun AskCard(nav: Nav) {
    val (bg, fg) = readableContainer()
    Surface(
        color = bg, contentColor = fg, shape = RoundedCornerShape(20.dp),
        modifier = Modifier.fillMaxWidth().padding(top = 8.dp).clickable { nav.go(Screen.Assistant) },
    ) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.AutoAwesome, contentDescription = null, tint = fg, modifier = Modifier.size(28.dp))
            Column(Modifier.weight(1f).padding(start = 12.dp)) {
                Text("Ask Mindmill", style = MaterialTheme.typography.titleMedium, color = fg)
                Text(
                    "Anything the Mac can do: start a meeting, find a decision, set up a factory. Type or dictate.",
                    style = MaterialTheme.typography.bodyMedium, color = fg,
                )
            }
        }
    }
}

@Composable
private fun NextMeetingCard(data: JsonObject, nav: Nav) {
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    val events = data.objects("events")
    val nextId = data.text("next")
    val next = data.obj("next") ?: events.firstOrNull { it.text("id") == nextId }
        ?: events.firstOrNull { it.string("status") == "live" } ?: return
    val ev = CalendarEvent.parse(next)
    SectionCard(if (ev.status == "live") "Meeting now" else "Next meeting") {
        Text(ev.title, style = MaterialTheme.typography.bodyLarge)
        Text(ev.whenText, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        ChipFlow(Modifier.padding(top = 6.dp)) {
            if (ev.status == "live") {
                Button(onClick = { nav.go(Screen.MacMeeting) }) { Text("Open the live meeting") }
            } else {
                Button(onClick = {
                    scope.launch {
                        val o = app.runAndReport("meeting.mac.start", jsonOf("event" to ev.id))
                        if (o?.ok == true) nav.go(Screen.MacMeeting)
                    }
                }) { Text("Start on Mac") }
            }
            TextButton(onClick = { nav.go(Screen.MacMeeting) }) { Text("All of today") }
        }
    }
}

@Composable
fun BacklogScreen(nav: Nav) {
    val app = LocalApp.current
    val settings by app.settings.collectAsState()
    var mine by rememberSaveable { mutableStateOf(true) }
    var stateFilter by rememberSaveable { mutableStateOf<String?>(null) }
    var query by rememberSaveable { mutableStateOf("") }
    val (state, retry) = rememberLoad(settings.scope, mine) {
        app.call("tracker.items", jsonOf("scope" to app.currentScope, "mine" to mine))
    }
    val items = state.value?.objects("items")?.map(WorkItem::parse).orEmpty()
    val states = items.map { it.state }.filter { it.isNotBlank() }.distinct()
    val shown = items.filter { (stateFilter == null || it.state == stateFilter) && (query.isBlank() || "#${it.id} ${it.title}".contains(query.trim(), true)) }
    RefreshList(state.refreshing, retry) {
        item {
            ChipFlow(Modifier.padding(top = 4.dp)) {
                Choice("Mine", mine) { mine = true }
                Choice("Everyone's", !mine) { mine = false }
            }
            if (states.size > 1) {
                ChipFlow(Modifier.padding(top = 4.dp)) {
                    Choice("Any state", stateFilter == null) { stateFilter = null }
                    states.forEach { s -> Choice(s, stateFilter == s) { stateFilter = if (stateFilter == s) null else s } }
                }
            }
            if (items.size > 8) {
                OutlinedTextField(query, { query = it }, label = { Text("Filter by title or number") }, singleLine = true,
                    modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp))
            }
            ChipFlow(Modifier.padding(top = 4.dp)) {
                OutlinedButton(onClick = { nav.go(Screen.RunAction("workitem.create")) }) { Text("New work item") }
                TextButton(onClick = { nav.go(Screen.PullRequests) }) { Text("Pull requests") }
            }
            LoadStatus(state, retry)
            if (state.value != null && shown.isEmpty()) {
                EmptyState(
                    when {
                        query.isNotBlank() || stateFilter != null -> "Nothing matches the filter."
                        mine -> "Nothing is assigned to you."
                        else -> "No work items in this project."
                    },
                    actionLabel = if (mine && query.isBlank()) "Show everyone's" else null,
                    onAction = { mine = false },
                )
            }
        }
        items(shown, key = { it.id }) { w ->
            ListRow(
                "#${w.id} ${w.title}",
                subtitle = listOf(w.type, w.state, w.assignee.ifBlank { "Unassigned" }, w.sprintName).filter { it.isNotBlank() }.joinToString(" · "),
                onClick = { nav.go(Screen.WorkItemDetail(w.raw)) },
            )
        }
    }
}

@Composable
fun WorkItemScreen(raw: JsonObject) {
    val app = LocalApp.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val item = remember(raw) { WorkItem.parse(raw) }
    var busy by remember { mutableStateOf(false) }
    var comment by rememberSaveable { mutableStateOf("") }
    var assignee by rememberSaveable { mutableStateOf("") }
    var newState by rememberSaveable { mutableStateOf("") }
    var currentState by remember { mutableStateOf(item.state) }
    val (details, retryDetails) = rememberLoad(item.id) { app.runAction("workitem.get", jsonOf("id" to item.id)).data.string("text") }

    fun update(vararg change: Pair<String, Any?>, after: () -> Unit = {}) {
        busy = true
        scope.launch {
            val o = app.runAndReport("workitem.update", jsonOf("id" to item.id, "scope" to app.currentScope, *change))
            if (o?.ok == true) after()
            busy = false
        }
    }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 16.dp)) {
        Text("#${item.id} ${item.title}", style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(vertical = 6.dp))
        ChipFlow {
            listOf(item.type, currentState, item.assignee.ifBlank { "Unassigned" }, item.sprintName).filter { it.isNotBlank() }
                .forEach { InfoChip(it) }
        }
        if (busy) LinearProgressIndicator(Modifier.fillMaxWidth().padding(vertical = 6.dp))

        SectionTitle("State")
        val common = (listOf("New", "Active", "Resolved", "Closed") + item.state).filter { it.isNotBlank() }.distinct()
        ChipFlow {
            common.forEach { s -> Choice(s, s == currentState) { if (!busy && s != currentState) update("state" to s) { currentState = s } } }
        }
        SectionTitle("Assign")
        Button(onClick = { update("assignee" to "me") }, enabled = !busy, modifier = Modifier.fillMaxWidth()) { Text("Assign to me") }
        SectionTitle("Comment")
        OutlinedTextField(comment, { comment = it }, label = { Text("A comment for the tracker") }, modifier = Modifier.fillMaxWidth(), minLines = 2)
        Button(
            onClick = { update("comment" to comment.trim()) { comment = "" } },
            enabled = !busy && comment.isNotBlank(), modifier = Modifier.padding(top = 8.dp),
        ) { Text("Post comment") }

        if (item.tasks.isNotEmpty()) {
            SectionTitle("Tasks")
            item.tasks.forEach { t -> ListRow(t.title, subtitle = listOf(t.state, t.assignee).filter { it.isNotBlank() }.joinToString(" · ")) }
        }
        MoreOptions {
            OutlinedTextField(assignee, { assignee = it }, label = { Text("Assign to (name or email)") }, modifier = Modifier.fillMaxWidth())
            TextButton(onClick = { update("assignee" to assignee.trim()) }, enabled = !busy && assignee.isNotBlank()) { Text("Assign") }
            OutlinedTextField(newState, { newState = it }, label = { Text("Another state") }, modifier = Modifier.fillMaxWidth())
            TextButton(onClick = { val s = newState.trim(); update("state" to s) { currentState = s } }, enabled = !busy && newState.isNotBlank()) { Text("Set state") }
            if (item.url.isNotBlank()) {
                TextButton(onClick = {
                    runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, item.url.toUri())) }
                }) { Text("Open in the tracker") }
            }
        }
        SectionTitle("Details")
        LoadStatus(details, retryDetails, skeletonRows = 3)
        details.value?.takeIf { it.isNotBlank() }?.let {
            Card(Modifier.fillMaxWidth().padding(bottom = 16.dp)) {
                Text(markdownish(it), style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(12.dp))
            }
        }
    }
}

@Composable
fun FactoriesScreen(nav: Nav) {
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    var tick by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) { app.events.collect { if (it.name == "factory.changed") tick++ } }
    val (state, retry) = rememberLoad(trigger = tick) { app.runAction("factories.status") }
    val factories = state.value?.data?.objects("factories")?.map(Factory::parse).orEmpty()
    var deleting by remember { mutableStateOf<Factory?>(null) }

    fun run(action: String, params: JsonObject) {
        scope.launch {
            app.runAndReport(action, params)
            retry()
        }
    }

    RefreshList(state.refreshing, retry) {
        item {
            Text(
                "A factory takes work items, builds them in sessions and opens pull requests, asking you when it needs to.",
                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(vertical = 4.dp),
            )
            ChipFlow(Modifier.padding(vertical = 4.dp)) {
                Button(onClick = { nav.go(Screen.FactoryEditor(null)) }) { Text("New factory") }
                TextButton(onClick = { nav.go(Screen.AllActions("Factories")) }) { Text("Factory actions") }
            }
            LoadStatus(state, retry)
            if (state.value != null && factories.isEmpty()) {
                EmptyState("No factories yet.", "Create one", { nav.go(Screen.FactoryEditor(null)) })
            }
        }
        items(factories, key = { it.id }) { f -> FactoryCard(f, nav, ::run, onDelete = { deleting = f }) }
    }
    deleting?.let { f ->
        ConfirmDialog(
            "Delete ${f.name}?",
            "The factory and its settings go away. If it is running, it stops first; sessions it started keep their work.",
            "Delete",
            onConfirm = { scope.launch { if (deleteFactory(app, f.id, f.name)) retry() } },
            onDismiss = { deleting = null },
        )
    }
}

@Composable
private fun FactoryCard(f: Factory, nav: Nav, run: (String, JsonObject) -> Unit, onDelete: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Card(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
        Column(Modifier.padding(start = 14.dp, end = 4.dp, top = 8.dp, bottom = 12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(f.name, style = MaterialTheme.typography.titleMedium)
                    Text(
                        listOfNotNull(
                            factoryStatusTitle(f.status),
                            f.progress?.let { "${(it * 100).toInt()}% done" },
                            "${f.maxParallel} at a time",
                        ).joinToString(" · "),
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                androidx.compose.foundation.layout.Box {
                    IconButton(onClick = { menu = true }) { Icon(Icons.Default.MoreVert, contentDescription = "More for ${f.name}") }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        DropdownMenuItem(text = { Text("Edit") }, leadingIcon = { Icon(Icons.Default.Edit, null) },
                            onClick = { menu = false; nav.go(Screen.FactoryEditor(f.id)) })
                        DropdownMenuItem(text = { Text("Duplicate") }, leadingIcon = { Icon(Icons.Default.ContentCopy, null) },
                            onClick = { menu = false; nav.go(Screen.FactoryEditor(f.id, duplicate = true)) })
                        DropdownMenuItem(text = { Text("Delete", color = MaterialTheme.colorScheme.error) },
                            leadingIcon = { Icon(Icons.Default.Delete, null, tint = MaterialTheme.colorScheme.error) },
                            onClick = { menu = false; onDelete() })
                    }
                }
            }
            Column(Modifier.padding(end = 10.dp)) {
                f.progress?.let {
                    LinearProgressIndicator(progress = { it.toFloat().coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp))
                }
                val key = jsonOf("factory" to f.id)
                ChipFlow(Modifier.padding(top = 4.dp)) {
                    when (f.status) {
                        "running" -> {
                            OutlinedButton(onClick = { run("factory.pause", key) }) { Text("Pause") }
                            OutlinedButton(onClick = { run("factory.stop", key) }) { Text("Stop") }
                        }
                        "paused" -> {
                            Button(onClick = { run("factory.resume", key) }) { Text("Resume") }
                            OutlinedButton(onClick = { run("factory.stop", key) }) { Text("Stop") }
                        }
                        "windingDown" -> Text("Finishing the steps it's on.", style = MaterialTheme.typography.bodySmall)
                        else -> Button(onClick = { run("factory.start", key) }) { Text("Start") }
                    }
                    TextButton(onClick = { nav.go(Screen.FactoryEditor(f.id)) }) { Text("Edit") }
                }
                if (f.tasks.isNotEmpty()) {
                    SectionTitle("Working on")
                    f.tasks.forEach { t ->
                        ListRow(
                            (t.workItem?.let { "#$it " } ?: "") + t.title,
                            subtitle = t.milestone,
                            onClick = t.session?.let { s -> { nav.go(Screen.SessionChat(s, t.title)) } },
                        )
                    }
                }
                f.questions.forEach { q -> FactoryQuestionView(q, run) }
            }
        }
    }
}

@Composable
private fun FactoryQuestionView(q: Factory.FactoryQuestion, run: (String, JsonObject) -> Unit) {
    var answer by rememberSaveable(q.id) { mutableStateOf("") }
    SectionTitle("Question" + (q.workItem?.let { " on #$it" } ?: ""))
    Text(q.text, style = MaterialTheme.typography.bodyMedium)
    if (q.options.isNotEmpty()) {
        ChipFlow(Modifier.padding(top = 4.dp)) {
            q.options.forEach { o -> Choice(o, false) { run("factory.answer", jsonOf("question" to q.id, "answer" to o)) } }
        }
    }
    OutlinedTextField(answer, { answer = it }, label = { Text("Your answer") }, modifier = Modifier.fillMaxWidth().padding(top = 4.dp))
    TextButton(
        onClick = { run("factory.answer", jsonOf("question" to q.id, "answer" to answer.trim())); answer = "" },
        enabled = answer.isNotBlank(),
    ) { Text("Answer") }
}
