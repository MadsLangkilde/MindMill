import Foundation
import KBCore
import KBEngine

/// Builds launches with the user's environment and `KB_ROOT`.
extension AppModel {
    enum ClaudeAvailability: Equatable {
        case resolving
        case found(URL)
        case missing
    }

    var claudeAvailability: ClaudeAvailability {
        guard let shell else { return .resolving }
        return shell.claude.map(ClaudeAvailability.found) ?? .missing
    }

    /// The plugin KB runs: a folder chosen in Settings, else the copy inside Mindmill.app.
    var pluginLocation: (path: String, source: PluginLocation.Source) { Self.currentPluginLocation }

    nonisolated static var currentPluginLocation: (path: String, source: PluginLocation.Source) {
        PluginLocation.resolve(chosen: UserDefaults.standard.string(forKey: AppSettingsKeys.pluginRoot),
                               bundled: Bundle.main.resourceURL?.appendingPathComponent("plugin").path)
    }

    var pluginRootPath: String { pluginLocation.path }

    /// The model a task runs on, from Settings → AI; empty for the assistant's default.
    func model(for task: AITask) -> String { engine.model(for: task) }

    var liveModel: String { model(for: .meetings) }

    var defaultModel: String { model(for: .work) }

    var backgroundModel: String { model(for: .background) }

    var brainName: String { engine.brainName }

    var cli: KBCLI { engine.cli }

    func resolveShell() {
        engine.resolveTools { [weak self] in
            self?.checkConnectors(force: true)
            self?.startBackgroundWork()
        }
    }

    func claudeEnvironment() -> [String: String] { engine.claudeEnvironment() }

    func launch(prompt: String, sessionID: String, resume: Bool, model: String, cwd: URL,
                tools: [String] = ClaudeLaunch.bridgeTools) -> ClaudeLaunch? {
        engine.launch(prompt: prompt, sessionID: sessionID, resume: resume, model: model, cwd: cwd, tools: tools)
    }

    var claudeMissingExplanation: String { engine.claudeMissingExplanation }
}

enum AppSettingsKeys {
    static let appearance = "appearance"
    static let settingsPane = "settingsPane"
    static let launchMode = "launchMode"
    static let autoMorning = "autoMorning"
    static let calendarMinutes = "calendarSyncMinutes"
    static let calendarModel = "calendarModel"
    static let transcriptLanguage = "transcriptLanguage"
    static let transcriptMicrophone = "transcriptMicrophone"
    static let transcriptComputerAudio = "transcriptComputerAudio"
    static let transcriptConsentAcknowledged = "transcriptConsentAcknowledged"
    static let pluginRoot = "pluginRoot"
    static let liveModel = "liveModel"
    static let defaultModel = "defaultModel"
    static let defaultPluginRoot = PluginLocation.developmentPath
}
