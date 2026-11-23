import AppKit
import KBCore
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
    static let lastProjectKey = "lastProjectID"

    var rootPath: String
    private(set) var rootOverride: Bool
    var index: KBIndex = .empty
    var loadError: KBLoadError?

    /// Everything the sidebar, lists, timeline and counts show is limited to this project.
    private(set) var projectID: String?
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
    private(set) var indexVersion = 0
    var dailyDate = KBDate.today()
    private(set) var dailyPlan: DailyPlan?
    var shell: LoginShell.Resolved?
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
    var morning = ClaudeChat()
    var email = ClaudeChat()
    var emailSync = EmailSyncState()
    var reminders: [Reminder] = []
    var selectedReminderID: String?
    var todaySelection: TodaySelection?
    var todayAllScopes = UserDefaults.standard.bool(forKey: "todayAllScopes")
    var todayHiddenMeetings: Set<String> = []
    var people = People()
    @ObservationIgnored var peopleLoaded = false
    var peopleSyncing = false
    var reminderSheet: ReminderSheetRequest?
    var goals: [Goal] = []
    var selectedGoalID: String?
    var goalSheet: GoalSheetRequest?
    @ObservationIgnored var goalChats: [String: ClaudeChat] = [:]
    var calendar = ClaudeChat()
    var calendarSync = CalendarSyncState()
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
    @ObservationIgnored var backgroundStarted = false
    @ObservationIgnored var lastAutoDay: String?
    @ObservationIgnored var syncTimer: Timer?
    @ObservationIgnored var morningAfterSync = false
    /// Meetings created with "Prepare with Claude", started when their window opens.
    var pendingPrepare: Set<EntryID> = []
    var askConversations: [String: AskConversation] = [:]
    /// When the goal coach of each goal last had a message, so Plan → Sessions lists it.
    var goalCoachUpdated: [String: Date] = [:]
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
    var factories: [Factory] = []
    var factoryEditor: FactoryEditRequest?
    var workItemDetails: [Int: WorkItemDetail] = [:]
    var claudeFind = ClaudeFind()
    /// Counts ⌘F presses, so the view in front can open its find bar.
    var findRequest = 0
    var workItemDetailLoading: Set<Int> = []
    /// Side conversations on factory questions, by question id: copies of the asking session, never saved.
    var factoryAsides: [UUID: ClaudeChat] = [:]
    @ObservationIgnored var coverageChecking: Set<UUID> = []
    @ObservationIgnored var factoriesLoaded = false
    @ObservationIgnored var factoryLastTick = Date.distantPast
    @ObservationIgnored var factoryAssigning: Set<Int> = []
    var scans: [ScanRun] = []
    @ObservationIgnored var scanChats: [String: ClaudeChat] = [:]
    @ObservationIgnored var scansLastRead = Date.distantPast
    @ObservationIgnored var scansLoaded = false
    var projectPane: ProjectPane = .home
    var addProjectRequest: AddProjectRequest?
    var scanApplying: Set<String> = []
    var scanActivity: [String: String] = [:]
    var strategies: [Strategy] = []
    var strategiesSheet: StrategiesSheetRequest?
    var newLeadRequest: NewLeadRequest?
    var factCheck = FactCheckState()
    var followupWatch = FollowupWatchState()
    var scopesSheet = false
    /// The first-run setup was finished or skipped once.
    var onboardingCompleted = UserDefaults.standard.bool(forKey: OnboardingGate.completedKey)
    /// KB → Set Up KB… opens the setup again.
    var onboardingForced = false
    /// Once the setup shows, it stays until finished, even when its reason goes away halfway.
    var onboardingInProgress = false
    /// Bumped by Reset Layout so the window's columns are built again.
    var layoutGeneration = 0
    var myWork: MyWork?
    var myWorkLoading = false
    var myWorkError: String?
    var myWorkFetched: Date?
    var tracker: TrackerBacklog?
    var trackerLoading = false
    var trackerError: String?
    var trackerFetched: Date?
    var selectedWorkItem: Int?
    /// Mindmill's own tracker per scope, loaded when shown.
    var localTrackers: [String: LocalTracker] = [:]
    var selectedLocalItem: Int?
    @ObservationIgnored var trackerKindCache: [String: String] = [:]
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
    let remote = RemoteServer()
    let testing = TestCenter()
    let actions = ActionLayer()
    @ObservationIgnored lazy var actionServer = LocalActionServer(layer: actions)
    var voiceConversations: [String: VoiceConversation] = [:]
    let voiceMode = MacVoiceMode()
    @ObservationIgnored var realtimeRelays: [String: RealtimeRelay] = [:]
    /// `kb@kb` is installed in Claude Code; nil until checked.
    var claudePluginInstalled: Bool?
    var installingClaudePlugin = false
    /// The brain and the model for each task (Settings → AI).
    var aiSetup = AISetup.migrated(defaults: .standard) {
        didSet { aiSetup.save(defaults: .standard) }
    }
    /// Prompts sent from session and Ask fields, for ↑ and ↓.
    var promptHistory = PromptHistory(entries: UserDefaults.standard.stringArray(forKey: AppModel.promptHistoryKey) ?? [])
    /// Signing the Azure CLI in again when the Azure DevOps tools say its sign-in expired.
    let azureSignIn = AzureCLISignIn()
    var pullRequests: PullRequestList?
    var pullRequestsLoading = false
    var pullRequestsError: String?
    var pullRequestsFetched: Date?
    /// When KB last queued each pull request's expired build again.
    @ObservationIgnored var expiredBuildRetries: [Int: Date] = [:]
    /// When each session last sent the overview session a message.
    @ObservationIgnored var reportedToOverseer: [String: Date] = [:]
    var selectedPR: Int?
    /// `kb pr show` per pull request: its comment threads.
    var prDetails: [Int: PullRequest] = [:]
    var prDetailLoading: Set<Int> = []
    var prBusy: Set<Int> = []
    var completePRRequest: CompletePRRequest?
    /// Ready PRs the user said "Not Now" to in a session, until KB restarts.
    var completeAsksDeclined: Set<Int> = []
    /// When each Build session was first seen done; nil until it has been worked out once (see `DoneArchive`).
    var sessionsDoneSince: [String: Date]? = (UserDefaults.standard.dictionary(forKey: AppModel.doneSinceKey) as? [String: Double])?
        .mapValues(Date.init(timeIntervalSince1970:))
    static let doneSinceKey = "sessionsDoneSince"
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
    var followupChecker = ClaudeChat()
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
    var findingDuplicates = false
    /// Claude's suggested links per fact id, until accepted or rejected; rejected ones aren't suggested again.
    var factLinkSuggestions: [String: [FactLinkSuggestion]] = [:]
    var factLinkRejected: [String: [String]] = [:]
    var suggestingLinks: Set<EntryID> = []
    @ObservationIgnored var factGraphPending: Int?
    var factGraphCache: (key: Int, points: [String: FactGraph.Point])?
    @ObservationIgnored var quizStatsCache: QuizStats?
    @ObservationIgnored var crewTimer: Timer?
    @ObservationIgnored var crewDirty = true
    @ObservationIgnored var crewWritten = Date.distantPast
    @ObservationIgnored var crewLastState: CrewState?
    var sessions: [WorkSession] = []
    var selectedSessionID: String?
    @ObservationIgnored var sessionsLoaded = false
    @ObservationIgnored var meetingControllers: [EntryID: MeetingController] = [:]
    @ObservationIgnored var openWindowAction: ((String, String?) -> Void)?
    @ObservationIgnored var openSettingsAction: (() -> Void)?

    @ObservationIgnored private var pendingNavigation: (() -> Void)?
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var teamWatchers: [FileWatcher] = []
    @ObservationIgnored private var watchedTeamPaths: Set<String> = []

    init() {
        if let last = UserDefaults.standard.string(forKey: "appMode"),
           let launch = AppMode(rawValue: UserDefaults.standard.string(forKey: AppSettingsKeys.launchMode) ?? "") {
            SplitViewMemory.swap(from: last, to: launch.rawValue)
            UserDefaults.standard.set(launch.rawValue, forKey: "appMode")
        }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--root"), i + 1 < args.count {
            rootPath = args[i + 1]
            rootOverride = true
        } else if let env = ProcessInfo.processInfo.environment["KB_ROOT"], !env.isEmpty {
            rootPath = env
            rootOverride = true
        } else {
            rootPath = KBConfig.loadRootPath()
            rootOverride = false
        }
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
        trackerKindCache = [:]
        for scope in localTrackers.keys {
            let fresh = LocalTracker.load(scope: scope, root: rootURL)
            if fresh != localTrackers[scope] { localTrackers[scope] = fresh }
        }
        do {
            index = try KBIndex.load(root: rootURL)
            loadError = nil
            let tags = ItemTags.load(root: rootURL)
            if tags != itemTags { itemTags = tags }
            let merges = FollowupMergeProposal.load(root: rootURL, index: index)
            if merges != mergeProposals { mergeProposals = merges }
            watchTeamFolders()
        } catch let error as KBLoadError {
            index = .empty
            loadError = error
        } catch {
            index = .empty
            loadError = .registryInvalid(error.localizedDescription)
        }
        if projectID == nil || index.project(projectID!) == nil {
            let remembered = UserDefaults.standard.string(forKey: Self.lastProjectKey)
            let fallback = remembered.flatMap { index.project($0) } ?? index.projects.first
            projectID = fallback?.id
        }
        dailyPlan = DailyPlan.load(date: dailyDate, root: rootURL)
        loadTodayHidden()
        reminders = Reminders.load(root: rootURL)
        goals = Goals.load(root: rootURL)
        if let sel = selectedGoalID, !goals.contains(where: { $0.id == sel }) { selectedGoalID = nil }
        if let sel = selectedReminderID, !reminders.contains(where: { $0.id == sel }) { selectedReminderID = nil }
        indexVersion += 1
        scheduleSharingRefresh()
        strategies = StrategyStore.load(pluginRoot: URL(fileURLWithPath: KBConfig.expandTilde(pluginRootPath)), kbRoot: rootURL)
        factWatchIndexChanged()
        followupWatchIndexChanged()
        scopeWatchIndexChanged()
        tagWatchIndexChanged()
        remoteIndexChanged()
        testScopesChanged()
        let existing = Set(index.entries.keys)
        inboxSelection = inboxSelection.intersection(existing)
        multiSelection = multiSelection.intersection(existing)
        if multiSelection.count < 2 { multiSelection = [] }
        reconcileDocumentWithDisk()
    }

    /// Watches the KB folder and every repo's `knowledgebase/` folder that exists.
    func startWatching() {
        watcher?.stop()
        watcher = nil
        teamWatchers.forEach { $0.stop() }
        teamWatchers = []
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return }
        let w = FileWatcher(path: rootURL.path, debounce: 0.2) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        if w.start() { watcher = w }
        watchTeamFolders()
    }

    /// Repos' team folders appear when the first team entry is written or a pull brings one; watch any new ones.
    func watchTeamFolders() {
        let layout = KBLayout.of(root: rootURL)
        let dirs = layout.checkouts.keys.compactMap { layout.teamDir($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let paths = Set(dirs.map(\.path))
        guard paths != watchedTeamPaths else { return }
        teamWatchers.forEach { $0.stop() }
        teamWatchers = paths.sorted().compactMap { path in
            let w = FileWatcher(path: path, debounce: 0.2) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
            return w.start() ? w : nil
        }
        watchedTeamPaths = paths
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
            rootPath = trimmed
            rootOverride = false
            projectID = nil
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
        projectID = id
        multiSelection = []
        selectedWorkItem = nil
        showProposedBacklog = false
        showProposedFacts = false
            showLooseTasks = false
        UserDefaults.standard.set(id, forKey: Self.lastProjectKey)
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
