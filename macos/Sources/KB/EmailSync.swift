import KBCore
import KBEngine
import SwiftUI

extension AppModel {
    /// Has Claude read new mail and propose reminders for what needs the user, skipping newsletters and noise.
    func syncEmail() { engine.routines.syncEmail() }
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
