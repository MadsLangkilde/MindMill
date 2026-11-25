import KBCore
import KBEngine
import SwiftUI

/// Facts as a list, or as a graph of how they link.
struct FactsColumn: View {
    @Environment(AppModel.self) private var model
    let project: KBProject
    @AppStorage("factsView") private var view = "list"

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $view) {
                Text("List").tag("list")
                Text("Graph").tag("graph")
                Text("Quiz").tag("quiz")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 8)
            .help("Graph shows the facts as dots and their links as lines; Quiz helps you remember them")
            switch view {
            case "graph": FactGraphView(project: project)
            case "quiz": QuizView(project: project)
            default: EntryListView(project: project, section: .facts)
            }
        }
    }
}

extension AppModel {
    /// Opens a fact in the detail pane and nothing else: the scope, the section and the graph stay as they are.
    func openFactFromGraph(_ id: EntryID) {
        guard id != selectedEntryID else { return }
        navigate { [self] in openNow(id) }
    }

    /// Lays the graph out off the main thread; the result is kept until the facts or links change.
    func factGraphLayout(nodes: [String], edges: [FactGraph.Edge]) -> [String: FactGraph.Point]? {
        var h = Hasher()
        nodes.sorted().forEach { h.combine($0) }
        edges.sorted { ($0.a, $0.b) < ($1.a, $1.b) }.forEach { h.combine($0) }
        let key = h.finalize()
        if let cached = factGraphCache, cached.key == key { return cached.points }
        if factGraphPending != key {
            factGraphPending = key
            Task.detached(priority: .userInitiated) {
                let points = FactGraph.layout(nodes: nodes, edges: edges)
                await MainActor.run { [weak self] in
                    guard let self, self.factGraphPending == key else { return }
                    self.factGraphCache = (key, points)
                    self.factGraphPending = nil
                }
            }
        }
        return factGraphCache?.points
    }
}

/// Dots for facts, lines for links. Drag to pan, pinch or the buttons to zoom; clicking a dot opens the fact and
/// lights up its neighbours, and Focus hides everything else.
struct FactGraphView: View {
    @Environment(AppModel.self) private var model
    let project: KBProject
    @State private var scale: Double = 1
    @State private var baseScale: Double = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var focus = false
    @AppStorage("factGraphDepth") private var depth = 1

    static let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .brown, .indigo, .mint, .red]

    var body: some View {
        let every = model.index.entries(project: project.id, section: .facts).filter { !$0.isDraft }
        let facts = model.tagFiltered(every, .facts)
        let ids = Set(facts.map(\.id))
        let edges = model.index.factLinks(among: ids).map { FactGraph.Edge($0.0.rawValue, $0.1.rawValue) }
        let query = model.listQuery(.facts)
        let matching = query.isEmpty ? nil : Set(facts.filter { $0.matches(query) }.map(\.id.rawValue))
        let selected = model.selectedEntryID.flatMap { ids.contains($0) ? $0.rawValue : nil }
        let near = selected.map { FactGraph.neighbourhood(of: $0, edges: edges, depth: depth) }
        // Focus only narrows the picture when the fact has neighbours; a lone fact never empties the graph.
        let shown = focus && (near?.count ?? 0) > 1 ? near : nil
        VStack(spacing: 0) {
            ListSearchField(key: .facts, prompt: "Highlight facts")
            TagFilterBar(key: .facts, available: every.map(\.tags))
            toolbar(hasSelection: (near?.count ?? 0) > 1)
            Divider()
            if facts.isEmpty {
                ListEmptyState(title: every.isEmpty ? "No facts yet" : "No facts have every picked tag", systemImage: "point.3.connected.trianglepath.dotted")
            } else if let points = model.factGraphLayout(nodes: facts.map(\.id.rawValue), edges: edges) {
                graph(facts: facts, edges: edges, points: points, selected: selected, near: near, shown: shown, matching: matching)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Laying out \(facts.count) facts…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                Spacer()
            }
            legend(facts)
        }
        .navigationSubtitle("Facts")
    }

    private func toolbar(hasSelection: Bool) -> some View {
        ChipRow(spacing: 8) {
            Button { zoom(by: 1 / 1.4) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out")
            Button { zoom(by: 1.4) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in")
            Button("Fit") { withAnimation { scale = 1; baseScale = 1; offset = .zero; baseOffset = .zero } }
                .help("Show every fact")
            Toggle("Focus", isOn: $focus)
                .toggleStyle(.button)
                .disabled(!hasSelection)
                .help("Show only the picked fact and its neighbours")
            Picker("Depth", selection: $depth) {
                Text("Neighbours").tag(1)
                Text("2 links away").tag(2)
            }
            .labelsHidden()
            .fixedSize()
            .help("How far from the picked fact to light up")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func zoom(by factor: Double) {
        withAnimation {
            scale = min(max(scale * factor, 0.2), 8)
            baseScale = scale
        }
    }

    /// The colours in use, so a colour can be read; a fact takes its first tag's colour.
    @ViewBuilder
    private func legend(_ facts: [KBEntry]) -> some View {
        let tags = EntryTags.vocabulary(facts.compactMap { $0.tags.first.map { [$0] } }).prefix(12)
        if !tags.isEmpty {
            Divider()
            ChipRow(spacing: 8) {
                ForEach(Array(tags), id: \.tag) { t in
                    HStack(spacing: 4) {
                        Circle().fill(Self.colour(for: t.tag)).frame(width: 8, height: 8)
                        Text(t.tag).lineLimit(1)
                    }
                    .fixedSize()
                }
                HStack(spacing: 4) {
                    Circle().fill(Color.secondary).frame(width: 8, height: 8)
                    Text("no tag")
                }
                .fixedSize()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    static func colour(for tag: String?) -> Color {
        guard let tag else { return .secondary }
        return palette[FactGraph.colourSlot(tag, count: palette.count)]
    }

    private func graph(facts: [KBEntry], edges: [FactGraph.Edge], points: [String: FactGraph.Point], selected: String?,
                       near: Set<String>?, shown: Set<String>?, matching: Set<String>?) -> some View {
        let byID = Dictionary(facts.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { a, _ in a })
        let visible = points.filter { shown?.contains($0.key) ?? true }
        let box = FactGraph.bounds(Array(visible.values)) ?? (minX: -1, minY: -1, maxX: 1, maxY: 1)
        return GeometryReader { geo in
            // Margins in points, so the outer dots keep room for their labels however narrow the column is.
            let side: CGFloat = 90, top: CGFloat = 24, bottom: CGFloat = 44
            let usableW = max(geo.size.width - side * 2, 40), usableH = max(geo.size.height - top - bottom, 40)
            let fit = min(usableW / max(box.maxX - box.minX, 80), usableH / max(box.maxY - box.minY, 80))
            let k = fit * scale
            let cx = (box.minX + box.maxX) / 2, cy = (box.minY + box.maxY) / 2
            let toScreen = { (p: FactGraph.Point) -> CGPoint in
                CGPoint(x: (p.x - cx) * k + geo.size.width / 2 + offset.width,
                        y: (p.y - cy) * k + top + usableH / 2 + offset.height)
            }
            Canvas { ctx, size in
                for e in edges {
                    guard let a = visible[e.a], let b = visible[e.b] else { continue }
                    let lit = near.map { $0.contains(e.a) && $0.contains(e.b) } ?? false
                    var path = Path()
                    path.move(to: toScreen(a))
                    path.addLine(to: toScreen(b))
                    ctx.stroke(path, with: .color(lit ? Color.accentColor : Color.secondary.opacity(near == nil ? 0.45 : 0.15)),
                               lineWidth: lit ? 2 : 1)
                }
                let labelAll = k > 1.1 || visible.count <= 25
                var labels: [(rank: Int, text: GraphicsContext.ResolvedText, at: CGPoint, size: CGSize)] = []
                for (id, p) in visible {
                    let s = toScreen(p)
                    let entry = byID[id]
                    let dim = (near.map { !$0.contains(id) } ?? false) || (matching.map { !$0.contains(id) } ?? false)
                    let r: CGFloat = id == selected ? 8 : 5.5
                    let dot = Path(ellipseIn: CGRect(x: s.x - r, y: s.y - r, width: r * 2, height: r * 2))
                    ctx.fill(dot, with: .color(Self.colour(for: entry?.tags.first).opacity(dim ? 0.2 : 1)))
                    if id == selected { ctx.stroke(dot, with: .color(.primary), lineWidth: 2) }
                    let lit = (near?.contains(id) ?? false) || (matching?.contains(id) ?? false)
                    guard labelAll || id == selected || lit, let title = entry?.title else { continue }
                    let short = title.count > 40 ? String(title.prefix(38)) + "…" : title
                    let text = ctx.resolve(Text(short).font(.caption2)
                        .foregroundStyle(dim ? Color.secondary.opacity(0.4) : Color.primary))
                    labels.append((id == selected ? 0 : lit ? 1 : 2, text, CGPoint(x: s.x, y: s.y + r + 7),
                                   text.measure(in: CGSize(width: 400, height: 40))))
                }
                // Labels never overlap: the picked and lit ones go first, a later one moves down a line or two, and
                // one that still collides is left out until zooming in makes room.
                var taken: [CGRect] = []
                for l in labels.sorted(by: { $0.rank < $1.rank }) {
                    let half = l.size.width / 2 + 4
                    let x = size.width > half * 2 ? min(max(l.at.x, half), size.width - half) : size.width / 2
                    for step in 0..<3 {
                        let rect = CGRect(x: x - half, y: l.at.y + CGFloat(step) * (l.size.height + 1), width: half * 2,
                                          height: l.size.height)
                        guard l.rank == 0 || !taken.contains(where: { $0.intersects(rect) }) else { continue }
                        taken.append(rect)
                        ctx.draw(l.text, at: CGPoint(x: x, y: rect.minY), anchor: .top)
                        break
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { v in offset = CGSize(width: baseOffset.width + v.translation.width, height: baseOffset.height + v.translation.height) }
                .onEnded { _ in baseOffset = offset })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { v in scale = min(max(baseScale * v.magnification, 0.2), 8) }
                .onEnded { _ in baseScale = scale })
            .onTapGesture { location in
                let hit = visible.min { a, b in
                    let pa = toScreen(a.value), pb = toScreen(b.value)
                    return hypot(pa.x - location.x, pa.y - location.y) < hypot(pb.x - location.x, pb.y - location.y)
                }
                if let hit, hypot(toScreen(hit.value).x - location.x, toScreen(hit.value).y - location.y) < 14,
                   let id = EntryID(hit.key) {
                    model.openFactFromGraph(id)
                }
            }
            .help("Drag to move, pinch to zoom, click a dot to open the fact")
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipped()
    }
}
