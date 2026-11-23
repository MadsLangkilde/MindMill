import SwiftUI

/// A short message under the content, in the layout: it pushes the content up instead of covering it.
struct NoticeBar: View {
    let text: String
    var seconds: Double = 5
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text(text).font(.callout).lineLimit(2).textSelection(.enabled)
                Spacer(minLength: 8)
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task(id: text) {
            try? await Task.sleep(for: .seconds(seconds))
            withAnimation { onClose() }
        }
    }
}
