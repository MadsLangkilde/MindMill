import AppKit
import KBCore
import KBEngine

/// What Claude can reach, from `claude mcp list`: checked at launch, when KB comes to the front and after a sync
/// fails, so a connector that was signed out (say, by a password change) shows with what to do, and syncing starts
/// again by itself once it is fixed.
extension AppModel {
    var connectorProblems: [ClaudeConnectors.Problem] { ClaudeConnectors.problems(connectorServers) }

    /// `force` checks now; otherwise at most every 10 minutes, or every 5 seconds while something is broken.
    func checkConnectors(force: Bool = false) {
        guard !connectorsChecking, case .found = claudeAvailability else { return }
        if !force, let at = connectorsChecked {
            let wait: TimeInterval = connectorProblems.isEmpty && !microsoft365NeedsSignIn ? 600 : 5
            if Date().timeIntervalSince(at) < wait { return }
        }
        connectorsChecking = true
        let hadM365Problem = microsoft365NeedsSignIn
        Task {
            let r = await runClaude(["mcp", "list"])
            connectorsChecking = false
            connectorsChecked = Date()
            guard let r else { return }
            let servers = ClaudeConnectors.parse(r.stdout)
            guard !servers.isEmpty else { return }
            connectorServers = servers
            let m365 = servers.filter { $0.name == Self.microsoft365 }
            if m365.contains(where: { $0.status == .connected }) {
                microsoft365Status = "connected"
            } else if let s = m365.first {
                microsoft365Status = s.status == .needsAuth ? "needs-auth" : s.status == .failed ? "failed" : microsoft365Status
            }
            if hadM365Problem, !microsoft365NeedsSignIn {
                notice = "Microsoft 365 is connected again. Syncing the calendar."
                syncCalendar()
            }
            scheduleConnectorRecheck()
        }
    }

    /// While something is broken, checks again by itself: every 10 seconds for five minutes after Reconnect (the
    /// fix usually happens in the browser meanwhile), else every 30 seconds while KB is in front. Stops once all works.
    func scheduleConnectorRecheck() {
        connectorTimer?.invalidate()
        connectorTimer = nil
        guard !connectorProblems.isEmpty || microsoft365NeedsSignIn else {
            connectorFixStarted = nil
            return
        }
        let eager = connectorFixStarted.map { Date().timeIntervalSince($0) < 300 } ?? false
        connectorTimer = Timer.scheduledTimer(withTimeInterval: eager ? 10 : 30, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if eager || NSApp.isActive { self.checkConnectors(force: true) } else { self.scheduleConnectorRecheck() }
            }
        }
    }

    /// The fix for a connector: claude.ai's Connectors page for claude.ai connectors, Claude Code's /mcp for others.
    func fixConnector(_ server: ClaudeConnectors.Server?) {
        connectorFixStarted = Date()
        scheduleConnectorRecheck()
        if server?.fromClaudeAI ?? true {
            NSWorkspace.shared.open(ConnectionsSettingsView.connectorsURL)
        } else {
            signInToConnectors()
        }
    }

    /// A Claude session that finds out why the tools KB uses don't work and walks the user through fixing them.
    func troubleshootConnections() {
        let lines = connectorServers.map { "- \($0.name): \($0.status.rawValue)" }.joined(separator: "\n")
        let failures = [calendarSync.error.map { "Last calendar sync: \($0)" }, emailSync.error.map { "Last email scan: \($0)" }]
            .compactMap { $0 }.joined(separator: "\n")
        let brief = """
        Help me find out why KB can't reach my tools, and fix it with me. KB reaches Outlook, Teams, Jira and the rest through Claude's connectors.

        `claude mcp list` said:
        \(lines.isEmpty ? "(not checked yet)" : lines)
        \(failures.isEmpty ? "" : "\n\(failures)\n")
        1. Run `claude mcp list` yourself to see it now, and for each tool KB needs, try one small read with it (for Microsoft 365: today's calendar with `outlook_calendar_search`, limit 1).
        2. Explain each failure in a line, in plain words: "needs authentication" is an expired or revoked sign-in, often after a password change; claude.ai connectors are reconnected at claude.ai → Settings → Connectors (https://claude.ai/settings/connectors), others in Claude Code's `/mcp`.
        3. Tell me exactly what to click, one tool at a time, and wait for me to say it's done before checking again.
        4. When everything works, run `kb sync calendar` and tell me what it said.
        Never ask me for a password or a token in this chat.
        """
        mode = .plan
        sidebarSelection = .sessions
        newSession(title: "Fix my connections", message: brief, display: "Troubleshoot my connections with \(Brain.name)", space: .plan)
    }
}
