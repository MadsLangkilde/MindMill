import KBCore
import KBEngine
import SwiftUI

extension AppModel {
    /// Opens Ask on the subject's project (or the current one), with the subject attached to the next question.
    func askAbout(_ subject: AskSubject) {
        let p = subject.project.flatMap { index.project($0) != nil ? $0 : nil } ?? projectID
        guard let p else { return }
        if p != projectID { navigate { [self] in setProject(p) } }
        conversation(for: p).subject = subject
        openAsk()
    }
}

struct AskSubjectChip: View {
    @Bindable var conversation: AskConversation

    var body: some View {
        if let s = conversation.subject {
            HStack(spacing: 6) {
                Image(systemName: "paperclip").foregroundStyle(Color.accentColor)
                Text("About: ").foregroundStyle(.secondary) + Text(s.title).fontWeight(.medium)
                Spacer(minLength: 4)
                Button { conversation.subject = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Ask without it")
            }
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 14)
            .padding(.top, 6)
        }
    }
}
