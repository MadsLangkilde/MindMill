import AppKit
import KBCore
import KBEngine
import SwiftUI

/// Answers to a ```choices block, when the reply is waiting on the user.
struct ChoiceHandler {
    let multi: Bool
    let picked: Set<String>
    let toggle: (String) -> Void
    let choose: (String) -> Void
}

/// A Claude reply rendered as a document: headings, lists, code, tables and clickable choices.
struct MarkdownDocument: View {
    let text: String
    var choices: ChoiceHandler?
    @Environment(\.findHighlight) private var highlight

    var body: some View {
        let blocks = MarkdownBlocks.parse(text)
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(marked(text))
                .font(level == 1 ? .title2.weight(.semibold) : level == 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let text):
            Text(marked(text)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        case .listItem(let indent, let marker, let checked, let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if let checked {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(checked ? Color.accentColor : .secondary)
                } else {
                    Text(marker).foregroundStyle(.secondary).monospacedDigit()
                        .frame(minWidth: marker.count > 1 ? 18 : 8, alignment: .trailing)
                }
                Text(marked(text)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 18 + 4)
        case .code(let language, let code):
            CodeBlock(language: language, code: code)
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1).fill(Color.accentColor.opacity(0.5)).frame(width: 3)
                Text(marked(text)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows)
        case .rule:
            Divider().padding(.vertical, 4)
        case .choices(let multi, let options):
            ChoicesView(multi: multi, options: options, handler: choices)
        case .strategies(let options):
            StrategyPicker(options: options, handler: choices)
        case .capture(let urls):
            CaptureLinksView(urls: urls)
        }
    }

    static func inline(_ text: String) -> AttributedString {
        EntryIDLinks.attributed(text)
    }

    private func marked(_ text: String) -> AttributedString {
        Self.inline(text).highlighting(highlight)
    }
}

extension EnvironmentValues {
    /// What ⌘F in a conversation looks for: the messages mark every place it appears.
    @Entry var findHighlight = ""
}

extension AttributedString {
    /// The same text with every place `query` appears marked, as a found word is in other apps.
    func highlighting(_ query: String) -> AttributedString {
        let plain = String(characters)
        let found = TextFind.ranges(of: query, in: plain)
        guard !found.isEmpty else { return self }
        var out = self
        for r in found {
            let lo = plain.distance(from: plain.startIndex, to: r.lowerBound)
            let hi = plain.distance(from: plain.startIndex, to: r.upperBound)
            let a = out.characters.index(out.startIndex, offsetBy: lo), b = out.characters.index(out.startIndex, offsetBy: hi)
            out[a..<b].backgroundColor = Color.yellow.opacity(0.55)
            out[a..<b].foregroundColor = Color.black
        }
        return out
    }
}

struct ChoicesView: View {
    let multi: Bool
    let options: [String]
    let handler: ChoiceHandler?

    var body: some View {
        if let handler {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(options, id: \.self) { option in
                    let recommended = option.localizedCaseInsensitiveContains("(recommended)")
                    let label = option.replacingOccurrences(of: "(Recommended)", with: "")
                        .replacingOccurrences(of: "(recommended)", with: "").trimmingCharacters(in: .whitespaces)
                    Button {
                        if handler.multi { handler.toggle(label) } else { handler.choose(label) }
                    } label: {
                        HStack(spacing: 8) {
                            if handler.multi {
                                Image(systemName: handler.picked.contains(label) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(handler.picked.contains(label) ? Color.accentColor : .secondary)
                            }
                            Text(MarkdownDocument.inline(label)).multilineTextAlignment(.leading)
                            if recommended {
                                Text("Recommended").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: 520, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(recommended ? 0.10 : 0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.accentColor.opacity(recommended ? 0.45 : 0.2)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if handler.multi {
                    Button("Send \(handler.picked.count) Selected") {
                        handler.choose(options.map { $0.replacingOccurrences(of: "(Recommended)", with: "").trimmingCharacters(in: .whitespaces) }
                            .filter(handler.picked.contains).joined(separator: ", "))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(handler.picked.isEmpty)
                }
                Text("Or type your own answer below.").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.top, 2)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(options, id: \.self) { option in
                    Label { Text(MarkdownDocument.inline(option)) } icon: { Image(systemName: "circle").font(.caption2) }
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct CodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false
    @Environment(\.findHighlight) private var highlight

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                Text(AttributedString(code).highlighting(highlight))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.15)))
    }
}

/// A Markdown table. Each column is as wide as its longest cell up to a limit, so long cells wrap inside their
/// own column and every row is as tall as its tallest cell. Wider than the reply, it scrolls sideways.
struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    @Environment(\.findHighlight) private var highlight

    private static let maxColumn: CGFloat = 300
    private static let minColumn: CGFloat = 40

    var body: some View {
        let widths = columnWidths()
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                row(header, widths: widths, bold: true)
                    .background(Color.secondary.opacity(0.08))
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    Divider()
                    row(r, widths: widths, bold: false)
                        .background(i % 2 == 1 ? Color.secondary.opacity(0.03) : .clear)
                }
            }
            .fixedSize(horizontal: true, vertical: true)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.15)))
    }

    private func row(_ cells: [String], widths: [CGFloat], bold: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<widths.count, id: \.self) { i in
                Text(MarkdownDocument.inline(i < cells.count ? cells[i] : "").highlighting(highlight))
                    .font(bold ? .callout.weight(.semibold) : .callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: widths[i], alignment: .topLeading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
            }
        }
    }

    /// Measured in the callout font: the longest cell (or header) per column, between the limits.
    private func columnWidths() -> [CGFloat] {
        let regular = NSFont.preferredFont(forTextStyle: .callout)
        let bold = NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask)
        func width(_ s: String, _ font: NSFont) -> CGFloat {
            let plain = String(MarkdownDocument.inline(s).characters)
            return plain.components(separatedBy: "\n").map {
                ($0 as NSString).size(withAttributes: [.font: font]).width
            }.max() ?? 0
        }
        return (0..<header.count).map { i in
            var w = width(header[i], bold)
            for r in rows where i < r.count { w = max(w, width(r[i], regular)) }
            return min(max(ceil(w) + 2, Self.minColumn), Self.maxColumn)
        }
    }
}
