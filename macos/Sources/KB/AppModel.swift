import AppKit
import KBCore
import KBEngine
import Observation
import SwiftUI

enum SidebarItem: Hashable {
    case section(KBSection)
    case timeline
    case pullRequests
    case today
    case reminders
    case goals
    case project
    case sessions
}

enum DiskConflict: Equatable {
    case modified
    case deleted
}

struct DeleteRequest: Identifiable, Equatable {
    var id: EntryID { entry }
    let entry: EntryID
    let title: String
    let effects: [String]

    var message: String {
        var text = "The file is removed from the knowledge base."
        if !effects.isEmpty {
            text += "\n\nThis also changes:\n" + effects.map { "• " + $0 }.joined(separator: "\n")
        }
        return text + "\n\nThe knowledge base's git history keeps earlier commits of it."
    }
}

struct NewEntryRequest: Identifiable, Equatable {
    let id = UUID()
    let project: String
    let section: KBSection
    var supersedes: EntryID?
    var suggestedTitle: String = ""
    /// Other scopes of the same project to tag the new entry with.
    var scopes: [String] = []
}

@MainActor
@Observable
final class AppModel {
    static let lastProjectKey = MindmillEngine.lastScopeKey

    /// The knowledge base, its scopes, the `kb` CLI, the actions and the companion hub. The app observes it and
    /// forwards to it, so what the phone or a voice session changes shows at once.
    let engine: MindmillEngine

    var rootPath: String { engine.rootPath }
    var rootOverride: Bool { engine.rootOverride }
    var index: KBIndex { engine.index }
    var loadError: KBLoadError? { engine.loadError }

    /// Everything the sidebar, lists, timeline and counts show is limited to this project.
    var projectID: String? { engine.scope }
    var sidebarSelection: SidebarItem? = .section(.decisions)
    private(set) var selectedEntryID: EntryID?
    var searchText = ""
    var searchAllProjects = false

    var document: EntryDocument?
    var isEditing = false
    var diskConflict: DiskConflict?
    var showUnsavedPrompt = false
    var newEntryRequest: NewEntryRequest?
    var deleteRequest: DeleteRequest?
    var errorMessage: String?
    var notice: String?

    /// Bumped on every reload, so views holding their own state can refresh from disk.
    var indexVersion: Int { engine.indexVersion }
    var dailyDate = KBDate.today()
    private(set) var dailyPlan: DailyPlan?
    var shell: LoginShell.Resolved? {
        get { engine.shell }
        set { engine.shell = newValue }
    }
    var busyEntries: Set<EntryID> = []
    var inboxSelection: Set<EntryID> = []
    /// Two or more entries picked in a list (⌘-click, ⇧-click): the detail shows actions for all of them.
    var multiSelection: Set<EntryID> = []
    var followupCloseRequest: FollowupCloseRequest?
    var backlogCreateRequest: BacklogCreateRequest?
    var backlogBatchRequest: BacklogBatchRequest?
    var newPBIRequest: NewPBIRequest?
    var captureRequests: [String: WebCaptureRequest] = [:]
    var projectSettingsRequest: ProjectSettingsRequest?
    var newMeetingRequest: NewMeetingRequest?
    var morning: ClaudeChat {
        get { engine.routines.morning }
        set { engine.routines.morning = newValue }
    }
    var email: ClaudeChat {
        get { engine.routines.email }
        set { engine.routines.email = newValue }
    }
    var emailSync: EmailSyncState {
        get { engine.routines.emailSync }
        set { engine.routines.emailSync = newValue }
    }
    var reminders: [Reminder] = []
    var selectedReminderID: String?
    var todaySelection: TodaySelection?
    var todayAllScopes = UserDefaults.standard.bool(forKey: "todayAllScopes")
    var todayHiddenMeetings: Set<String> = []
    var people: People {
        get { engine.plan.people }
        set { engine.plan.people = newValue }
    }
    var peopleLoaded: Bool {
        get { engine.plan.peopleLoaded }
        set { engine.plan.peopleLoaded = newValue }
    }
    var peopleSyncing: Bool {
        get { engine.plan.peopleSyncing }
        set { engine.plan.peopleSyncing = newValue }
    }
    var reminderSheet: ReminderSheetRequest?
    var goals: [Goal] = []
    var selectedGoalID: String?
    var goalSheet: GoalSheetRequest?
    var goalChats: [String: ClaudeChat] {
        get { engine.plan.goalChats }
        set { engine.plan.goalChats = newValue }
    }
    var calendar: ClaudeChat {
        get { engine.routines.calendar }
        set { engine.routines.calendar = newValue }
    }
    var calendarSync: CalendarSyncState {
        get { engine.routines.calendarSync }
        set { engine.routines.calendarSync = newValue }
    }
    /// The claude.ai Microsoft 365 connector's status from the latest Claude session (`connected`, `needs-auth`, …).
    var microsoft365Status = ""
    /// The servers `claude mcp list` showed last, and when.
    var connectorServers: [ClaudeConnectors.Server] = []
    var connectorsChecked: Date?
    var connectorsChecking = false
    @ObservationIgnored var connectorTimer: Timer?
    /// When the user pressed Reconnect: KB checks often for a while after.
    @ObservationIgnored var connectorFixStarted: Date?
    /// Meetings whose window should start taking notes as soon as it opens.
    var pendingStart: Set<EntryID> = []
    @ObservationIgnored var backgroundStarted = false {
        didSet {
            engine.sessions.backgroundChecks = backgroundStarted
            engine.plan.backgroundStarted = backgroundStarted
        }
    }
    @ObservationIgnored var lastAutoDay: String?
    @ObservationIgnored var syncTimer: Timer?
    @ObservationIgnored var morningAfterSync = false
    /// Meetings created with "Prepare with Claude", started when their window opens.
    var pendingPrepare: Set<EntryID> = []
    var askConversations: [String: AskConversation] = [:]
    /// When the goal coach of each goal last had a message, so Plan → Sessions lists it.
    var goalCoachUpdated: [String: Date] {
        get { engine.plan.goalCoachUpdated }
        set { engine.plan.goalCoachUpdated = newValue }
    }
    /// Meeting chats kept in Application Support, by meeting: how many messages, and when they last changed.
    var meetingChats: [EntryID: (count: Int, updated: Date)] = [:]
    @ObservationIgnored var meetingChatsLoaded = false
    /// Conversations that aren't sessions (a meeting's chat, a goal's coach, Ask), archived from Plan → Sessions:
    /// when, so a newer message brings one back.
    var planArchivedLinks: [String: Double] = UserDefaults.standard.dictionary(forKey: "planArchivedLinks") as? [String: Double] ?? [:] {
        didSet { UserDefaults.standard.set(planArchivedLinks, forKey: "planArchivedLinks") }
    }
    /// Claude session windows, newest first; saved to Application Support.
    /// Plan (knowledge and planning) or Build (implementation sessions).
    var mode: AppMode = AppMode(rawValue: UserDefaults.standard.string(forKey: AppSettingsKeys.launchMode) ?? "")
        ?? AppMode(rawValue: UserDefaults.standard.string(forKey: "appMode") ?? "") ?? .plan {
        didSet {
            SplitViewMemory.swap(from: oldValue.rawValue, to: mode.rawValue)
            UserDefaults.standard.set(mode.rawValue, forKey: "appMode")
        }
    }
    /// Build mode's detail: nil is the overview, otherwise a session id.
    var buildSelection: String?
    var factoryEditor: FactoryEditRequest?
    var workItemDetails: [Int: WorkItemDetail] = [:]
    var claudeFind = ClaudeFind()
    /// Counts ⌘F presses, so the view in front can open its find bar.
    var findRequest = 0
    var workItemDetailLoading: Set<Int> = []
    var projectPane: ProjectPane = .home
    var addProjectRequest: AddProjectRequest?
    var strategiesSheet: StrategiesSheetRequest?
    var newLeadRequest: NewLeadRequest?
    var factCheck = FactCheckState()
    var followupWatch: FollowupWatchState {
        get { engine.plan.followupWatch }
        set { engine.plan.followupWatch = newValue }
    }
    var scopesSheet = false
    /// The first-run setup was finished or skipped once.
    var onboardingCompleted = UserDefaults.standard.bool(forKey: OnboardingGate.completedKey)
    /// KB → Set Up KB… opens the setup again.
    var onboardingForced = false
    /// Once the setup shows, it stays until finished, even when its reason goes away halfway.
    var onboardingInProgress = false
    /// Bumped by Reset Layout so the window's columns are built again.
    var layoutGeneration = 0
    /// `kb backlog duplicates` per scope: tracker items found for the proposals waiting to be created.
    var duplicateChecked: [String: Date] { engine.backlog.checked }
    var duplicateChecking: Set<String> { engine.backlog.checking }
    var duplicateErrors: [String: String] { engine.backlog.errors }
    /// Each tracker's sprints around today (`kb sprint status`), and what Mindmill remembers of them.
    var sprintReport: SprintReport? { engine.sprints.report }
    var sprintWatch: SprintWatch { engine.sprints.watch }
    var sprintsChecking: Bool { engine.sprints.checking }
    var sprintReviewRequest: SprintReviewRequest?
    var sprintCreating: Set<String> = []
    var selectedWorkItem: Int?
    /// Mindmill's own tracker per scope, loaded when shown.
    var localTrackers: [String: LocalTracker] = [:]
    var selectedLocalItem: Int?
    /// Folded sections' open or closed state for this run of the app, by key (`FoldMemory.swift`).
    var foldStates: [String: Bool] = [:]
    /// A reminder or goal opened from the search results.
    var searchPick: SearchPick?
    var showProposedBacklog = false
    /// Facts' detail pane shows the proposed facts instead of an entry.
    var showProposedFacts = false
    /// Backlog's "Tasks to close" list in the content area.
    var showLooseTasks = false
    /// Tasks being changed in Azure DevOps right now.
    var busyTasks: Set<Int> = []
    /// PBIs and bugs being moved or changed in Azure DevOps right now.
    var busyWorkItems: Set<Int> = []
    /// Everything in a past sprint, finished work too, read when the sprint is picked in Backlog.
    var sprintItems: [String: [TrackerBacklog.Item]] = [:]
    var sprintLoading: Set<String> = []
    /// PBIs and bugs found in Azure DevOps for a search, finished ones included.
    var workItemSearch = WorkItemSearch()
    /// What each list's own search field holds, by list.
    var listSearch: [String: String] = [:]
    /// Signing Claude Code in again when a session's login fails.
    let claudeSignIn = ClaudeSignIn()
    /// Remote access for paired phones (Settings → Remote).
    var remote: RemoteServer { engine.remote }
    let pusher = APNsPusher()
    let testPlatform = MacTestPlatform()
    var actions: ActionLayer { engine.actions }
    @ObservationIgnored lazy var actionServer = LocalActionServer(layer: actions)
    var voiceConversations: [String: VoiceConversation] {
        get { engine.voiceConversations }
        set { engine.voiceConversations = newValue }
    }
    let voiceMode = MacVoiceMode()
    var realtimeRelays: [String: RealtimeRelay] {
        get { engine.realtimeRelays }
        set { engine.realtimeRelays = newValue }
    }
    /// `mindmill@mindmill` is installed in Claude Code; nil until checked.
    var claudePluginInstalled: Bool?
    var installingClaudePlugin = false
    /// The brain and the model for each task (Settings → AI).
    var aiSetup: AISetup {
        get { engine.aiSetup }
        set { engine.aiSetup = newValue }
    }
    /// Prompts sent from session and Ask fields, for ↑ and ↓.
    var promptHistory = PromptHistory(entries: UserDefaults.standard.stringArray(forKey: AppModel.promptHistoryKey) ?? [])
    /// Signing the Azure CLI in again when the Azure DevOps tools say its sign-in expired.
    let azureSignIn = AzureCLISignIn()
    var selectedPR: Int?
    /// `kb pr show` per pull request: its comment threads.
    var prDetails: [Int: PullRequest] = [:]
    var prDetailLoading: Set<Int> = []
    var prBusy: Set<Int> = []
    var completePRRequest: CompletePRRequest?
    /// Ready PRs the user said "Not Now" to in a session, until KB restarts.
    var completeAsksDeclined: Set<Int> = []
    var prCommentsRequest: PRCommentsRequest?
    var implementRequest: ImplementRequest?
    /// Completed pull requests that left a worktree or branch behind.
    var donePRs: CompletedPRs?
    /// Merged PRs auto clean-up has already tried this launch.
    @ObservationIgnored var autoCleanedPRs: Set<Int> = []
    /// Which entries are shared with the team, and how far each has got.
    var sharing = SharingStatus()
    @ObservationIgnored var sharingTask: Task<Void, Never>?
    @ObservationIgnored var sharingRefreshed = Date.distantPast
    /// Entries whose sharing is being changed.
    var sharingBusy: Set<EntryID> = []
    /// Branch and distance from the remote of each repository, by scope.
    var repoStates: [String: RepoState] = [:]
    var reposLoading = false
    var reposPulling: Set<String> = []
    var donePRsLoading = false
    var prCleanupRequest: CompletedPRs.PR?
    /// Merged pull requests to clean up together, from My Work.
    var bulkCleanupRequest: BulkCleanupRequest?
    var newDiscussionRequest: NewDiscussionRequest?
    var newResearchRequest: NewResearchRequest?
    var architectureTab: ArchitectureTab = .notes
    var projectDocs: [String: ProjectDocList] = [:]
    var projectDocsLoading: Set<String> = []
    var projectDocsError: [String: String] = [:]
    var selectedProjectDoc: String?
    /// A doc just created, to open in edit mode.
    var editProjectDoc: String?
    var docScanRequest: DocScanRequest?
    var newDocRequest: NewDocRequest?
    var saveDocsRequest: SaveDocsRequest?
    var diagramRequest: DiagramRequest?
    var newMailReferenceRequest: NewMailReferenceRequest?
    var concludeDiscussionRequest: ConcludeDiscussionRequest?
    @ObservationIgnored var trackerTimer: Timer?
    @ObservationIgnored var pullRequestTimer: Timer?
    var factChecker = ClaudeChat()
    var scopeTags = ScopeTagState()
    var scopeTagger = ClaudeChat()
    var tagWatch = TagWatchState()
    var tagger = ClaudeChat()
    /// Tags picked in each list's tag filter, by list.
    var tagFilter: [String: Set<String>] = [:]
    /// The knowledge base's own tags on tracker items, never written to the tool unless aligned.
    var itemTags = ItemTags()
    /// Follow-ups that may say the same thing, waiting for the user.
    var mergeProposals: [FollowupMergeProposal] = []
    var findingDuplicates: Bool {
        get { engine.plan.findingDuplicates }
        set { engine.plan.findingDuplicates = newValue }
    }
    /// Claude's suggested links per fact id, until accepted or rejected; rejected ones aren't suggested again.
    var factLinkSuggestions: [String: [FactLinkSuggestion]] {
        get { engine.plan.factLinkSuggestions }
        set { engine.plan.factLinkSuggestions = newValue }
    }
    var factLinkRejected: [String: [String]] {
        get { engine.plan.factLinkRejected }
        set { engine.plan.factLinkRejected = newValue }
    }
    var suggestingLinks: Set<EntryID> {
        get { engine.plan.suggestingLinks }
        set { engine.plan.suggestingLinks = newValue }
    }
    @ObservationIgnored var factGraphPending: Int?
    var factGraphCache: (key: Int, points: [String: FactGraph.Point])?
    var selectedSessionID: String?
    @ObservationIgnored var meetingControllers: [EntryID: MeetingController] = [:]
    @ObservationIgnored var openWindowAction: ((String, String?) -> Void)?
    @ObservationIgnored var openSettingsAction: (() -> Void)?

    @ObservationIgnored private var pendingNavigation: (() -> Void)?

    init() {
        if let last = UserDefaults.standard.string(forKey: "appMode"),
           let launch = AppMode(rawValue: UserDefaults.standard.string(forKey: AppSettingsKeys.launchMode) ?? "") {
            SplitViewMemory.swap(from: last, to: launch.rawValue)
            UserDefaults.standard.set(launch.rawValue, forKey: "appMode")
        }
        let start = MindmillEngine.startRoot()
        engine = MindmillEngine(rootPath: start.path, rootOverride: start.override, platform: MacPlatform.make())
        engine.platform.presenter = self
        engine.platform.actionEndpoint = actionServer
        engine.myNames = { [weak self] in self?.myNames ?? [] }
        engine.onTrackerChanged = { [weak self] in self?.refreshTracker(force: true) }
        wireSessions()
        engine.onReload.append { [weak self] loaded in self?.engineReloaded(loaded) }
        engine.structureExtras = { [weak self] scope in self?.structureExtras(scope: scope) ?? StructureExtras() }
        AppAppearance.apply()
        reload()
        startWatching()
        resolveShell()
        wireClaudeSignIn()
        wireAzureSignIn()
        registerActions()
        actionServer.start()
        startRemoteIfEnabled()
        loadFactLinkRejected()
    }

    var rootURL: URL { KBConfig.rootURL(for: rootPath) }

    // MARK: The tracker cache (the engine's)

    var tracker: TrackerBacklog? {
        get { engine.tracker.backlog }
        set { engine.tracker.backlog = newValue }
    }
    var trackerLoading: Bool { engine.tracker.backlogLoading }
    var trackerError: String? { engine.tracker.backlogError }
    var trackerFetched: Date? { engine.tracker.backlogFetched }
    var myWork: MyWork? { engine.tracker.myWork }
    var myWorkLoading: Bool { engine.tracker.myWorkLoading }
    var myWorkError: String? { engine.tracker.myWorkError }
    var myWorkFetched: Date? { engine.tracker.myWorkFetched }
    var pullRequests: PullRequestList? {
        get { engine.tracker.pullRequests }
        set { engine.tracker.pullRequests = newValue }
    }
    var pullRequestsLoading: Bool { engine.tracker.pullRequestsLoading }
    var pullRequestsError: String? { engine.tracker.pullRequestsError }
    var pullRequestsFetched: Date? { engine.tracker.pullRequestsFetched }

    var project: KBProject? { projectID.flatMap { index.project($0) } }

    var windowTitle: String {
        guard let project else { return "Mindmill" }
        return "Mindmill — \(project.title)"
    }

    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    func pickSearchResult(_ pick: SearchPick) {
        navigate { [self] in
            multiSelection = []
            closeDocument()
            selectedWorkItem = nil
            searchPick = pick
        }
    }

    var searchResults: [(project: KBProject, entries: [KBEntry])] {
        index.search(searchText, project: searchAllProjects ? nil : projectID)
    }

    var currentSection: KBSection? {
        if case .section(let s) = sidebarSelection { return s }
        return nil
    }

    // MARK: Loading

    func reload() {
        engine.reload()
    }

    /// What the app derives from the knowledge base, after every reload (the engine's, whoever asked for it).
    private func engineReloaded(_ loaded: Bool) {
        for scope in localTrackers.keys {
            let fresh = LocalTracker.load(scope: scope, root: rootURL)
            if fresh != localTrackers[scope] { localTrackers[scope] = fresh }
        }
        if loaded {
            let tags = ItemTags.load(root: rootURL)
            if tags != itemTags { itemTags = tags }
            let merges = FollowupMergeProposal.load(root: rootURL, index: index)
            if merges != mergeProposals { mergeProposals = merges }
        }
        dailyPlan = DailyPlan.load(date: dailyDate, root: rootURL)
        loadTodayHidden()
        reminders = Reminders.load(root: rootURL)
        goals = Goals.load(root: rootURL)
        if let sel = selectedGoalID, !goals.contains(where: { $0.id == sel }) { selectedGoalID = nil }
        if let sel = selectedReminderID, !reminders.contains(where: { $0.id == sel }) { selectedReminderID = nil }
        scheduleSharingRefresh()
        engine.sessions.reloadStrategies()
        factWatchIndexChanged()
        followupWatchIndexChanged()
        scopeWatchIndexChanged()
        tagWatchIndexChanged()
        testScopesChanged()
        let existing = Set(index.entries.keys)
        inboxSelection = inboxSelection.intersection(existing)
        multiSelection = multiSelection.intersection(existing)
        if multiSelection.count < 2 { multiSelection = [] }
        reconcileDocumentWithDisk()
    }

    /// Watches the KB folder and every repo's `knowledgebase/` folder that exists.
    func startWatching() {
        engine.startWatching()
    }

    func changeRoot(to path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            try KBConfig.saveRootPath(trimmed)
        } catch {
            errorMessage = "Could not write \(KBConfig.defaultConfigURL.path): \(error.localizedDescription)"
            return
        }
        navigate { [self] in
            try? engine.changeRoot(to: trimmed, save: false)
            closeDocument()
            reload()
            startWatching()
        }
    }

    /// Keeps the open document in step with the file on disk.
    private func reconcileDocumentWithDisk() {
        guard let doc = document else { return }
        switch DiskSync.decide(doc, diskText: try? String(contentsOf: doc.url, encoding: .utf8)) {
        case .unchanged: break
        case .reload(let fresh):
            document = fresh
            diskConflict = nil
        case .conflictModified: diskConflict = .modified
        case .conflictDeleted: diskConflict = .deleted
        case .close: closeDocument()
        }
    }

    func reloadFromDisk() {
        guard let doc = document else { return }
        if let text = try? String(contentsOf: doc.url, encoding: .utf8) {
            document = EntryDocument(id: doc.id, url: doc.url, text: text)
        } else {
            closeDocument()
        }
        diskConflict = nil
    }

    func keepMine() {
        guard var doc = document else { return }
        // Compare later disk changes against what is there now, so the banner does not return for this one.
        doc.diskText = (try? String(contentsOf: doc.url, encoding: .utf8)) ?? ""
        if diskConflict == .deleted { doc.diskText = nil }
        document = doc
        diskConflict = nil
    }

    // MARK: Navigation

    /// Runs `action` now, or after the user has saved or discarded unsaved changes.
    func navigate(_ action: @escaping () -> Void) {
        if let doc = document, doc.isDraft, !doc.isNew {
            // A draft keeps itself: whatever was typed stays in Drafts until it is saved.
            if doc.isDirty { save(publish: false) }
            action()
        } else if let doc = document, doc.isDirty {
            pendingNavigation = action
            showUnsavedPrompt = true
        } else {
            action()
        }
    }

    func resolveUnsaved(save shouldSave: Bool) {
        let action = pendingNavigation
        pendingNavigation = nil
        showUnsavedPrompt = false
        if shouldSave {
            guard save() else { return }
        } else {
            closeDocument()
        }
        action?()
    }

    func cancelNavigation() {
        pendingNavigation = nil
        showUnsavedPrompt = false
    }

    func selectProject(_ id: String) {
        guard id != projectID else { return }
        navigate { [self] in setProject(id) }
    }

    /// `keepSearchScope` is for opening a result of an all-projects search, which should stay open.
    func setProject(_ id: String, keepSearchScope: Bool = false) {
        guard index.project(id) != nil, id != projectID else { return }
        engine.scope = id
        multiSelection = []
        selectedWorkItem = nil
        showProposedBacklog = false
        showProposedFacts = false
            showLooseTasks = false
        UserDefaults.standard.set(id, forKey: Self.lastProjectKey)
        rememberScope(id)
        testProjectOpened(id)
        if !keepSearchScope { searchAllProjects = false }
        closeDocument()
        if sidebarSelection == nil { sidebarSelection = .section(.decisions) }
        autoSelectOverview()
    }

    func selectSidebar(_ item: SidebarItem?) {
        mode = .plan
        multiSelection = []
        guard item != sidebarSelection else { return }
        navigate { [self] in
            sidebarSelection = item
            todaySelection = nil
            selectedWorkItem = nil
        showProposedBacklog = false
        showProposedFacts = false
            showLooseTasks = false
            closeDocument()
            autoSelectOverview()
        }
    }

    private func autoSelectOverview() {
        guard sidebarSelection == .section(.overview), let p = projectID else { return }
        let id = EntryID(project: p, section: .overview, stem: "overview")
        if index.entry(id) != nil { openNow(id) }
    }

    func selectEntry(_ id: EntryID?) {
        guard id != selectedEntryID else { return }
        navigate { [self] in
            if let id { open(id) } else { closeDocument() }
        }
    }

    /// Opens an entry, switching project and section to where it lives so it is never shown under another project.
    func open(_ id: EntryID) {
        // An entry tagged with the selected scope opens right there, wherever its file lives.
        let shownHere = projectID.map { scope in index.entry(id).map { index.shows($0, in: scope) } ?? false } ?? false
        if id.project != projectID && !shownHere { setProject(id.project, keepSearchScope: isSearching) }
        if !(id.section == .decisions && sidebarSelection == .timeline) {
            sidebarSelection = .section(id.section)
        }
        openNow(id)
    }

    func openNow(_ id: EntryID) {
        do {
            document = try KBStore.load(id, root: rootURL)
            selectedEntryID = id
            selectedWorkItem = nil
        showProposedBacklog = false
        showProposedFacts = false
            showLooseTasks = false
            diskConflict = nil
            isEditing = document?.isDraft ?? false
        } catch {
            errorMessage = "Could not open \(id.rawValue): \(error.localizedDescription)"
        }
    }

    /// Opens a link from an entry: a `kb://` URL, an entry id, a relative link to another entry's file,
    /// or anything else in the default app.
    func openLink(_ raw: String) {
        if let url = URL(string: raw), url.scheme == "kb" {
            handle(url: url)
            return
        }
        var resolved = EntryID(raw)
        if resolved == nil, let url = URL(string: raw), url.isFileURL {
            resolved = EntryID(fileURL: url, root: rootURL)
            if resolved == nil {
                NSWorkspace.shared.open(url)
                return
            }
        }
        guard let id = resolved else {
            if let url = URL(string: raw), url.scheme != nil { NSWorkspace.shared.open(url) }
            return
        }
        guard index.entry(id) != nil else {
            errorMessage = "\(id.rawValue) does not exist."
            return
        }
        navigate { [self] in
            searchText = ""
            mode = .plan
            open(id)
        }
    }

    func handle(url: URL) {
        guard url.scheme == "kb" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if handleWorkflowURL(host: url.host ?? "", items: items) { return }
        if let raw = items.first(where: { $0.name == "id" })?.value {
            guard let id = EntryID(raw), index.entry(id) != nil else {
                errorMessage = "No entry with id \(raw)."
                return
            }
            let action = items.first(where: { $0.name == "action" })?.value
            navigate { [self] in
                searchText = ""
                mode = .plan
                open(id)
                if let action { performEntryAction(action, id: id) }
            }
        } else if let p = items.first(where: { $0.name == "project" })?.value {
            guard index.project(p) != nil else {
                errorMessage = "No project with id \(p)."
                return
            }
            navigate { [self] in
                searchText = ""
                mode = .plan
                setProject(p)
                closeDocument()
                let hasOverview = index.entry(EntryID(project: p, section: .overview, stem: "overview")) != nil
                let named = items.first(where: { $0.name == "section" })?.value.flatMap(KBSection.init(rawValue:))
                sidebarSelection = .section(named ?? (hasOverview ? .overview : .decisions))
                autoSelectOverview()
            }
        }
    }

    func closeDocument() {
        document = nil
        selectedEntryID = nil
        diskConflict = nil
        isEditing = false
    }

    // MARK: Editing

    /// `publish` turns a draft into a real entry; `false` keeps it a draft (switching away from it).
    @discardableResult
    func save(publish: Bool = true) -> Bool {
        guard var doc = document else { return false }
        let wasDraft = doc.isDraft
        if publish, wasDraft { doc.frontmatter.set("draft", nil) }
        guard doc.isDirty || diskConflict != nil else { return true }
        if publish, wasDraft, doc.title.trimmingCharacters(in: .whitespaces).isEmpty {
            errorMessage = "Give it a title before saving."
            return false
        }
        do {
            let result = try KBStore.save(&doc, root: rootURL)
            document = doc
            selectedEntryID = doc.id
            diskConflict = nil
            if !result.superseded.isEmpty {
                notice = "Marked \(result.superseded.map(\.rawValue).joined(separator: ", ")) as superseded."
            }
            if !result.missing.isEmpty {
                errorMessage = "Saved, but these superseded ids do not exist and were left alone: \(result.missing.joined(separator: ", "))"
            }
            if publish, wasDraft {
                isEditing = false
                notice = "Saved “\(doc.title)”."
                if SharingStatus.sharedByDefault(doc.id.section), sharing.repos[doc.id.project]?.path != nil {
                    setShared(doc.id, true, quiet: true)
                }
            } else if sharingState(doc.id).isShared {
                pushShared(doc.id)
            }
            reload()
            return true
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
            return false
        }
    }

    /// The scope a new meeting goes in: the selected one, else the first project-wide scope.
    var meetingScope: String? {
        projectID ?? index.projects.first(where: \.wide)?.id ?? index.projects.first?.id
    }

    /// A spontaneous meeting: created for now and opened straight into note-taking.
    func startQuickMeeting(title: String? = nil, project: String? = nil, attendees: [String] = []) {
        guard let p = project ?? meetingScope else { return }
        let now = Date()
        let t = (title?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? "Quick chat \(MeetingController.clock(now))"
        do {
            let doc = try MeetingFile.create(project: p, title: t, date: KBDate.today(now), start: MeetingController.clock(now),
                                             attendees: attendees, root: rootURL)
            reload()
            takeNotes(doc.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestNewEntry(_ section: KBSection) {
        guard let p = projectID else { return }
        if section == .meetings {
            newMeetingRequest = NewMeetingRequest(project: p)
            return
        }
        newEntryRequest = NewEntryRequest(project: p, section: section)
    }

    func requestSupersede() {
        guard let doc = document, doc.id.section == .decisions, doc.status == .active, let p = projectID,
              doc.id.project == p else { return }
        newEntryRequest = NewEntryRequest(project: p, section: .decisions, supersedes: doc.id, suggestedTitle: doc.title)
    }

    func createEntry(_ request: NewEntryRequest, title: String) {
        // New entries always go into the selected project.
        guard request.project == projectID else {
            errorMessage = "The selected project changed; nothing was created."
            return
        }
        navigate { [self] in
            do {
                if let old = request.supersedes {
                    let tags = index.entry(old)?.tags ?? []
                    let doc = try KBStore.newDocument(project: request.project, section: .decisions, title: title,
                                                      root: rootURL, supersedes: [old], tags: tags)
                    searchText = ""
                    sidebarSelection = .section(.decisions)
                    document = doc
                    selectedEntryID = doc.id
                    diskConflict = nil
                    isEditing = true
                } else {
                    var doc = try KBStore.newDocument(project: request.project, section: request.section, title: title, root: rootURL)
                    if request.section != .overview { doc.frontmatter.set("draft", .string("true")) }
                    let extra = request.scopes.filter { $0 != request.project }
                    if !extra.isEmpty { doc.frontmatter.set("scopes", .list([request.project] + extra)) }
                    // Scopes picked by hand in the sheet stay; otherwise the tagger sets them once it is saved.
                    if !extra.isEmpty { markScopesManual([doc.id]) }
                    try KBStore.save(&doc, root: rootURL)
                    reload()
                    searchText = ""
                    sidebarSelection = .section(request.section)
                    openNow(doc.id)
                    isEditing = true
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func revealInFinder() {
        guard let doc = document, !doc.isNew else { return }
        NSWorkspace.shared.activateFileViewerSelecting([doc.url])
    }

    func openInDefaultEditor() {
        guard let doc = document, !doc.isNew else { return }
        NSWorkspace.shared.open(doc.url)
    }

    func toggleEditing() {
        guard document != nil else { return }
        isEditing.toggle()
    }

    var hasUnsavedChanges: Bool { document?.isDirty ?? false }
}
