import KBCore
import SwiftUI

struct EmailSyncState: Equatable {
    var lastRun: Date?
    var summary: String?
    var error: String?
    var inFlight = false
}

extension AppModel {
    /// Has Claude read new mail and propose reminders for what needs the user, skipping newsletters and noise.
    func syncEmail() {
        guard !email.isRunning, !morning.isBusy else { return }
        guard let launch = launch(prompt: ClaudeModes.email, sessionID: UUID().uuidString.lowercased(), resume: false,
                                  model: defaultModel, cwd: rootURL,
                                  tools: ["Bash(kb:*)", "Read", "Edit", "mcp__claude_ai_Microsoft_365__outlook_email_search",
                                          "mcp__claude_ai_Microsoft_365__read_resource"]) else {
            errorMessage = claudeMissingExplanation
            return
        }
        email.onEvent = { [weak self] event in self?.emailEvent(event) }
        do {
            try email.start(launch, mode: "email")
        } catch {
            emailSync.error = error.localizedDescription
            return
        }
        emailSync.lastRun = Date()
        emailSync.inFlight = true
        email.send(ClaudeModes.warmup, tag: "connect", show: false)
        email.send("scan", tag: "email", show: false)
    }

    private func emailEvent(_ event: ClaudeEvent) {
        switch event {
        case .turnResult(let text, let isError, let tag) where tag == "email":
            emailSync.inFlight = false
            let line = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
            if !isError, line.hasPrefix("EMAIL") {
                emailSync.summary = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                emailSync.error = nil
                notice = "Email: \(emailSync.summary ?? "")"
            } else {
                emailSync.error = line.hasPrefix("ERROR") ? String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) : (line.isEmpty ? "Email scan failed." : line)
                if ConnectorSignIn.isNeeded(text) { microsoft365Status = "needs-auth" }
                checkConnectors(force: true)
            }
            email.stop()
            reload()
        case .exited:
            guard emailSync.inFlight else { return }
            emailSync.inFlight = false
            emailSync.error = "\(Brain.name) stopped before the email scan finished."
        default:
            break
        }
    }
}

struct EmailSyncButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.emailSync
        Button {
            model.syncEmail()
        } label: {
            if model.email.isRunning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: s.error == nil ? "envelope.arrow.triangle.branch" : "envelope.badge")
                    .foregroundStyle(s.error == nil ? Color.primary : .orange)
            }
        }
        .disabled(model.email.isRunning || model.morning.isBusy)
        .help(help(s))
    }

    private func help(_ s: EmailSyncState) -> String {
        if model.email.isRunning { return "\(Brain.name) is reading new email…" }
        var lines = ["Scan new email for things you need to do. \(Brain.name) suggests reminders, keeps open discussions up to date, and skips newsletters and notifications."]
        if let d = s.lastRun, s.error == nil, let sum = s.summary { lines.append("Last scan \(MeetingController.clock(d)): \(sum)") }
        if let e = s.error { lines.append("Last scan failed: \(e)") }
        return lines.joined(separator: "\n")
    }
}
