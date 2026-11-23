import AppKit
import KBCore
import SwiftUI

/// A plain-text editor that reports where given paragraphs sit vertically in the visible area,
/// so a gutter beside it can line flags up with the note they answer.
struct NotesTextView: NSViewRepresentable {
    let text: String
    let onChange: (String) -> Void
    /// Note id → the paragraph text to locate.
    let anchors: [Int: String]
    let onPositions: ([Int: CGFloat]) -> Void
    var placeholder = "Type notes. A blank line (or a pause) sends the paragraph to \(Brain.name)."

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1 from the start: reading `layoutManager` later would switch a TextKit 2 view over at runtime.
        let tv = NSTextView(usingTextLayoutManager: false)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.drawsBackground = false
        tv.font = NSFont.systemFont(ofSize: 15)
        tv.textContainerInset = NSSize(width: 18, height: 16)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        para.paragraphSpacing = 2
        tv.defaultParagraphStyle = para
        tv.typingAttributes = [.font: NSFont.systemFont(ofSize: 15), .paragraphStyle: para, .foregroundColor: NSColor.textColor]
        tv.string = text
        context.coordinator.textView = tv
        context.coordinator.placeholder = placeholder
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.geometryChanged),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.geometryChanged),
                                               name: NSView.frameDidChangeNotification, object: tv)
        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            tv.scrollToEndOfDocument(nil)
            context.coordinator.scheduleReport()
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        // Replacing the text mid-composition (a dead key such as ´ or ¨) breaks the input context's ranges.
        if let tv = c.textView, tv.string != text, !c.isEditing, !tv.hasMarkedText() {
            tv.string = text
        }
        c.scheduleReport()
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NotesTextView
        weak var textView: NSTextView?
        var placeholder = ""
        var isEditing = false
        private var last: [Int: CGFloat] = [:]

        init(_ parent: NotesTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            isEditing = true
            parent.onChange(tv.string)
            isEditing = false
            scheduleReport()
        }

        @objc func geometryChanged() { scheduleReport() }

        private var reportScheduled = false

        /// Layout is measured on the next main-queue turn, never inside a SwiftUI update or a text edit:
        /// an Objective-C exception thrown by the layout manager there unwinds through SwiftUI's observation
        /// tracking and corrupts it, which crashed the app later at an unrelated spot.
        func scheduleReport() {
            guard !reportScheduled else { return }
            reportScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reportScheduled = false
                self.report()
            }
        }

        private func report() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer,
                  let storage = tv.textStorage, let clip = tv.enclosingScrollView?.contentView else { return }
            guard !tv.hasMarkedText(), storage.editedMask.isEmpty else { return }
            lm.ensureLayout(for: tc)
            let ns = tv.string as NSString
            var out: [Int: CGFloat] = [:]
            var cache: [String: CGFloat] = [:]
            for (id, anchor) in parent.anchors {
                if let y = cache[anchor] { out[id] = y; continue }
                var r = ns.range(of: anchor, options: .backwards)
                if r.location == NSNotFound {
                    r = ns.range(of: String(anchor.prefix(24)), options: .backwards)
                }
                guard r.location != NSNotFound else { continue }
                let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: r.location, length: min(1, r.length)), actualCharacterRange: nil)
                let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
                let y = rect.minY + tv.textContainerInset.height - clip.bounds.origin.y
                cache[anchor] = y
                out[id] = y
            }
            guard out != last else { return }
            last = out
            parent.onPositions(out)
        }
    }
}

/// Flags beside the notes, each at the height of the paragraph it answers. `OK` shows nothing.
struct FlagGutter: View {
    let notes: [LiveNote]
    let flags: [Int: [LiveReply.Flag]]
    let pending: Set<Int>
    let positions: [Int: CGFloat]

    private struct Placed: Identifiable {
        let id: Int
        let y: CGFloat
        let flags: [LiveReply.Flag]
        let pending: Bool
    }

    var body: some View {
        GeometryReader { geo in
            let placed = layout(width: geo.size.width)
            ZStack(alignment: .topLeading) {
                ForEach(placed) { p in
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(p.flags.enumerated()), id: \.offset) { _, f in FlagBubble(flag: f) }
                        if p.pending { ReadingDots() }
                    }
                    .frame(width: geo.size.width - 16, alignment: .leading)
                    .offset(x: 8, y: p.y)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .animation(.easeOut(duration: 0.25), value: placed.map(\.id))
        }
    }

    /// Top of each group at its paragraph, pushed down when the group above would overlap.
    private func layout(width: CGFloat) -> [Placed] {
        let charsPerLine = max(20, Int((width - 40) / 6.6))
        var items: [Placed] = []
        var bottom: CGFloat = -.infinity
        let ordered = notes.filter { !(flags[$0.id] ?? []).isEmpty || pending.contains($0.id) }
            .compactMap { n -> (LiveNote, CGFloat)? in positions[n.id].map { (n, $0) } }
            .sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 < $1.1 }
        for (note, y0) in ordered {
            let fl = flags[note.id] ?? []
            let isPending = pending.contains(note.id)
            let y = max(y0 + 14, bottom + 6)
            let lines = fl.reduce(0) { $0 + $1.text.count / charsPerLine + 1 }
            let height = CGFloat(lines) * 16 + CGFloat(fl.count) * 12 + (isPending ? 16 : 0)
            bottom = y + height
            items.append(Placed(id: note.id, y: y - 14, flags: fl, pending: isPending))
        }
        return items
    }
}

struct FlagBubble: View {
    let flag: LiveReply.Flag

    var body: some View {
        let color: Color = flag.kind == .warning ? .orange : flag.kind == .info ? .blue : .secondary
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: flag.kind == .warning ? "exclamationmark.triangle.fill" : flag.kind == .info ? "info.circle.fill" : "text.bubble")
                .foregroundStyle(color)
                .font(.caption)
            Text(EntryIDLinks.attributed(flag.text))
                .font(.callout)
                .foregroundStyle(flag.kind == .note ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(flag.kind == .note ? 0.06 : 0.11), in: RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .leading) {
            Rectangle().fill(color.opacity(0.7)).frame(width: 2).padding(.vertical, 4)
        }
    }
}

struct ReadingDots: View {
    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 0.4)) { ctx in
            let phase = Int(ctx.date.timeIntervalSinceReferenceDate / 0.4) % 3
            HStack(spacing: 3) {
                ForEach(0..<3) { i in
                    Circle().fill(Color.secondary.opacity(i == phase ? 0.8 : 0.3)).frame(width: 4, height: 4)
                }
            }
            .padding(.leading, 8)
            .padding(.vertical, 4)
        }
    }
}

/// Inline Markdown with every entry id turned into a `kb://open` link.
enum EntryIDLinks {
    static let pattern = #"`?([a-z0-9][a-z0-9-]*/(?:decisions|meetings|facts|architecture|followups|backlog)/[a-z0-9][a-z0-9-]*)`?"#

    static func attributed(_ text: String) -> AttributedString {
        let linked = text.replacingOccurrences(of: pattern, with: "[$1](kb://open?id=$1)", options: .regularExpression)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: linked, options: options)) ?? AttributedString(text)
    }
}
