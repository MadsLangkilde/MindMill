package dk.langkilde.mindmill.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.LifecycleResumeEffect
import dk.langkilde.mindmill.Notice
import dk.langkilde.mindmill.remote.ConnectionState
import dk.langkilde.mindmill.remote.RemoteException
import dk.langkilde.mindmill.remote.bool
import dk.langkilde.mindmill.remote.jsonOf
import dk.langkilde.mindmill.remote.obj
import dk.langkilde.mindmill.remote.userMessage
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject

sealed interface Screen {
    data object Home : Screen
    data object MyWork : Screen
    data object Backlog : Screen
    data class Sessions(val space: String = "plan") : Screen
    data object Voice : Screen
    data object More : Screen
    data object Assistant : Screen
    data class Facts(val proposed: Boolean = false, val section: String = "facts") : Screen
    data class Followups(val filter: String = "mine") : Screen
    data object Meetings : Screen
    data object MacMeeting : Screen
    data object Factories : Screen
    data class FactoryEditor(val id: String?, val duplicate: Boolean = false) : Screen
    data object Test : Screen
    data object Connection : Screen
    data class AllActions(val area: String? = null) : Screen
    data class RunAction(val name: String, val defaults: Map<String, String> = emptyMap()) : Screen
    data object Knowledge : Screen
    data class NewEntry(val section: String) : Screen
    data object PullRequests : Screen
    data class PullRequest(val id: String, val title: String) : Screen
    data object Discussions : Screen
    data object People : Screen
    data object Tags : Screen
    data class Command(val title: String, val args: List<String>, val about: String) : Screen
    data class ActionView(val title: String, val action: String, val area: String, val fallbackArgs: List<String>, val about: String) : Screen
    data class WorkItemDetail(val item: JsonObject) : Screen
    data class Entry(val id: String) : Screen
    data class SessionChat(val id: String, val title: String, val archived: Boolean = false) : Screen
    data class MeetingDetail(val id: String, val title: String) : Screen
    data object LiveMeeting : Screen
    data class Web(val title: String, val url: String, val preview: Boolean) : Screen
}

fun Screen.title(): String = when (this) {
    Screen.Home -> "Mindmill"
    Screen.MyWork -> "Overview"
    Screen.Backlog -> "Backlog"
    is Screen.Sessions -> "Sessions"
    Screen.Voice -> "Voice"
    Screen.More -> "More"
    Screen.Assistant -> "Ask Mindmill"
    is Screen.Facts -> if (proposed) "Proposed facts" else sectionTitle(section)
    is Screen.Followups -> "Follow-ups"
    Screen.Meetings -> "Meetings"
    Screen.MacMeeting -> "Meeting on the Mac"
    Screen.Factories -> "Factories"
    is Screen.FactoryEditor -> if (id == null) "New factory" else if (duplicate) "Duplicate factory" else "Edit factory"
    Screen.Test -> "Test"
    Screen.Connection -> "Connection"
    is Screen.AllActions -> area?.let { dk.langkilde.mindmill.remote.ActionInfo.areaTitle(it) } ?: "All actions"
    is Screen.RunAction -> dk.langkilde.mindmill.remote.humanize(name.replace('.', ' '))
    Screen.Knowledge -> "Knowledge"
    is Screen.NewEntry -> "New ${sectionTitle(section).lowercase().removeSuffix("s")}"
    Screen.PullRequests -> "Pull requests"
    is Screen.PullRequest -> "Pull request !$id"
    Screen.Discussions -> "Discussions"
    Screen.People -> "People"
    Screen.Tags -> "Tags"
    is Screen.Command -> title
    is Screen.ActionView -> title
    is Screen.WorkItemDetail -> "Work item"
    is Screen.Entry -> "Entry"
    is Screen.SessionChat -> "Session"
    is Screen.MeetingDetail -> "Meeting"
    Screen.LiveMeeting -> "Meeting on this phone"
    is Screen.Web -> title
}

/** Lists whose rows open a detail: on a wide screen the detail opens beside the list. */
fun Screen.isListScreen(): Boolean = when (this) {
    is Screen.Sessions, Screen.Backlog, Screen.Meetings, is Screen.Facts, Screen.PullRequests, Screen.Discussions,
    Screen.Knowledge, Screen.Tags, Screen.MyWork, Screen.Factories -> true
    else -> false
}

/** What a list pane says until something is picked. */
fun Screen.pickHint(): String = when (this) {
    is Screen.Sessions -> "Choose a session to read and answer it here."
    Screen.Backlog -> "Choose a work item to see it here."
    Screen.Meetings -> "Choose a meeting to see its notes here."
    Screen.PullRequests -> "Choose a pull request to see it here."
    Screen.Factories -> "Choose a factory to edit it here."
    Screen.MyWork -> "What you open shows here."
    else -> "Choose one to see it here."
}

open class Nav(val stack: SnapshotStateList<Screen> = mutableStateListOf(Screen.Home)) {
    val current: Screen get() = stack.last()
    val tab: Screen get() = stack.first()
    open fun go(s: Screen) { if (current != s) stack.add(s) }
    fun tab(s: Screen) { stack.clear(); stack.add(s) }
    fun back(): Boolean = if (stack.size > 1) { stack.removeAt(stack.lastIndex); true } else false
    fun replace(s: Screen) { if (stack.size > 1) stack.removeAt(stack.lastIndex); stack.add(s) }
}

/** The list pane of a list–detail layout: what it opens replaces the detail beside it. */
private class ListPaneNav(base: Nav) : Nav(base.stack) {
    override fun go(s: Screen) {
        while (stack.size > 1) stack.removeAt(stack.lastIndex)
        stack.add(s)
    }
}

/** The current mode and its sections, for screens that list them (More, Home). */
data class NavContext(
    val mode: Mode = Mode.PLAN,
    val sections: List<NavSection> = emptyList(),
    val overflow: List<NavSection> = emptyList(),
    val kbSections: List<String> = emptyList(),
    val width: WidthClass = WidthClass.COMPACT,
)

val LocalNavContext = staticCompositionLocalOf { NavContext() }

/** Archive changes made on this phone, shown at once while the Mac's list catches up. */
object SessionArchive {
    val overrides = mutableStateMapOf<String, Boolean>()

    /** `session.archive`, or the action of that name on a Mac that has no method for it. */
    suspend fun set(app: dk.langkilde.mindmill.MindmillApp, id: String, archived: Boolean) {
        overrides[id] = archived
        try {
            try {
                app.call("session.archive", jsonOf("id" to id, "archived" to archived))
            } catch (e: RemoteException) {
                if (!e.isUnknownMethod) throw e
                val o = app.runAction("session.archive", jsonOf("id" to id, "archived" to archived))
                if (o.status == dk.langkilde.mindmill.remote.ActionOutcome.Status.FAILED) throw RemoteException("failed", o.speech)
            }
        } catch (e: Exception) {
            overrides.remove(id)
            throw e
        }
    }

    /** Archives or restores [id] and says so at the bottom, with Undo. */
    fun toggle(app: dk.langkilde.mindmill.MindmillApp, scope: kotlinx.coroutines.CoroutineScope, id: String, title: String, archive: Boolean) {
        scope.launch {
            try {
                set(app, id, archive)
                val undo: () -> Unit = { toggle(app, scope, id, title, !archive) }
                app.done(if (archive) "Archived “$title”." else "Restored “$title”.", "Undo", undo)
            } catch (e: Exception) {
                app.done(e.userMessage(), error = true)
            }
        }
    }
}

/** `app.structure`, kept fresh; the built-in structure when the Mac is older or hasn't answered yet. */
@Composable
private fun rememberStructure(): AppStructure {
    val app = LocalApp.current
    val conn by app.connection.state.collectAsState()
    val settings by app.settings.collectAsState()
    val refresh by app.refresh.collectAsState()
    val hello = (conn as? ConnectionState.Connected)?.hello
    var loaded by remember { mutableStateOf<AppStructure?>(null) }
    var tick by remember { mutableIntStateOf(0) }
    LifecycleResumeEffect(Unit) {
        tick++
        onPauseOrDispose { }
    }
    LaunchedEffect(Unit) {
        app.events.collectLatest { e ->
            if (e.name == "session.changed" || e.name == "structure.changed") {
                delay(1_500)
                tick++
            }
        }
    }
    LaunchedEffect(hello != null, settings.scope, refresh, tick) {
        if (hello == null) return@LaunchedEffect
        try {
            loaded = AppStructure.parse(app.call("app.structure", jsonOf("scope" to app.currentScope)))
        } catch (e: RemoteException) {
            if (e.isUnknownMethod) loaded = null
        } catch (_: Exception) {
        }
    }
    val kb = hello?.sections.orEmpty()
    return remember(loaded, kb) { (loaded ?: AppStructure.default(kb)).forPhone(kb) }
}

@Composable
fun MindmillRoot() {
    val app = LocalApp.current
    val conn by app.connection.state.collectAsState()
    val settings by app.settings.collectAsState()
    val mode = Mode.of(settings.mode)
    val nav = remember { Nav(mutableStateListOf(if (mode == Mode.BUILD) Screen.MyWork else Screen.Home)) }
    val saved = remember { mutableMapOf<Mode, List<Screen>>() }

    if (conn is ConnectionState.NotPaired || conn is ConnectionState.Unauthorized) {
        PairingScreen((conn as? ConnectionState.Unauthorized)?.message)
        return
    }
    val structure = rememberStructure()
    val kb = (conn as? ConnectionState.Connected)?.hello?.sections.orEmpty()
    val sections = structure.sections(mode)

    fun switchMode(to: Mode) {
        if (to == mode) return
        saved[mode] = nav.stack.toList()
        app.updateSettings { it.copy(mode = to.id) }
        val back = saved[to]
        if (back.isNullOrEmpty()) nav.tab(structure.sections(to).first().screen(to, kb))
        else { nav.stack.clear(); nav.stack.addAll(back) }
    }

    BackHandler(enabled = nav.stack.size > 1) { nav.back() }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val width = WidthClass.of(maxWidth.value)
        val ctx = NavContext(mode, sections, if (width == WidthClass.COMPACT) PhoneBar.overflow(mode, sections) else emptyList(), kb, width)
        val other = Mode.entries.first { it != mode }
        val switch: @Composable (Modifier) -> Unit = { m ->
            ModeSwitch(mode, structure.needsYou(other).let { n -> mapOf(other to n) }, m) { switchMode(it) }
        }
        CompositionLocalProvider(LocalNavContext provides ctx) {
            if (width == WidthClass.COMPACT) {
                Scaffold(bottomBar = { PhoneBottomBar(nav, mode, sections, kb) }) { padding ->
                    Column(Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding).imePadding()) {
                        MainColumn(nav, conn, switch, twoPane = false)
                    }
                }
            } else {
                Scaffold { padding ->
                    Row(Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding).imePadding()) {
                        SideNav(nav, mode, sections, kb, Modifier.width(if (width == WidthClass.EXPANDED) 260.dp else 220.dp))
                        VerticalDivider()
                        Column(Modifier.weight(1f).fillMaxHeight()) {
                            MainColumn(nav, conn, switch, twoPane = width == WidthClass.EXPANDED)
                        }
                    }
                }
            }
        }
    }
    ConfirmationDialog()
}

@Composable
private fun androidx.compose.foundation.layout.ColumnScope.MainColumn(
    nav: Nav,
    conn: ConnectionState,
    switch: @Composable (Modifier) -> Unit,
    twoPane: Boolean,
) {
    TopBar(nav, switch)
    Column(Modifier.padding(horizontal = 16.dp)) {
        ConnectionBanner(conn)
        AppNotice(nav)
    }
    Box(Modifier.weight(1f).fillMaxWidth()) { Panes(nav, twoPane) }
    FlashBar(nav)
}

/** One pane, or on a wide screen a list with its detail beside it. */
@Composable
private fun Panes(nav: Nav, twoPane: Boolean) {
    val root = nav.tab
    if (twoPane && root.isListScreen()) {
        val listNav = remember(nav) { ListPaneNav(nav) }
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val listWidth = (maxWidth * 0.42f).coerceIn(320.dp, 420.dp)
            Row(Modifier.fillMaxSize()) {
                Box(Modifier.width(listWidth).fillMaxHeight().padding(horizontal = 16.dp)) {
                    key(root) { ScreenContent(listNav, root) }
                }
                VerticalDivider()
                Box(Modifier.weight(1f).fillMaxHeight().padding(horizontal = 16.dp)) {
                    if (nav.stack.size > 1) {
                        val detail = nav.current
                        key(detail) { ScreenContent(nav, detail) }
                    } else {
                        ListEmptyState(root.pickHint(), Modifier.padding(top = 8.dp))
                    }
                }
            }
        }
    } else {
        Box(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
            val s = nav.current
            key(s) { ScreenContent(nav, s) }
        }
    }
}

/** Plan | Build, as at the top of the Mac's window. */
@Composable
private fun ModeSwitch(mode: Mode, needs: Map<Mode, Int>, modifier: Modifier, onPick: (Mode) -> Unit) {
    SingleChoiceSegmentedButtonRow(modifier) {
        Mode.entries.forEachIndexed { i, m ->
            SegmentedButton(
                selected = m == mode,
                onClick = { onPick(m) },
                shape = SegmentedButtonDefaults.itemShape(i, Mode.entries.size),
                label = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(m.title, maxLines = 1)
                        val n = needs[m] ?: 0
                        if (n > 0) Badge(Modifier.padding(start = 6.dp)) { Text("$n") }
                    }
                },
            )
        }
    }
}

@Composable
private fun SectionIcon(s: NavSection, showBadge: Boolean) {
    val icon = sectionIcon(s.id, s.icon)
    if (showBadge && s.needsYou > 0) {
        BadgedBox(badge = { Badge { Text("${s.needsYou}") } }) { Icon(icon, contentDescription = null) }
    } else {
        Icon(icon, contentDescription = null)
    }
}

/** Phone: the mode's most important sections, and More for the rest. */
@Composable
private fun PhoneBottomBar(nav: Nav, mode: Mode, sections: List<NavSection>, kb: List<String>) {
    val primary = PhoneBar.primary(mode, sections)
    val overflow = PhoneBar.overflow(mode, sections)
    val inBar = primary.map { it.screen(mode, kb) }
    NavigationBar {
        primary.forEach { s ->
            val screen = s.screen(mode, kb)
            NavigationBarItem(
                selected = nav.tab == screen,
                onClick = { nav.tab(screen) },
                icon = { SectionIcon(s, showBadge = true) },
                label = { BarLabel(PhoneBar.label(s)) },
            )
        }
        val moreNeeds = overflow.sumOf { it.needsYou }
        NavigationBarItem(
            selected = nav.tab == Screen.More || nav.tab !in inBar,
            onClick = { nav.tab(Screen.More) },
            icon = {
                if (moreNeeds > 0) BadgedBox(badge = { Badge() }) { Icon(Icons.Default.Menu, contentDescription = null) }
                else Icon(Icons.Default.Menu, contentDescription = null)
            },
            label = { BarLabel("More") },
        )
    }
}

/** A bottom-bar label that shrinks rather than being cut off. */
@Composable
private fun BarLabel(text: String) {
    BasicText(
        text,
        maxLines = 1,
        style = MaterialTheme.typography.labelMedium.copy(color = LocalContentColor.current),
        autoSize = TextAutoSize.StepBased(minFontSize = 8.sp, maxFontSize = 12.sp, stepSize = 0.5.sp),
    )
}

/** Tablet, unfolded or landscape: every section of the mode, then what's on the phone's More page. */
@Composable
private fun SideNav(nav: Nav, mode: Mode, sections: List<NavSection>, kb: List<String>, modifier: Modifier) {
    val extras = listOf(
        NavSection("knowledge", "Search knowledge", "magnifyingglass"),
        NavSection("tags", "Tags", "tag"),
        NavSection("people", "People", "person.2"),
        NavSection("allActions", "All actions", "bolt"),
        NavSection("strategies", "Strategies", "point.3.connected.trianglepath.dotted"),
        NavSection("connection", "Connection", "antenna.radiowaves.left.and.right"),
    ).filter { e -> sections.none { it.id == e.id } }
    Column(modifier.fillMaxHeight().verticalScroll(rememberScrollState()).padding(horizontal = 8.dp, vertical = 8.dp)) {
        var heading: String? = null
        sections.forEach { s ->
            if (s.group != null && s.group != heading) {
                Text(s.group, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 16.dp, top = 12.dp, bottom = 4.dp))
            }
            heading = s.group
            SideItem(nav, s, s.screen(mode, kb))
        }
        HorizontalDivider(Modifier.padding(vertical = 8.dp))
        extras.forEach { s ->
            val screen = when (s.id) {
                "allActions" -> Screen.AllActions()
                "connection" -> Screen.Connection
                else -> s.screen(mode, kb)
            }
            SideItem(nav, s, screen)
        }
    }
}

@Composable
private fun SideItem(nav: Nav, s: NavSection, screen: Screen) {
    NavigationDrawerItem(
        label = { Text(s.title) },
        selected = nav.tab == screen,
        onClick = { nav.tab(screen) },
        icon = { Icon(sectionIcon(s.id, s.icon), contentDescription = null) },
        badge = {
            when {
                s.needsYou > 0 -> Badge { Text("${s.needsYou}") }
                (s.count ?: 0) > 0 -> Text("${s.count}", style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        },
        modifier = Modifier.height(48.dp),
    )
}

@Composable
private fun TopBar(nav: Nav, switch: @Composable (Modifier) -> Unit) {
    val app = LocalApp.current
    val conn by app.connection.state.collectAsState()
    val settings by app.settings.collectAsState()
    val ctx = LocalNavContext.current
    val hello = (conn as? ConnectionState.Connected)?.hello
    var picking by remember { mutableStateOf(false) }
    val current = nav.current
    val compact = ctx.width == WidthClass.COMPACT
    val actions: @Composable () -> Unit = {
        if (current != Screen.Voice) {
            IconButton(onClick = { nav.go(Screen.Voice) }) { Icon(Icons.Default.Mic, contentDescription = "Talk") }
        }
        if (current != Screen.Assistant) {
            IconButton(onClick = { nav.go(Screen.Assistant) }) {
                Icon(Icons.Default.AutoAwesome, contentDescription = "Ask Mindmill", tint = MaterialTheme.colorScheme.primary)
            }
        }
        (current as? Screen.SessionChat)?.let { SessionMenu(nav, it) }
    }
    if (compact) {
        Row(
            Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp, top = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            switch(Modifier.weight(1f).widthIn(max = 320.dp))
            actions()
        }
    }
    Row(
        Modifier.fillMaxWidth().padding(start = if (nav.stack.size > 1) 4.dp else 16.dp, end = 4.dp, top = 2.dp, bottom = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (nav.stack.size > 1) {
            IconButton(onClick = { nav.back() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") }
        }
        Column(Modifier.weight(1f)) {
            val title = ctx.sections.firstOrNull { nav.stack.size == 1 && it.screen(ctx.mode, ctx.kbSections) == current }?.title
                ?.takeIf { current != Screen.Home } ?: current.title()
            Text(title, style = MaterialTheme.typography.titleLarge, maxLines = 2, overflow = TextOverflow.Ellipsis)
            val scopes = hello?.scopes.orEmpty()
            if (scopes.isNotEmpty()) {
                Box {
                    val scope = scopes.firstOrNull { it.id == (settings.scope ?: hello?.scope) }
                    Row(
                        Modifier.clickable { picking = true }.padding(vertical = 2.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            scope?.title ?: "Pick a project", style = MaterialTheme.typography.labelLarge,
                            color = MaterialTheme.colorScheme.primary,
                        )
                        Icon(Icons.Default.ArrowDropDown, contentDescription = "Change project", tint = MaterialTheme.colorScheme.primary)
                    }
                    DropdownMenu(expanded = picking, onDismissRequest = { picking = false }) {
                        scopes.forEach { s ->
                            DropdownMenuItem(text = { Text(s.title) }, onClick = { app.setScope(s.id); picking = false })
                        }
                    }
                }
            }
        }
        if (!compact) {
            switch(Modifier.widthIn(min = 160.dp, max = 240.dp))
            Spacer(Modifier.width(4.dp))
            actions()
        }
    }
}

/** A session's own menu in the top bar: archive it or bring it back. */
@Composable
private fun SessionMenu(nav: Nav, s: Screen.SessionChat) {
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    var open by remember { mutableStateOf(false) }
    val (loaded, _) = rememberLoad(s.id) {
        app.call("session.get", jsonOf("id" to s.id, "since" to Int.MAX_VALUE)).obj("session").bool("archived")
    }
    val archived = SessionArchive.overrides[s.id] ?: loaded.value ?: s.archived
    Box {
        IconButton(onClick = { open = true }) { Icon(Icons.Default.MoreVert, contentDescription = "Session options") }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(
                text = { Text(if (archived) "Unarchive" else "Archive") },
                onClick = { open = false; SessionArchive.toggle(app, scope, s.id, s.title, !archived) },
            )
            DropdownMenuItem(
                text = { Text("Show on the Mac") },
                onClick = { open = false; scope.launch { app.runAndReport("app.show", jsonOf("screen" to "session", "id" to s.id)) } },
            )
        }
    }
}

/** How the connection is, in the layout: quiet while connecting, a countdown while retrying, reasons and tips when stuck. */
@Composable
fun ConnectionBanner(conn: ConnectionState) {
    val app = LocalApp.current
    when (conn) {
        is ConnectionState.Connecting -> Row(
            Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically,
        ) {
            CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
            Text(
                when {
                    conn.attempt == 0 && !conn.wasConnected -> "Connecting to ${conn.macName}…"
                    conn.attempt == 0 -> "Reconnecting to ${conn.macName}…"
                    else -> "Trying ${conn.macName} again…"
                },
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 8.dp),
            )
        }
        is ConnectionState.Reconnecting -> {
            val left = secondsUntil(conn.retryAtMillis)
            NoticeBar(
                conn.problem.message(conn.macName) + if (left > 0) " Retrying in ${left}s." else " Retrying…",
                Modifier.padding(vertical = 4.dp), actionLabel = "Retry now", onAction = { app.connection.retryNow() },
            )
        }
        is ConnectionState.Unreachable -> UnreachableCard(conn)
        else -> Unit
    }
}

@Composable
private fun UnreachableCard(conn: ConnectionState.Unreachable) {
    val app = LocalApp.current
    var open by remember(conn.problem.kind) { mutableStateOf(true) }
    val left = secondsUntil(conn.retryAtMillis)
    Surface(
        color = MaterialTheme.colorScheme.errorContainer, shape = RoundedCornerShape(12.dp),
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
    ) {
        Column(Modifier.padding(start = 14.dp, end = 6.dp, top = 10.dp, bottom = 6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "Can't reach ${conn.macName}", style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.onErrorContainer, modifier = Modifier.weight(1f),
                )
                TextButton(onClick = { open = !open }) { Text(if (open) "Less" else "Why?") }
            }
            Text(conn.problem.message(conn.macName), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onErrorContainer)
            if (open) {
                conn.problem.tips(conn.macName).forEach { tip ->
                    Text("• $tip", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onErrorContainer,
                        modifier = Modifier.padding(top = 4.dp, end = 8.dp))
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 4.dp)) {
                OutlinedButton(onClick = { app.connection.retryNow() }) { Text("Retry") }
                if (left > 0) {
                    Text("Trying again in ${left}s", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onErrorContainer, modifier = Modifier.padding(start = 12.dp))
                }
            }
        }
    }
}

private fun Nav.follow(route: Any?) {
    when (route) {
        is Screen -> go(route)
        "test" -> go(Screen.Test)
        is Function0<*> -> route.invoke()
    }
}

@Composable
private fun AppNotice(nav: Nav) {
    val app = LocalApp.current
    val notice by app.notice.collectAsState()
    val n = notice ?: return
    NoticeBar(
        n.text, Modifier.padding(vertical = 4.dp),
        actionLabel = n.action,
        onAction = n.route?.let { r -> { app.dismissNotice(); nav.follow(r) } },
        onDismiss = { app.dismissNotice() },
        error = n.error,
    )
}

/** What just finished, at the bottom of the layout above the tabs; it goes away by itself. */
@Composable
private fun FlashBar(nav: Nav) {
    val app = LocalApp.current
    val flash by app.flash.collectAsState()
    val n: Notice = flash ?: return
    LaunchedEffect(n.id) {
        delay(if (n.action != null || n.error) 7_000 else 4_000)
        app.dismissFlash(n.id)
    }
    Surface(
        color = if (n.error) MaterialTheme.colorScheme.errorContainer else MaterialTheme.colorScheme.inverseSurface,
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
    ) {
        Row(Modifier.padding(start = 14.dp, end = 4.dp, top = 4.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(
                n.text, style = MaterialTheme.typography.bodyMedium,
                color = if (n.error) MaterialTheme.colorScheme.onErrorContainer else MaterialTheme.colorScheme.inverseOnSurface,
                modifier = Modifier.weight(1f).padding(vertical = 8.dp),
            )
            if (n.action != null && n.route != null) {
                TextButton(onClick = { app.dismissFlash(n.id); nav.follow(n.route) }) {
                    Text(n.action, color = if (n.error) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.inversePrimary)
                }
            }
            IconButton(onClick = { app.dismissFlash(n.id) }) {
                Icon(Icons.Default.Close, contentDescription = "Dismiss",
                    tint = if (n.error) MaterialTheme.colorScheme.onErrorContainer else MaterialTheme.colorScheme.inverseOnSurface)
            }
        }
    }
}


@Composable
private fun ScreenContent(nav: Nav, screen: Screen) {
    when (val s = screen) {
        Screen.Home -> HomeScreen(nav)
        Screen.MyWork -> MyWorkScreen(nav)
        Screen.Backlog -> BacklogScreen(nav)
        is Screen.Sessions -> SessionsScreen(nav, Mode.of(s.space))
        Screen.Voice -> VoiceScreen(nav)
        Screen.More -> MoreScreen(nav)
        Screen.Assistant -> AssistantScreen(nav)
        is Screen.Facts -> FactsScreen(nav, s.proposed, s.section)
        is Screen.Followups -> FollowupsScreen(s.filter)
        Screen.Meetings -> MeetingsScreen(nav)
        Screen.MacMeeting -> MacMeetingScreen(nav)
        Screen.Factories -> FactoriesScreen(nav)
        is Screen.FactoryEditor -> FactoryEditorScreen(nav, s.id, s.duplicate)
        Screen.Test -> TestScreen(nav)
        Screen.Connection -> ConnectionScreen(nav)
        is Screen.AllActions -> AllActionsScreen(nav, s.area)
        is Screen.RunAction -> RunActionScreen(nav, s.name, s.defaults)
        Screen.Knowledge -> KnowledgeScreen(nav)
        is Screen.NewEntry -> NewEntryScreen(nav, s.section)
        Screen.PullRequests -> PullRequestsScreen(nav)
        is Screen.PullRequest -> PullRequestScreen(nav, s.id, s.title)
        Screen.Discussions -> DiscussionsScreen(nav)
        Screen.People -> PeopleScreen()
        Screen.Tags -> TagsScreen(nav)
        is Screen.Command -> CommandScreen(s.args, s.about)
        is Screen.ActionView -> ActionViewScreen(nav, s.action, s.area, s.fallbackArgs, s.about)
        is Screen.WorkItemDetail -> WorkItemScreen(s.item)
        is Screen.Entry -> EntryScreen(nav, s.id)
        is Screen.SessionChat -> SessionChatScreen(nav, s.id, s.title)
        is Screen.MeetingDetail -> MeetingDetailScreen(s.id, s.title)
        Screen.LiveMeeting -> LiveMeetingScreen(nav)
        is Screen.Web -> WebScreen(s.title, s.url, s.preview)
    }
}
