import AppKit
import SwiftUI

// A key instead of `@Entry`: the Command Line Tools don't ship SwiftUI's macro plugin.
private struct ChooseLinkKey: EnvironmentKey {
    static let defaultValue: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
}

extension EnvironmentValues {
    /// Asks how to open a web link: in the user's browser, in Mindmill's own, or copied.
    var chooseLink: @MainActor (URL) -> Void {
        get { self[ChooseLinkKey.self] }
        set { self[ChooseLinkKey.self] = newValue }
    }
}

extension View {
    /// Web links clicked in this window ask how to open them. Other links (kb://, mail) open as before.
    func linkChoices() -> some View { modifier(LinkChoices()) }
}

private struct LinkChoices: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var pending: URL?

    func body(content: Content) -> some View {
        content
            .environment(\.chooseLink, { pending = $0 })
            .environment(\.openURL, OpenURLAction { url in
                guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .systemAction }
                pending = url
                return .handled
            })
            .confirmationDialog(pending.map { "Open \($0.host ?? $0.absoluteString)?" } ?? "",
                                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                                presenting: pending) { url in
                Button("Open in Your Browser") { NSWorkspace.shared.open(url) }
                Button("Open in Mindmill") { model.openCapture(url, for: .clipboard) }
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    model.notice = "Copied the link."
                }
                Button("Cancel", role: .cancel) {}
            } message: { url in
                Text(url.absoluteString)
            }
    }
}
