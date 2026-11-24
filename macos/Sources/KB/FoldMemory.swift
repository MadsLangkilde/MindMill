import SwiftUI

extension AppModel {
    /// A folded section's state, kept for as long as the app runs: each list opens the way it was left.
    /// Suggestions and finished items start folded.
    func fold(_ key: String, expanded: Bool = false) -> Binding<Bool> {
        Binding(get: { [self] in foldStates[key] ?? expanded }, set: { [self] in foldStates[key] = $0 })
    }
}

/// A block of suggestions under a tappable heading, folded until opened; its state lasts while the app runs.
struct FoldBlock<Content: View, Trailing: View>: View {
    @Environment(AppModel.self) private var model
    let key: String
    let title: String
    var count: Int?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(key: String, title: String, count: Int? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.key = key
        self.title = title
        self.count = count
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        let open = model.fold(key)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { withAnimation(.easeOut(duration: 0.15)) { open.wrappedValue.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
                            .foregroundStyle(.secondary)
                        Text(title).font(.headline)
                        if let count { Text("\(count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                trailing
            }
            if open.wrappedValue { content }
        }
    }
}
