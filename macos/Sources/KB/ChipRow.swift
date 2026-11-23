import SwiftUI

/// A row of chips or badges at full size: whole chips move to the next line when the row runs out of width.
struct ChipRow<Content: View>: View {
    var spacing: CGFloat = 6
    var alignment: VerticalAlignment = .center
    @ViewBuilder var content: Content

    var body: some View {
        FlowLayout(spacing: spacing, centered: alignment == .center) { content }
    }
}

/// Lays its views out left to right and wraps whole views onto the next line. It is as wide as its widest line,
/// and a view wider than the line on its own is offered the line's width, so text in it wraps instead of spilling.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat?
    var centered = true

    private struct Line {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(_ maxWidth: CGFloat?, _ subviews: Subviews) -> [Line] {
        var result: [Line] = []
        var line = Line()
        for (i, s) in subviews.enumerated() {
            var size = s.sizeThatFits(.unspecified)
            if let maxWidth, size.width > maxWidth {
                size = s.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
                size.width = min(size.width, maxWidth)
            }
            let needed = line.items.isEmpty ? size.width : line.width + spacing + size.width
            if let maxWidth, !line.items.isEmpty, needed > maxWidth + 0.5 {
                result.append(line)
                line = Line()
            }
            line.width = line.items.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.items.append((i, size))
        }
        if !line.items.isEmpty { result.append(line) }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ls = lines(proposal.width, subviews)
        let gap = lineSpacing ?? spacing
        let height = ls.reduce(0) { $0 + $1.height } + gap * CGFloat(max(0, ls.count - 1))
        return CGSize(width: ls.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let gap = lineSpacing ?? spacing
        var y = bounds.minY
        for line in lines(bounds.width, subviews) {
            var x = bounds.minX
            for item in line.items {
                let dy = centered ? (line.height - item.size.height) / 2 : 0
                subviews[item.index].place(at: CGPoint(x: x, y: y + dy), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += line.height + gap
        }
    }
}

/// A card's text with its button beside it, or under it when the card is too narrow for both, decided by the
/// card's own width. Subviews: lead, info, action; or info and action; or info alone.
struct AdaptiveCardLayout: Layout {
    var spacing: CGFloat = 12
    var stackedSpacing: CGFloat = 10
    /// The least width the text gets beside the button before the button moves under it.
    var minInfoWidth: CGFloat = 220

    private struct Parts {
        var lead: LayoutSubview?
        var info: LayoutSubview?
        var action: LayoutSubview?

        init(_ s: LayoutSubviews) {
            switch s.count {
            case 0: break
            case 1: info = s[0]
            case 2: info = s[0]; action = s[1]
            default: lead = s[0]; info = s[1]; action = s[2]
            }
        }

        var leadSize: CGSize { lead?.sizeThatFits(.unspecified) ?? .zero }
        var actionSize: CGSize { action?.sizeThatFits(.unspecified) ?? .zero }
    }

    private func sideBySide(_ width: CGFloat, _ p: Parts) -> Bool {
        let lead = p.leadSize.width, action = p.actionSize.width
        let gaps = (lead > 0 ? spacing : 0) + (action > 0 ? spacing : 0)
        return width - lead - action - gaps >= minInfoWidth
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews s: Subviews, cache: inout ()) -> CGSize {
        let p = Parts(s)
        // Asked for its smallest size (width 0), it measures at the narrowest it is laid out at: text measured at
        // zero width is one character per line and would make the card, and the window, impossibly tall.
        let proposed = proposal.width ?? 600
        let width = proposed < 1 ? minInfoWidth + p.leadSize.width + (p.leadSize.width > 0 ? spacing : 0) : proposed
        let lead = p.leadSize, action = p.actionSize
        let leadGap = lead.width > 0 ? spacing : 0
        if sideBySide(width, p) {
            let infoW = max(0, width - lead.width - leadGap - action.width - (action.width > 0 ? spacing : 0))
            let info = p.info?.sizeThatFits(ProposedViewSize(width: infoW, height: nil)) ?? .zero
            return CGSize(width: min(width, proposed), height: max(lead.height, info.height, action.height))
        }
        let info = p.info?.sizeThatFits(ProposedViewSize(width: max(0, width - lead.width - leadGap), height: nil)) ?? .zero
        let actionFit = p.action?.sizeThatFits(ProposedViewSize(width: width, height: nil)) ?? .zero
        let top = max(lead.height, info.height)
        return CGSize(width: min(width, proposed), height: top + (actionFit.height > 0 ? stackedSpacing + actionFit.height : 0))
    }

    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews s: Subviews, cache: inout ()) {
        let p = Parts(s)
        let lead = p.leadSize, action = p.actionSize
        let leadGap = lead.width > 0 ? spacing : 0
        if sideBySide(b.width, p) {
            let infoW = max(0, b.width - lead.width - leadGap - action.width - (action.width > 0 ? spacing : 0))
            let info = p.info?.sizeThatFits(ProposedViewSize(width: infoW, height: nil)) ?? .zero
            p.lead?.place(at: CGPoint(x: b.minX, y: b.midY), anchor: .leading, proposal: ProposedViewSize(lead))
            p.info?.place(at: CGPoint(x: b.minX + lead.width + leadGap, y: b.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: infoW, height: info.height))
            p.action?.place(at: CGPoint(x: b.maxX, y: b.midY), anchor: .trailing, proposal: ProposedViewSize(action))
        } else {
            let infoW = max(0, b.width - lead.width - leadGap)
            let info = p.info?.sizeThatFits(ProposedViewSize(width: infoW, height: nil)) ?? .zero
            p.lead?.place(at: CGPoint(x: b.minX, y: b.minY), proposal: ProposedViewSize(lead))
            p.info?.place(at: CGPoint(x: b.minX + lead.width + leadGap, y: b.minY), proposal: ProposedViewSize(width: infoW, height: info.height))
            let actionFit = p.action?.sizeThatFits(ProposedViewSize(width: b.width, height: nil)) ?? .zero
            p.action?.place(at: CGPoint(x: b.minX, y: b.minY + max(lead.height, info.height) + stackedSpacing),
                            proposal: ProposedViewSize(width: min(actionFit.width, b.width), height: actionFit.height))
        }
    }
}

/// Columns side by side while each gets at least `minColumnWidth`, wrapping into more rows when the width is short,
/// down to one column. Each row is as tall as its tallest column.
struct BoardLayout: Layout {
    var minColumnWidth: CGFloat = 230
    var spacing: CGFloat = 12

    private func columns(_ width: CGFloat, _ n: Int) -> Int {
        guard n > 0 else { return 1 }
        return max(1, min(n, Int((width + spacing) / (minColumnWidth + spacing))))
    }

    private func rows(_ width: CGFloat, _ s: Subviews) -> (colWidth: CGFloat, rows: [[Int]], heights: [CGFloat]) {
        let cols = columns(width, s.count)
        let colWidth = max(0, (width - CGFloat(cols - 1) * spacing) / CGFloat(cols))
        var rows: [[Int]] = []
        var heights: [CGFloat] = []
        for start in stride(from: 0, to: s.count, by: cols) {
            let idx = Array(start..<min(start + cols, s.count))
            rows.append(idx)
            heights.append(idx.map { s[$0].sizeThatFits(ProposedViewSize(width: colWidth, height: nil)).height }.max() ?? 0)
        }
        return (colWidth, rows, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews s: Subviews, cache: inout ()) -> CGSize {
        let proposed = proposal.width ?? 1000
        // Asked for its smallest size, it measures one column at its least width rather than at zero.
        let width = proposed < 1 ? minColumnWidth : proposed
        let r = rows(width, s)
        return CGSize(width: min(width, proposed), height: r.heights.reduce(0, +) + CGFloat(max(0, r.rows.count - 1)) * spacing)
    }

    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews s: Subviews, cache: inout ()) {
        let r = rows(b.width, s)
        var y = b.minY
        for (row, height) in zip(r.rows, r.heights) {
            var x = b.minX
            for i in row {
                s[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: r.colWidth, height: height))
                x += r.colWidth + spacing
            }
            y += height + spacing
        }
    }
}
