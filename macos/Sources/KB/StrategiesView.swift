import KBCore
import SwiftUI

/// The strategy choices for a session, for menus.
struct StrategyMenuItems: View {
    @Environment(AppModel.self) private var model
    let session: WorkSession

    var body: some View {
        Menu("Strategy") {
            ForEach(model.strategies) { st in
                Button {
                    model.applyStrategy(st, to: session)
                } label: {
                    if session.strategy == st.slug { Label(st.title, systemImage: "checkmark") } else { Text(st.title) }
                }
            }
            if session.strategy != nil {
                Divider()
                Button("No Strategy") { model.clearStrategy(session) }
            }
            Divider()
            Button("Manage Strategies…") { model.strategiesSheet = StrategiesSheetRequest(selected: session.strategy) }
        }
    }
}

/// In a session's header: the strategy it follows, or a quiet way to pick one.
struct StrategyButton: View {
    @Environment(AppModel.self) private var model
    let session: WorkSession

    var body: some View {
        let current = session.strategy.flatMap { slug in model.strategies.first { $0.slug == slug } }
        Menu {
            ForEach(model.strategies) { st in
                Button {
                    model.applyStrategy(st, to: session)
                } label: {
                    if session.strategy == st.slug { Label(st.title, systemImage: "checkmark") } else { Text(st.title) }
                }
                .help(st.summary)
            }
            if current != nil {
                Divider()
                Button("No Strategy") { model.clearStrategy(session) }
            }
            Divider()
            Button("Manage Strategies…") { model.strategiesSheet = StrategiesSheetRequest(selected: session.strategy) }
        } label: {
            Label(current?.title ?? "Strategy", systemImage: "point.3.connected.trianglepath.dotted")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(current == nil ? .secondary : .primary)
        .help(current.map { "Strategy: \($0.title). \($0.summary)" } ?? "Work with a strategy, for example one that starts sessions by itself")
    }
}


/// Every strategy with its details and diagram. Built-in ones are read-only (copy one to make your own);
/// yours can be edited and deleted, and new ones made.
struct StrategiesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?
    @State private var editing: StrategyEditorRequest?
    @State private var confirmDelete = false

    init(request: StrategiesSheetRequest) {
        _selected = State(initialValue: request.selected)
    }

    var body: some View {
        let current = model.strategies.first { $0.slug == selected }
        VStack(spacing: 0) {
            HSplitView {
                let query = model.listQuery(.strategies)
                let shown = query.isEmpty ? model.strategies : model.strategies.filter { $0.matches(query) }
                VStack(spacing: 0) {
                    ListSearchField(key: .strategies, prompt: "Search strategies")
                    List(selection: $selected) {
                        if shown.isEmpty { ListSearchNoMatch(query: query) }
                        let builtIn = shown.filter(\.isBuiltIn)
                        if !builtIn.isEmpty || query.isEmpty {
                            Section("Built in") {
                                ForEach(builtIn) { row($0) }
                            }
                        }
                        let own = shown.filter { !$0.isBuiltIn }
                        if !own.isEmpty || query.isEmpty {
                            Section("Yours") {
                                if own.isEmpty { Text("None yet").foregroundStyle(.secondary).font(.callout) }
                                ForEach(own) { row($0) }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
                .frame(minWidth: 210, idealWidth: 230, maxWidth: 280)
                ScrollView {
                    if let current {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(current.title).font(.title3.weight(.semibold))
                            if !current.summary.isEmpty { Text(current.summary).foregroundStyle(.secondary) }
                            StrategyDetails(strategy: current)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Pick a strategy").foregroundStyle(.secondary).padding(40)
                    }
                }
                .frame(minWidth: 420)
            }
            Divider()
            HStack {
                Button { editing = .new } label: { Label("New Strategy…", systemImage: "plus") }
                Button {
                    model.draftStrategyWithClaude()
                    dismiss()
                } label: {
                    Label("Describe One to \(Brain.name)…", systemImage: "sparkles")
                }
                Spacer()
                if let current {
                    if current.isBuiltIn {
                        Button("Copy to Make My Own…") { editing = .copy(of: current) }
                    } else {
                        Button("Delete…", role: .destructive) { confirmDelete = true }
                        Button("Edit…") { editing = .edit(current) }
                    }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 860, height: 620)
        .onAppear { if selected == nil { selected = model.strategies.first?.slug } }
        .sheet(item: $editing) { StrategyEditorSheet(request: $0) }
        .confirmationDialog("Delete “\(current?.title ?? "")”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let current { model.deleteStrategy(current) }
                selected = model.strategies.first?.slug
            }
        } message: {
            Text("Sessions already using it keep their instructions.")
        }
    }

    private func row(_ st: Strategy) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(st.title)
            StrategyMiniFlow(strategy: st)
        }
        .tag(st.slug)
    }
}
