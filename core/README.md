# core: the code Mindmill's apps share

A Swift package with two libraries. The macOS app (`../macos`) links both in process; on Windows they run in the
engine host, `mindmill-engine.exe`, which the WinUI shell talks to over [docs/engine-host.md](../docs/engine-host.md).

```sh
swift build
swift test      # KBCoreTests and KBEngineTests
```

**Rule:** only Foundation, Dispatch and Observation. Anything Apple-only goes behind `#if canImport(…)` with a
portable fallback, or behind an adapter protocol that each platform implements. Nothing here has been compiled for
Windows yet (no Windows toolchain on the Mac it was written on), so treat every `#if` branch for Windows as
unverified until the step-0 spike builds it.

## KBCore: data, rules, parsing, protocol

The knowledge base (index, entries, front matter, tags, facts graph, quiz), follow-ups, meetings, goals, backlog and
sprints, factory rules and dashboard, Claude session launch and stream parsing (`ClaudeLaunch`, `ClaudeSession`,
`ClaudeStream`), the `kb` CLI wrapper (`KBCLI`), the action catalog and layer, the remote protocol, voice state
machines and realtime provider wires, test adapters and plans. Plain values and pure functions, almost all of it.

Portable pieces with a platform branch:

| Piece | macOS | Elsewhere |
|---|---|---|
| `Digest.sha256Hex` | CryptoKit | `PortableSHA256` (plain Swift, checked against CryptoKit in the tests) |
| `FileWatcher` (`FileWatching`, `FileWatchers.factory`) | `FSEventsFileWatcher` | `PollingFileWatcher`; a host can set `FileWatchers.factory` to a native watcher (Windows: `ReadDirectoryChangesW`) |
| `AppPaths.data` | `~/Library/Application Support/KB` | `%APPDATA%\Mindmill` (Windows) |
| `LoginShell.resolve` (claude, Python, environment) | the login shell, `zsh -ilc` | `WindowsTools`: PATH, `%USERPROFILE%\.local\bin\claude.exe`, `python`/`py -3`/`%LOCALAPPDATA%\Programs\Python` |
| `KBCLI.pythonArguments` | none | `["-3"]` with the `py` launcher |
| `RemoteIdentity` (TLS identity, `NWParameters`) | Security + Network | not built; the transport adapter owns its certificate (`CertificateFingerprint.of(der:)` is shared) |
| `RemoteAddresses.interfaceIPs` | `getifaddrs` | empty; `CompanionTransport.addresses()` reports them |
| `ImageBlock.make` | ImageIO scales and re-encodes | the file as it is when it is PNG/JPEG/GIF/WebP and small enough |
| `ScreenArea` | CoreGraphics | Foundation's `CGRect`/`CGPoint` |
| `KBConfig.expandTilde` / `abbreviateTilde` | `~/…` | also reads and writes `~/…` for `C:\Users\me\…` paths |

## KBEngine: engine work without UI

| File | What |
|---|---|
| `MindmillEngine.swift` | **The engine object**: the knowledge base (root, index, reload, file watching), the current scope, the `kb` CLI, the tools, the action layer, the companion hub and the remote method registry (`RemoteMethods`). `EnginePlatform` bundles the adapters a host gives it. |
| `EngineMethods.swift` | The remote API methods the engine answers itself, `hello`, and the `desktop.*`/`settings.*` desktop methods. |
| `EngineActions.swift` | The action handlers that need only the engine (knowledge, facts, follow-ups, meetings list/create, reminders, goals, backlog proposals, work item create, projects, `app.show`, `app.mode`, `settings.*`), and `SettingKeys`. |
| `EngineStructure.swift` | `app.structure`: the sidebars from the knowledge base plus `StructureExtras` the host fills in (sessions, factories, PRs), section badges and icons. |
| `EngineVoice.swift` | AI settings and Claude Code launches (`aiSetup`, `model(for:)`, `launch`), the voice brain, realtime relays and the `voice.*` methods, `ActionEndpoint` and `MCPHTTP` (the actions as MCP for the brain's sessions). |
| `EngineDesktop.swift` | Desktop-only: `desktop.tools`, `remote.status`/`remote.pairing.*`/`remote.device.*`, the `remote.changed` and `desktop.needsYou` events. |
| `Adapters.swift` | The adapter protocols below. |
| `ClaudeChat.swift` | A Claude Code session as observable state: transcript, turns, cancel, retry, sign-in problems. |
| `VoiceConversation.swift` | A spoken conversation on a persistent Claude session: sentences, barge-in, `ask_brain`. |
| `RealtimeRelay.swift`, `RealtimeKeyTest.swift` | The realtime voice APIs (OpenAI, Gemini, Grok) over `URLSessionWebSocketTask`, and key checks. |
| `RemoteServer.swift` | The companion hub: pairing, `hello`, request routing, events, devices; desktop shells (`acceptLocal`, `desktopToken`, the engine's own requests to a client with `request`). The socket is the `CompanionTransport`. |
| `RemotePayloads.swift`, `ActionText.swift` | JSON shapes of remote-api.md and the action handlers' parsing and phrasing (`ActionError`). |
| `WorkSession.swift`, `AskSubject.swift` | One Claude session (Plan or Build) as observable state; what "Work on it with Claude" attaches. |
| `SessionHub.swift` | `engine.sessions`: every session, saved in `sessions.json`; starting and wiring Claude Code, sending, cancel/retry/allow, the assistant, the lists Build shows. |
| `SessionCrew.swift` | The crew: the 1.5 s crew tick (`kb crew` orders, factories, scans, done checks, `state.json`), the overview session, leads and members, grouping by work item, archiving, finished checks, strategies. `NewLeadRequest`. |
| `SessionWork.swift` | A Build session's work status from the tracker cache (linked PRs, done, archived, badges, stuck PRs) and the sessions that start work (implement, continue, review, PR comments, conflicts). |
| `TrackerCache.swift` | `engine.tracker`: `kb tracker backlog`, `kb tracker mine`, `kb pr list` and their refreshes, expired builds, tracker kinds, marking work started. |
| `FactoryLoop.swift` | `engine.factories`: saving factories, runs, the 15 s loop (pick, follow, wind down, facts changed), questions and answers, coverage checks, side conversations. |
| `FactoryDecisions.swift` | The factory loop's decisions: places taken, task outcomes, time up, winding down, exclusions. |
| `ScanRunner.swift` | `engine.scans`: project scans, their Claude sessions and findings, and the scan actions. |
| `TestRunner.swift` | `engine.tests`: targets, the compatibility check, deliveries (APK, URL, preview; Apple kinds through `TestPlatform`), dev servers, review cards, the `test.*`/`review.*`/`preview.get` methods and test actions. |
| `EngineBuild.swift`, `EngineTracker.swift`, `EngineProjects.swift` | Build's remote methods (`sessions.list`, `session.*`, `tracker.items`, `assistant.open`, `factory.config.*`, `projects.config.save`) and actions (sessions, strategies, factories, tracker, pull requests, `overview`); `report`, `claudeOnce`, `kb sync`, `isolate(in:)`. |
| `CrewFiles.swift` | The crew folder: `state.json` and the `orders/` queue `kb crew` writes. |
| `EnginePlan.swift` | Plan's work as engine functions and actions: entries (delete, move, tags, scopes, sharing, `entry.ask` as a Plan session), fact changes, discussions, ideas and research (their kb skills in Plan sessions), references, reminders, the day's plan, `sync.*`, `repos.pull`, `calendar.upcoming`, `meeting.prepare` (a kb:prep Plan session), `people.*`. |
| `PlanCenter.swift` | `engine.plan`: state Plan keeps between calls: suggested fact links (and the rejected ones), the quiz (stats, cached questions), duplicate follow-ups, the background follow-up check (`FollowupWatchState`), goals and their coaches (`goalChats`), the people directory. |
| `RoutineCenter.swift` | `engine.routines`: the calendar sync, the email scan and the morning routine (headless Claude Code with the Microsoft 365 connector), their states, and `kb sync calendar|email` from a session. Hooks: `onConnectorTrouble`, `onCalendarSynced`, `afterCalendar`, `needsSignIn`. |
| `SprintCenter.swift` | `engine.sprints`: `kb sprint status` and `SprintWatch` (a sprint ended, a review waiting or snoozed), the review and its decisions, the next sprint, what is ready to start; the `sprint.*` and `work.startable` actions. Hook: `onLocalTrackerChanged`. |
| `BacklogCenter.swift` | `engine.backlog`: backlog proposals (propose, create, reject), the duplicate check (`kb backlog duplicates` and the brain's verdicts), aligning tags; the `backlog.*` and `workitem.tags.align` actions. |
| `TestCenter.swift`, `ShellInvocation.swift` | The Test menu's state and shell runs (`zsh -c` on macOS, Git Bash on Windows). |

### Adapter protocols

| Protocol | Methods | macOS | Windows |
|---|---|---|---|
| `SecretStore` | `secret(_:)`, `setSecret(_:name:)`, `hasSecret(_:)` | `KeychainSecretStore` (app, `MacPlatform.swift`); `<group>/<name>` → service `dk.langkilde.kb.<group>` | `CredentialSecretStore` (host): Credential Manager, target `Mindmill/<name>` |
| `ToolLocating` | `resolve() -> LoginShell.Resolved` | `SystemTools` (login shell) | `SystemTools` (`WindowsTools`) |
| `CompanionTransport` | `listen(port:folder:) -> CompanionListening`, `watchNetwork(_:)`, `stopWatchingNetwork()`, `addresses()`, `machineName` | `MacCompanionTransport` (app): `NWListener` + TLS from `RemoteIdentity`, `NWPathMonitor`, Tailscale CLI | `ForwardedPhoneTransport` (host): the shell terminates TLS and forwards phones to `/phone` (engine-host.md, "Phones on Windows") |
| `CompanionListening` | `fingerprint`, `onState`, `onConnection`, `start()`, `cancel()` | `NWCompanionListener` | host |
| `CompanionConnection` | `start(onText:onBinary:onClose:)`, `sendText(_:)`, `sendBinary(_:)`, `close()` | `NWCompanionConnection` | host (also the desktop shell's local socket) |
| `FileWatching` (KBCore) | `start()`, `stop()` | `FSEventsFileWatcher` | `DirectoryChangesWatcher` (host, `ReadDirectoryChangesW`) through `FileWatchers.factory` |
| `Notifier` | `notify(title:body:action:)` | not used yet: the app shows `NoticeBar` and pushes to phones itself | the shell's `platform.notify` (`ShellServices`) |
| `Presenter` | `show(screen:id:)` | `AppModel` (navigates the window) | the shell's `desktop.show` event (`ShellServices`) |
| `ActionEndpoint` | `mcpConfig()` | `LocalActionServer` (NWListener) | `LoopbackActionEndpoint` (host, plain sockets) |
| `SpeechServices` | `startListening(…events:)`, `stopListening()`, `speak(_:voice:rate:done:)`, `stopSpeaking()`, `voices()` | not adopted yet: `VoiceAudio`/`MacVoiceMode` in the app still call Speech and AVFoundation directly | the shell's `platform.speech.*`, `platform.speak`, `platform.voices` |
| `VoiceKeyStore` (KBCore) | `key(provider:)`, `set(_:provider:)` | `VoiceKeychain` = `SecretVoiceKeys(KeychainSecretStore.shared)` | `SecretVoiceKeys` over the host's `SecretStore` |
| `TestPlatform` | `ownKinds`, `gatherFacts(environment:)`, `deliver(_ job: TestJob)`, `snapshot(_:into:name:)` | `MacTestPlatform` (app): Xcode, `devicectl`, `simctl`, TestFlight, WebKit snapshots, the Mac's probes | none: the portable probes; iPhone kinds fail with "iPhone builds need a Mac…" plus the compatibility check's finding (`TestRunner.unsupported`), and `test.status` marks them `unavailable` |

`MemorySecretStore` and the fakes in `Tests/KBEngineTests` show the smallest implementations.

## How a host uses the engine

```swift
let platform = EnginePlatform(name: "Windows", machineWord: "PC", secrets: CredentialSecretStore(),
                              transport: ForwardedPhoneTransport(), defaults: .standard, pluginRoot: { … })
let engine = MindmillEngine(rootPath: root, platform: platform)
engine.platform.presenter = …; engine.platform.actionEndpoint = …     // weak: the host keeps them
engine.reload(); engine.startWatching(); engine.resolveTools()
engine.remote.acceptLocal(connection)          // a desktop shell's socket; phones come through the transport
engine.methods.register("meeting.start") { client, params in … }    // what the host adds
engine.actions.register("app.mode") { params in … }                 // replaces the engine's default
```

Hooks the host sets: `onReload` (after every reload), `onTrackerChanged`, `structureExtras`, `myNames` (default: the
name in Settings and the trackers' account),
`needsYouItems`/`factoryStatus` (for `desktop.state`; both default to the engine's sessions and factories),
`settings` (the desktop `settings.get/set`), `onBinaryFrame` (frames the engine doesn't handle), `onClientClosed`,
`onReport` (a notice or error for the host's own UI), `testingNote`, `syncSource` (`kb sync calendar|email`),
`currentMode`. `syncSource` is optional: without it `kb sync calendar|email` runs `engine.routines`. Plan's and
Build's parts have their own hooks, all optional (the engine falls back to the platform's presenter
and notifier):

- `sessions`: `onShow` (show a session; default `presenter.show("session", id)`), `onSent` (clear the host's input),
  `afterTurn` (offers; default: testing's auto delivery), `onDeleted`, `onTick`, `orderHook` (default `kb test
  suggest`), `onSync`, `linkedItems`/`archiveLinked` (conversations that list with Plan sessions), `mcpConfig`,
  `backgroundChecks`. A session that starts to wait on the user goes to `notifier` (`session:<id>`).
- `tracker`: `willRefreshBacklog`/`willRefreshPullRequests` (the Mac's timers), `onPullRequests`, `editLocal`.
- `factories`: `onCheckpoint` (default: testing at checkpoints), `onDeleted`. A question goes to `notifier`
  (`factory:<id>`) and sends `desktop.state`.
- `scans`: `onStarted`, `onDeleted`. `tests`: `platform` (`TestPlatform`), `onAskToSetUp`.

`isolate(in:)` keeps sessions, the crew folder, factories, scans and testing in one folder (tests; the engine host
with `--data`). The host starts the crew tick with `engine.sessions.startTicking()` (the Mac when Build first shows,
the Windows host at start). A method nobody registered answers `unknown_method`; one of a platform feature (`voice.`,
`meeting.`) answers `unavailable` ("… isn't available on Windows yet."), and an action without a handler fails with
the same sentence.

## Still in the macOS app target, and why

`AppModel` is `@Observable @MainActor` and owns the engine: `index`, `rootPath`, `projectID` (the engine's `scope`),
`shell`, `cli`, `actions`, `remote`, `aiSetup`, `voiceConversations`, `sessions`, `factories`, `strategies`,
`tracker`/`myWork`/`pullRequests`, `scans`, `testing` forward to it, so SwiftUI observes the engine through
`AppModel`. Its own state is the window's: selection (`selectedSessionID`, `buildSelection`, `projectPane`), sheets
and requests, and per session `SessionUIState` (`input`, `pendingAttachments`, `researchAskShown`, `testAskShown`,
reached as `WorkSession` extension properties). The app registers on `engine.methods`/`engine.actions` what still
needs it:

- **Meetings** (`Meeting/`, `RemoteMeetings.swift`, `meeting.*`, `meeting.mac.*`): `MeetingController` (1 100 lines)
  is the meeting window's model and the meeting at once: its live Claude session (live notes, questions, summary),
  filing, `LiveTranscriber` (Speech, voice processing) and `ScreenWatcher` (ScreenCaptureKit, Vision). **Next step:**
  split a `MeetingSession` into KBEngine (notes, transcript lines, the live Claude session, `finishMeeting`, summary
  and filing, `meeting.start/line/note/stop/get`, `meeting.changed`) with a `MeetingCapture` adapter (Mac:
  LiveTranscriber + ScreenWatcher; Windows: `platform.audio.capture`, `platform.transcript` events and `audio`
  frames through the realtime transcription, `platform.screen.text`), and keep the window state in the app.
- **Action handlers with UI state or app caches.** Registered over an engine default; most call the engine's function
  underneath (a few still run the same `kb` command themselves) and add the Mac's busy marks, its open document, navigation, notices or windows: `project.select`,
  `app.mode`, `fact.approve`/`decline`, `followup.update`, `settings.get/general/meetings`, `backlog.list`,
  `workitem.get/update/search/tasks/implement`, `workitem.tags.align`, `backlog.propose/create/reject`, `prs.list`,
  `pr.*`, `entry.*` (the open document; `entry.ask` opens the Ask window), `fact.link`, `fact.links.suggest` (answers
  at once, suggestions show beside the fact), `fact.change.*`, `followups.*`, `followup.merge`, `discussion.*`,
  `idea.*`, `research.*`, `reference.*`, `reminder.update/delete`, `goal.*`, `today.morning`, `sync.*` (`sync.all`
  follows the Mac's mode), `calendar.upcoming` (`open`: the meeting window), `meeting.prepare` (the meeting window's
  own prepare session), `repos.pull`. The state behind them (`engine.plan`, `engine.routines`, `engine.sprints`,
  `engine.backlog`) is the engine's; `AppModel` forwards its properties to it.
  Background watchers that only the Mac runs yet: the fact check (`FactChanges.swift`), scope tagging and tag
  suggestions (`ScopeTagging.swift`, `TagWatch.swift`), the connector health check, the calendar timer and the
  automatic morning run. They are portable (Claude Code runs and `kb`) and can move the same way when Windows needs them.
- **Plan's linked conversations** (meeting chats, goal coaches, Ask): the Mac lists them with `sessions.list` through
  `sessions.linkedItems` (the goal coaches themselves are `engine.plan.goalChats`). On Windows the goal coach answers
  in the goal's file (`goal.coach`), and Ask is a Plan session (`entry.ask`).
- **Research and testing offers** under Build sessions (`offerResearch`, `offerTesting`): UI, through `afterTurn`.
- **Voice audio** (`VoiceAudio.swift`, `MacVoiceMode.swift`): Speech, AVFoundation, voice processing for barge-in.
- **`MacTestPlatform`** (Xcode, `devicectl`, `simctl`, TestFlight, WebKit), **`LocalActionServer`** (NWListener),
  **`MacCompanionTransport`**, the Keychain, and everything with SwiftUI, AppKit, WebKit or PDFKit.

## Risks for the Windows build (not verifiable on a Mac)

- `URLSessionWebSocketTask` (RealtimeRelay) in swift-corelibs-foundation on Windows depends on its libcurl having
  WebSocket support; `maximumMessageSize` and `closeReason` may behave differently.
- `NSLock.withLock`, `DispatchSource` timers, `UserDefaults` and `Process` with pipes exist in corelibs Foundation but
  are less tested on Windows; `Process` can't start `.cmd` shims, so `claude.cmd` from npm is skipped.
- The `@Observable` macro needs the toolchain's macro plugins on Windows.
- `FileManager.urls(for: .applicationSupportDirectory)` is only the fallback when `%APPDATA%` is unset.
- `PollingFileWatcher` walks the folder every second; fine for a KB, slow for huge repositories.
- `withObservationTracking` (the engine's `remote.changed` events) and `@Observable` need the Observation module of
  the Windows toolchain.
- `AppPaths.data` honours `MINDMILL_DATA`, so tests and a second engine on a Mac never touch the app's data folder.
- Build on Windows (unverified): the crew tick is a `Task` loop on the main actor (the host runs `dispatchMain`);
  `TestShell` and dev servers run through Git Bash (`./gradlew` works there, `.cmd` shims don't start from
  `Process`); `URLSession.data(for:)` (backend previews, dev server checks) needs corelibs' async API; the
  Android SDK defaults to `%LOCALAPPDATA%\Android\Sdk` and PATH is joined with `;`; Claude Code sessions get
  `KB_CREW_DIR`/`KB_SESSION_ID` so `kb crew` reaches the engine; scans need a repository path the PC can read.
- Plan on Windows (unverified): the routines and the goal coach need Claude Code's claude.ai Microsoft 365 connector,
  signed in on the PC; `ActionText.shortDate`/`displayDate` use `DateFormatter` templates and `NSFullUserName()`
  (Ready to Start's "me") comes from corelibs; `tracker.items`, `backlog.list` and `work.startable` wait (up to 90 s)
  for a backlog fetched after the last change, so a slow tracker makes them slow rather than stale; nothing on
  Windows runs the background follow-up check, the fact check or the calendar timer yet (only on request).
