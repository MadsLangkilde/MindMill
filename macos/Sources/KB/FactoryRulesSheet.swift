import KBCore
import KBEngine
import SwiftUI

/// The parts of the rules, so the outline can show what the one under the pointer changes.
private enum FactoryTopic {
    case pick, strategy, exceptions, delivery, newWork, asks, run

    var steps: Set<FactoryStep> {
        switch self {
        case .pick: return [.pick]
        case .strategy: return [.start, .deliver]
        case .exceptions: return [.start]
        case .delivery: return [.deliver]
        case .newWork: return [.newWork]
        case .asks: return []
        case .run: return [.stop]
        }
    }

    var about: String {
        switch self {
        case .pick: return "Which work items it may take. It only ever takes yours, or unassigned ones that it assigns to you first."
        case .strategy: return "A strategy decides how a session works: alone, or as a lead with builders and reviewers. The default strategy is used for every item, unless an exception fits it."
        case .exceptions: return "Exceptions give some items another strategy than the default, for example bugs or items with a certain tag. The first exception that fits an item decides."
        case .delivery: return "What happens when the code is done: push the branch, open a pull request, or also complete it once it's approved."
        case .newWork: return "While it builds, a session may find work that should be its own item: a bug, a missing piece. It can create those for you, and the factory picks them up."
        case .asks: return "Where a session may stop to ask you. Asking never stops the work: the session carries on with what doesn't depend on the answer, and the question waits in the Factory view."
        case .run: return "How long the factory keeps taking new work. When it stops, sessions finish the step they're on and push their work."
        }
    }
}

/// Sets up a software factory: what it takes, how it builds, when it asks, and how long it runs, with an outline of
/// what it will do beside the rules.
struct FactoryRulesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: FactoryEditRequest
    @State private var name = "Software Factory"
    @State private var rules = FactoryRules()
    @State private var newAsk = ""
    @State private var loaded = false
    @State private var topic: FactoryTopic?
    @State private var editingAsks = false
    @State private var newStrategy: StrategyEditorRequest?
    @State private var strategiesBefore: Set<String> = []
    /// The new-work setting to go back to when "Create new work items" is turned on again.
    @State private var lastCreateMode: FactoryRules.NewWorkItems = .propose

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "gearshape.2.fill").foregroundStyle(Color.accentColor).font(.title2)
                TextField("Name", text: $name).textFieldStyle(.plain).font(.title2.weight(.semibold))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            HStack(spacing: 0) {
                Form {
                    pickSection
                    buildSection
                    exceptionsSection
                    newWorkSection
                    askSection
                    runSection
                }
                .formStyle(.grouped)
                .multilineTextAlignment(.leading)
                .frame(minWidth: 540, maxWidth: .infinity)
                Divider()
                ScrollView {
                    FactoryOutlineView(rules: rules, topic: topic).padding(18)
                }
                .frame(width: 350)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            }
            Divider()
            footer
        }
        .frame(minWidth: 900, idealWidth: 1040, minHeight: 600, idealHeight: 820)
        .onAppear(perform: load)
        .sheet(isPresented: $editingAsks) { FactoryAskEditor(rules: $rules) }
        .sheet(item: $newStrategy, onDismiss: useNewStrategy) { StrategyEditorSheet(request: $0) }
    }

    // MARK: Work it takes

    private enum Whose: Hashable { case mine, mineAndUnassigned, unassigned }
    private enum Kinds: Hashable { case both, pbis, bugs }

    private var whose: Binding<Whose> {
        Binding(get: {
            switch (rules.assignedToMe, rules.unassigned) {
            case (true, true): return .mineAndUnassigned
            case (false, true): return .unassigned
            default: return .mine
            }
        }, set: { w in
            rules.assignedToMe = w != .unassigned
            rules.unassigned = w != .mine
        })
    }

    private var kinds: Binding<Kinds> {
        Binding(get: { rules.pbis && rules.bugs ? .both : rules.bugs ? .bugs : .pbis },
                set: { k in
                    rules.pbis = k != .bugs
                    rules.bugs = k != .pbis
                })
    }

    private var pickSection: some View {
        Section {
            Group {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Scopes")
                    let scopes = model.factoryScopes
                    if scopes.isEmpty {
                        Text("No scope has a work-item tracker yet. Set one up in the scope's settings.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ChipRow(spacing: 6) {
                        ForEach(scopes) { p in
                            Toggle(isOn: scopeBinding(p.id)) { Label(p.title, systemImage: "folder") }
                                .toggleStyle(.button)
                        }
                    }
                }
                Picker("Whose items", selection: whose) {
                    Text("Assigned to me").tag(Whose.mine)
                    Text("Assigned to me, and unassigned").tag(Whose.mineAndUnassigned)
                    Text("Only unassigned").tag(Whose.unassigned)
                }
                Picker("Kinds", selection: kinds) {
                    Text("PBIs and bugs").tag(Kinds.both)
                    Text("Only PBIs").tag(Kinds.pbis)
                    Text("Only bugs").tag(Kinds.bugs)
                }
                Picker("Sprint", selection: $rules.sprint) {
                    ForEach(FactoryRules.SprintFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Continue my items already in progress", isOn: $rules.resumeStarted)
                Picker("Work items at a time", selection: Binding(get: { rules.maxParallel }, set: { n in
                    rules.maxParallel = n
                    UserDefaults.standard.set(n, forKey: Self.parallelKey)
                })) {
                    let choices = Set(FactoryRules.parallelChoices + [rules.maxParallel]).sorted()
                    ForEach(choices, id: \.self) { Text("\($0)").tag($0) }
                }
                .help("How many work items it works on at once, each in a session of its own. New factories start with the number you chose last.")
            }
            .onHover { if $0 { topic = .pick } }
        } header: {
            Text("Work it takes")
        } footer: {
            Text(rules.unassigned
                 ? "It assigns an unassigned item to you before it starts on it. It never takes an item someone else is assigned to, or one a session already works on."
                 : "It never takes an item someone else is assigned to, or one a session already works on.")
                .foregroundStyle(.secondary)
        }
    }

    private func scopeBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { rules.scopes.contains(id) },
                set: { on in
                    if on { if !rules.scopes.contains(id) { rules.scopes.append(id) } } else { rules.scopes.removeAll { $0 == id } }
                })
    }

    // MARK: How it builds

    private enum Delivery: Hashable { case push, open, complete }

    private var delivery: Binding<Delivery> {
        Binding(get: { !rules.openPRs ? .push : rules.completePRs ? .complete : .open },
                set: { d in
                    rules.openPRs = d != .push
                    rules.completePRs = d == .complete
                })
    }

    private var buildSection: some View {
        Section {
            Group {
                LabeledContent("Default strategy") {
                    HStack(spacing: 8) {
                        strategyPicker($rules.defaultStrategy)
                        Button("New Strategy…") {
                            strategiesBefore = Set(model.strategies.map(\.slug))
                            newStrategy = .new
                        }
                        .help("Make a new strategy; it becomes the default here")
                    }
                }
                if let st = model.strategies.first(where: { $0.slug == rules.defaultStrategy }), !st.summary.isEmpty {
                    Text(st.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .onHover { if $0 { topic = .strategy } }
            Picker("When the code is done", selection: delivery) {
                Text("Push the branch, no pull request").tag(Delivery.push)
                Text("Open a pull request; I merge").tag(Delivery.open)
                Text("Open a pull request and complete it once approved").tag(Delivery.complete)
            }
            .onHover { if $0 { topic = .delivery } }
        } header: {
            Text("How it builds")
        } footer: {
            Text("Every work item gets the default strategy, unless one of the exceptions below fits it.").foregroundStyle(.secondary)
        }
    }

    private func strategyPicker(_ selection: Binding<String>) -> some View {
        Picker("Strategy", selection: selection) {
            Text("None: one session works alone").tag("")
            ForEach(model.strategies) { Text($0.title).tag($0.slug) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private var exceptionsSection: some View {
        Section {
            Group {
                if rules.strategyRules.isEmpty {
                    Text("None: every item gets the default strategy.").foregroundStyle(.secondary)
                }
                ForEach($rules.strategyRules) { $rule in
                    FactoryExceptionRow(rule: $rule, picker: strategyPicker) {
                        rules.strategyRules.removeAll { $0.id == rule.id }
                    }
                }
                Button {
                    rules.strategyRules.append(FactoryStrategyRule(match: .bug, strategy: rules.defaultStrategy))
                } label: {
                    Label("Add an Exception", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
            .onHover { if $0 { topic = .exceptions } }
        } header: {
            Text("Exceptions to the default strategy")
        } footer: {
            Text("Checked from the top: the first exception that fits an item decides its strategy. For example, bugs use a quick strategy and items tagged “ble” a careful one.")
                .foregroundStyle(.secondary)
        }
    }

    private func useNewStrategy() {
        if let slug = model.strategies.map(\.slug).first(where: { !strategiesBefore.contains($0) }) {
            rules.defaultStrategy = slug
        }
        strategiesBefore = []
    }

    // MARK: New work items

    private var createsWork: Binding<Bool> {
        Binding(get: { rules.newWorkItems != .never },
                set: { on in rules.newWorkItems = on ? lastCreateMode : .never })
    }

    private var asksBeforeCreating: Binding<Bool> {
        Binding(get: { rules.newWorkItems == .propose },
                set: { ask in
                    rules.newWorkItems = ask ? .propose : .create
                    lastCreateMode = rules.newWorkItems
                })
    }

    private var newWorkSection: some View {
        Section {
            Group {
                Toggle(isOn: createsWork) {
                    OptionLabel(title: "Create new work items",
                                detail: "When a session finds work that should be its own item, like a bug or a missing piece, it creates it in the tracker, assigned to you, and the factory picks it up by these rules.")
                }
                if rules.newWorkItems != .never {
                    Toggle(isOn: asksBeforeCreating) {
                        OptionLabel(title: "Ask me before creating each one",
                                    detail: rules.newWorkItems == .propose
                                        ? "The question waits in the Factory view with Create it and Leave it; the session carries on meanwhile."
                                        : "It creates them right away.")
                    }
                    .padding(.leading, 20)
                }
            }
            .onHover { if $0 { topic = .newWork } }
        } header: {
            Text("New work items")
        } footer: {
            if rules.newWorkItems == .never {
                Text("Off: a session mentions what it found in its report and creates nothing.").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: When it asks you

    private var askSection: some View {
        Section {
            Group {
                Toggle(isOn: $rules.asks) {
                    OptionLabel(title: "Ask me questions",
                                detail: rules.asks ? "At the moments ticked below."
                                    : "Never: it makes the reasonable choice and lists its assumptions in its report and the pull request.")
                }
                if rules.asks {
                    ForEach(rules.askPoints) { point in
                        Toggle(isOn: Binding(get: { point.isOn }, set: { rules.setAsk(point.id, on: $0) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(point.title.isEmpty ? "Untitled" : point.title).fixedSize(horizontal: false, vertical: true)
                                    if point.isEdited { Chip(text: "Edited", color: .orange) }
                                    if point.isCustom { Chip(text: "Yours", color: .accentColor) }
                                }
                                if !point.detail.isEmpty {
                                    Text(point.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.leading, 20)
                    }
                    HStack(spacing: 8) {
                        TextField("Your own", text: $newAsk, prompt: Text("Add your own, e.g. Before changing the database schema"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addAsk)
                        Button("Add", action: addAsk)
                            .disabled(newAsk.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.leading, 20)
                }
            }
            .onHover { if $0 { topic = .asks } }
        } header: {
            HStack {
                Text("When it asks you")
                Spacer()
                Button { editingAsks = true } label: { Label("Edit Texts…", systemImage: "square.and.pencil") }
                    .buttonStyle(.borderless)
                    .help("Change what the sessions are told for each moment, and add or remove your own")
            }
        } footer: {
            Text("Asking never stops the work: a session carries on with everything that doesn't depend on the answer, and the question waits in the Factory view. What you answer that others would need comes back as a fact for you to confirm.")
                .foregroundStyle(.secondary)
        }
    }

    private func addAsk() {
        let t = newAsk.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        rules.addAsk(t)
        newAsk = ""
    }

    // MARK: How long it runs

    private var runSection: some View {
        Section("How long it runs") {
            Group {
                Picker("Runs", selection: $rules.duration) {
                    ForEach(FactoryRules.Duration.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                switch rules.duration {
                case .untilStopped: EmptyView()
                case .hours:
                    Stepper("For \(rules.hours.formatted(.number.precision(.fractionLength(0...1)))) hour\(rules.hours == 1 ? "" : "s")",
                            value: $rules.hours, in: 0.5...72, step: 0.5)
                case .until:
                    DatePicker("Until", selection: $rules.until, in: Date()...)
                }
            }
            .onHover { if $0 { topic = .run } }
        }
    }

    private var footer: some View {
        HStack {
            if let p = rules.problems.first {
                Label(p, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).lineLimit(2)
            }
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save") {
                let id = model.saveFactory(id: request.factoryID, name: name, rules: rules)
                model.showFactory(id)
                dismiss()
            }
            if !(model.factory(request.factoryID)?.isRunning ?? false) {
                Button("Save and Start") {
                    let id = model.saveFactory(id: request.factoryID, name: name, rules: rules)
                    model.showFactory(id)
                    model.startFactory(id)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!rules.problems.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    static let parallelKey = FactoryLoop.parallelKey

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let f = model.factory(request.factoryID) {
            name = f.name
            rules = f.rules
        } else {
            if let p = model.projectID, model.factoryScopes.contains(where: { $0.id == p }) { rules.scopes = [p] }
            name = model.factories.isEmpty ? "Software Factory" : "Software Factory \(model.factories.count + 1)"
            let last = UserDefaults.standard.integer(forKey: Self.parallelKey)
            if last > 0 { rules.maxParallel = last }
        }
        if rules.newWorkItems != .never { lastCreateMode = rules.newWorkItems }
    }
}

/// A title with a line under it that says what the option does.
private struct OptionLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "When <the item is a bug> use <strategy>", on one line when it fits, else on two.
private struct FactoryExceptionRow<P: View>: View {
    @Binding var rule: FactoryStrategyRule
    let picker: (Binding<String>) -> P
    let remove: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                when
                use
                Spacer(minLength: 0)
                removeButton
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    when
                    Spacer(minLength: 0)
                    removeButton
                }
                use.padding(.leading, 12)
            }
        }
    }

    private var when: some View {
        HStack(spacing: 6) {
            Text("When").fixedSize()
            Picker("When", selection: $rule.match) {
                ForEach(FactoryStrategyRule.Match.allCases, id: \.self) { Text($0.phrase).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            if rule.match.needsValue {
                TextField(rule.match == .tag ? "Tag" : "Words", text: $rule.value, prompt: Text(rule.match == .tag ? "tag" : "words"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
            }
        }
    }

    private var use: some View {
        HStack(spacing: 6) {
            Text("use").fixedSize()
            picker($rule.strategy)
        }
    }

    private var removeButton: some View {
        Button(action: remove) { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .help("Remove this exception")
    }
}

/// What the factory will do with each work item, step by step, under the rules as they are set now.
private struct FactoryOutlineView: View {
    @Environment(AppModel.self) private var model
    let rules: FactoryRules
    let topic: FactoryTopic?

    var body: some View {
        let steps = rules.outline(scopeTitle: { model.index.project($0)?.title ?? $0 },
                                  strategyTitle: { s in model.strategies.first { $0.slug == s }?.title ?? s })
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What it will do").font(.headline)
                Text("Each work item it takes goes through these steps in a \(Brain.name) session of its own. Orange marks where it asks you.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let topic {
                Text(topic.about)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                    stepRow(step, last: i == steps.count - 1)
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: topic)
    }

    private func stepRow(_ step: FactoryOutlineStep, last: Bool) -> some View {
        let lit = topic?.steps.contains(step.id) ?? false
        let asksLit = topic == .asks && !step.asks.isEmpty
        return HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Image(systemName: Self.icon(step.id))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Self.color(step.id).opacity(lit || topic == nil ? 1 : 0.55), in: Circle())
                if !last {
                    Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(step.title).font(.callout.weight(.semibold))
                Text(step.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if step.id == .start, let st = model.strategies.first(where: { $0.slug == rules.defaultStrategy }) {
                    StrategyMiniFlow(strategy: st)
                }
                if !step.asks.isEmpty {
                    ChipRow(spacing: 4) {
                        ForEach(step.asks, id: \.self) { AskTag(text: $0, strong: asksLit) }
                    }
                }
            }
            .padding(.top, 3)
            .padding(.bottom, last ? 0 : 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(6)
        .background(lit ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }

    static func icon(_ s: FactoryStep) -> String {
        switch s {
        case .pick: return "tray.and.arrow.down"
        case .start: return "play.fill"
        case .plan: return "list.bullet.clipboard"
        case .build: return "hammer.fill"
        case .newWork: return "plus.square.on.square"
        case .deliver: return "arrow.triangle.pull"
        case .stop: return "stop.fill"
        }
    }

    static func color(_ s: FactoryStep) -> Color {
        switch s {
        case .pick: return .blue
        case .start: return .purple
        case .plan: return .teal
        case .build: return .green
        case .newWork: return .indigo
        case .deliver: return .mint
        case .stop: return .gray
        }
    }
}

/// An orange "asks you" tag that wraps its text when it is long.
private struct AskTag: View {
    let text: String
    var strong = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: "questionmark.bubble.fill")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.orange)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.orange.opacity(strong ? 0.25 : 0.12), in: Capsule())
    }
}

/// Every moment a factory session may ask, with what it is told for each: change the wording, turn them on or off,
/// and add or remove your own.
struct FactoryAskEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var rules: FactoryRules

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("When It Asks You").font(.title2.weight(.semibold))
                Text("What a session is told for each moment it may stop to ask you. Change the wording to fit how you work, or add your own.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !rules.asks {
                        Text("Asking is off, so none of these are used until you turn on Ask me questions.")
                            .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(rules.askPoints) { point in
                        FactoryAskPointEditor(rules: $rules, point: point)
                    }
                    Button {
                        rules.addAsk("")
                    } label: {
                        Label("Add Your Own", systemImage: "plus")
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text("Changes apply when you save the factory.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    rules.customCheckpoints.removeAll { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 660)
        .frame(minHeight: 480, idealHeight: 700)
    }
}

private struct FactoryAskPointEditor: View {
    @Binding var rules: FactoryRules
    let point: FactoryAskPoint
    @State private var text = ""
    @State private var title = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Toggle("On", isOn: Binding(get: { point.isOn }, set: { rules.setAsk(point.id, on: $0) }))
                    .labelsHidden()
                if point.isCustom {
                    TextField("Moment", text: $title, prompt: Text("When it should ask, e.g. Before changing the database schema"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.body.weight(.medium))
                        .onChange(of: title) { _, t in rules.setAskTitle(point.id, t) }
                } else {
                    Text(point.title).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if point.isEdited {
                    Button("Reset") { text = point.defaultInstruction }
                        .buttonStyle(.borderless)
                        .help("Go back to the original wording")
                }
                if point.isCustom {
                    Button { rules.removeAsk(point.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Remove this one")
                }
            }
            if !point.detail.isEmpty {
                Text(point.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(point.isCustom ? "More for the session (optional)" : "What the session is told")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 52)
                .padding(4)
                .background(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(point.isCustom ? "What it should include when it asks, or what to check first" : point.defaultInstruction)
                            .font(.callout).foregroundStyle(.tertiary)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                    }
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                .onChange(of: text) { _, t in rules.setAskInstruction(point.id, t) }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .opacity(point.isOn ? 1 : 0.7)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            text = point.instruction
            title = point.title
        }
    }
}
