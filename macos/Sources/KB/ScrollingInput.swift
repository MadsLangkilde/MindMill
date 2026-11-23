import SwiftUI

/// A multi-line text field that grows with its text up to `maxLines`, then scrolls instead of clipping.
/// The field itself stays one view, so focus, submit and the caret are unchanged while it crosses the limit.
struct ScrollingInput<Content: View>: View {
    let maxLines: Int
    var lineHeight: CGFloat = 17
    /// The field's text: typing at the end keeps the last line in view.
    let text: String
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        let limit = CGFloat(maxLines) * lineHeight + 8
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    content
                        .fixedSize(horizontal: false, vertical: true)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: ScrollingInputHeightKey.self, value: g.size.height)
                        })
                    Color.clear.frame(height: 0).id(ScrollingInputHeightKey.endID)
                }
            }
            .scrollIndicators(height > limit ? .automatic : .never)
            .scrollDisabled(height <= limit)
            .frame(height: max(lineHeight + 4, min(height, limit)))
            .onPreferenceChange(ScrollingInputHeightKey.self) { height = $0 }
            .onChange(of: text) { old, new in
                if new.count > old.count, new.hasPrefix(old), height > limit {
                    proxy.scrollTo(ScrollingInputHeightKey.endID, anchor: .bottom)
                }
            }
        }
    }
}

private struct ScrollingInputHeightKey: PreferenceKey {
    static let endID = "scrolling-input-end"
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    /// Grows with `text` up to `maxLines`, then scrolls. Use on a `TextField(axis: .vertical)` without an upper line limit.
    func scrollingInput(_ text: String, maxLines: Int, lineHeight: CGFloat = 17) -> some View {
        ScrollingInput(maxLines: maxLines, lineHeight: lineHeight, text: text) { self }
    }
}
