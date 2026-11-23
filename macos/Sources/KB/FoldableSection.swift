import SwiftUI

/// A list section that folds: the whole header toggles it, and the arrow has its own space at the trailing edge,
/// shown on hover (and while folded), so nothing in the header moves. Used instead of `Section(isExpanded:)`, whose
/// sidebar arrow appears on hover and pushes the header's badges aside.
struct FoldableSection<Content: View, Header: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content
    @ViewBuilder var header: Header

    init(isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        _isExpanded = isExpanded
        self.content = content()
        self.header = header()
    }

    var body: some View {
        Section {
            if isExpanded { content }
        } header: {
            FoldHeader(isExpanded: $isExpanded) { header }
        }
    }
}

struct FoldHeader<Label: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder var label: Label
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            label.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: HeaderButton.size, height: HeaderButton.size)
                .opacity(hovering || !isExpanded ? 1 : 0)
        }
        .padding(.trailing, HeaderButton.trailing)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { withAnimation(.snappy) { isExpanded.toggle() } }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(isExpanded ? "Fold" : "Unfold")
        .help(isExpanded ? "Click to fold" : "Click to unfold")
    }
}

/// A small button at the trailing edge of a list section header, such as + for a new item: the same size and inset
/// as a folding header's arrow, so they line up.
struct HeaderButton: View {
    static let size: CGFloat = 20
    static let trailing: CGFloat = 10
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
                .frame(width: Self.size, height: Self.size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .padding(.trailing, Self.trailing)
        .help(help)
    }
}
