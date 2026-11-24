import AppKit
import KBCore
import KBEngine
import SwiftUI

/// Build's sidebar: Test, with whether the current project is set up.
struct TestSidebarRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let scope = model.testing.selectedScope ?? model.projectID
        let plan = scope.map { model.testing.store[$0] } ?? ScopeTestPlan()
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal").foregroundStyle(plan.isSetUp ? Color.green : Color.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Test").font(.body.weight(.medium))
                Text(!model.testing.working.isEmpty ? "Delivering…" : plan.isSetUp ? "Set up" : "Set up testing")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !plan.suggestions.isEmpty { NeedsBadge(count: plan.suggestions.count).help("Suggestions from sessions") }
        }
        .padding(.vertical, 3)
    }
}

/// Set up, check and run testing of what sessions and factories build: one place per project.
struct TestView: View {
    @Environment(AppModel.self) private var model
    @State private var moreOptions: Set<String> = []

    private var scope: String? { model.testing.selectedScope ?? model.projectID }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let scope {
                    CompatibilityCard(scope: scope)
                    SuggestionsCard(scope: scope)
                    let plan = model.testing.store[scope]
                    if plan.targets.isEmpty {
                        ListEmptyState(title: "Nothing to test found", systemImage: "magnifyingglass",
                                       message: model.repositories(of: scope).work.contains { $0.checkout != nil }
                                        ? "Mindmill didn't recognise an app, site, service or firmware in this project's repositories."
                                        : "This project has no repository on this Mac. Add a location in Edit Projects and Scopes.") {
                            Button("Look Again") { model.detectTestTargets(scope) }
                        }
                    } else {
                        ForEach(ordered(plan.targets)) { t in
                            TargetCard(scope: scope, target: t, moreOptions: binding(t.id))
                        }
                        DeliverWhenRow(scope: scope)
                    }
                    RecentDeliveries(scope: scope)
                } else {
                    ListEmptyState(title: "No project", systemImage: "folder", message: "Open a project to set up its testing.")
                }
            }
            .frame(maxWidth: 760, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(18)
        }
        .task(id: scope) {
            guard let scope else { return }
            if model.testing.store[scope].targets.isEmpty { model.detectTestTargets(scope) }
            if model.testing.facts.gathered == nil { await model.gatherTestFacts() }
            await model.runCompatibilityCheck(scope)
        }
    }

    private var header: some View {
        AdaptiveCardLayout(spacing: 10, stackedSpacing: 8, minInfoWidth: 220) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Test").font(.title2.weight(.semibold))
                Text("How builds from sessions and factories reach you to try, on this Mac and on your phone.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Picker("Project", selection: Binding(get: { scope ?? "" }, set: { model.testing.selectedScope = $0.isEmpty ? nil : $0 })) {
                    ForEach(model.index.projects.filter { !$0.wide }) { Text($0.title).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
                Button {
                    Task {
                        await model.gatherTestFacts()
                        if let scope { model.detectTestTargets(scope) }
                    }
                } label: { Label(model.testing.gathering ? "Checking…" : "Check Again", systemImage: "arrow.clockwise") }
                .disabled(model.testing.gathering)
            }
            .fixedSize()
        }
    }

    private func ordered(_ targets: [TestTarget]) -> [TestTarget] {
        guard let first = model.testing.preselectType else { return targets }
        return targets.filter { $0.type == first } + targets.filter { $0.type != first }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { moreOptions.contains(id) }, set: { if $0 { moreOptions.insert(id) } else { moreOptions.remove(id) } })
    }
}

private struct CompatibilityCard: View {
    @Environment(AppModel.self) private var model
    let scope: String

    var body: some View {
        let result = model.testing.store[scope].compatibility
        let checking = model.testing.checking.contains(scope)
        VStack(alignment: .leading, spacing: 8) {
            AdaptiveCardLayout(spacing: 10, stackedSpacing: 8, minInfoWidth: 200) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if checking {
                        ProgressView().controlSize(.small)
                        Text("Checking what this Mac can build and test…").font(.callout)
                    } else if let result, result.good {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Good to go").font(.callout.weight(.semibold))
                        Text("Checked \(result.checked.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    } else if let result {
                        Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.orange)
                        Text("This Mac can't do everything for this project").font(.callout.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(result.checked.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                        Text(model.claudeAvailable ? "Not checked yet" : "\(Brain.name) isn't available to check").font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Check Again") { Task { await model.runCompatibilityCheck(scope, force: true) } }
                    .disabled(checking || !model.claudeAvailable)
                    .fixedSize()
            }
            if let result, !result.good, !checking {
                ForEach(result.findings) { f in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(f.title).font(.callout.weight(.semibold))
                        if !f.detail.isEmpty { Text(f.detail).font(.callout) }
                        if !f.canStill.isEmpty { Label(f.canStill, systemImage: "checkmark").font(.caption) }
                        if !f.cannot.isEmpty { Label(f.cannot, systemImage: "xmark").font(.caption).foregroundStyle(.orange) }
                        if let fix = f.fix { Label(fix, systemImage: "wrench.and.screwdriver").font(.caption).foregroundStyle(.secondary) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
    }
}

private struct SuggestionsCard: View {
    @Environment(AppModel.self) private var model
    let scope: String

    var body: some View {
        let list = model.testing.store[scope].suggestions
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Suggested by sessions").font(.headline)
                ForEach(list) { s in
                    AdaptiveCardLayout(spacing: 10, stackedSpacing: 6, minInfoWidth: 200) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                            if !s.set.isEmpty {
                                Text(s.set.keys.sorted().map { "\($0): \(s.set[$0] ?? "")" }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        HStack {
                            Button("Dismiss") { model.testing.edit(scope) { $0.dismiss(s.id) } }
                            Button("Accept") { model.testing.edit(scope) { $0.accept(s.id) } }.buttonStyle(.borderedProminent)
                        }
                        .fixedSize()
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.07)))
        }
    }
}

private struct TargetCard: View {
    @Environment(AppModel.self) private var model
    let scope: String
    let target: TestTarget
    @Binding var moreOptions: Bool

    var body: some View {
        let facts = model.currentTestFacts
        let adapter = target.adapter
        let chosen = target.method ?? adapter.recommended(facts)
        let method = adapter.method(chosen) ?? TestAdapters.preview
        let items = model.testChecklist(target, method: chosen)
        let ready = target.method != nil && ChecklistItem.ready(items)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: target.type.icon).foregroundStyle(.secondary)
                Text(target.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if ready {
                    Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(method.title).font(.callout.weight(.semibold))
                    if chosen == adapter.recommended(facts) {
                        Text("Recommended").font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.green.opacity(0.15)))
                    }
                }
                Text(method.why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if target.method == nil {
                    Button("Use This") { model.testing.editTarget(scope, target.id) { $0.method = chosen } }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 2)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items) { ChecklistRow(scope: scope, target: target, item: $0) }
            }
            if let working = model.testing.working[target.id] {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(working).font(.callout).foregroundStyle(.secondary)
                }
            } else {
                ChipRow(spacing: 8) {
                    Button { Task { await model.deliverTest(scope: scope, targetID: target.id) } } label: {
                        Label(deliverTitle(method), systemImage: "paperplane")
                    }
                    .disabled(!ready)
                    .help(ready ? "Build, test and deliver it now" : "Finish the checklist first")
                    if target.type == .web || target.type == .backend, model.testing.servers[target.id]?.isRunning == true {
                        Button { model.stopDevServer(target.id) } label: { Label("Stop Server", systemImage: "stop.circle") }
                    }
                    Button(moreOptions ? "Fewer Options" : "More Options") { moreOptions.toggle() }
                        .buttonStyle(.borderless)
                }
            }
            if let link = model.testing.deliveries.first(where: { $0.target == target.id && $0.kind == .iosLink && $0.url != nil })?.url {
                InstallLinkView(link: link)
            }
            if moreOptions { TargetOptions(scope: scope, target: target, chosen: chosen) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))
    }

    private func deliverTitle(_ m: TestMethod) -> String {
        switch m.kind {
        case .apk, .url, .preview: return "Deliver to Phone"
        case .iosDevice: return "Install on iPhone"
        case .iosLink: return "Make Install Link"
        case .testflight: return "Upload to TestFlight"
        }
    }
}

private struct ChecklistRow: View {
    @Environment(AppModel.self) private var model
    let scope: String
    let target: TestTarget
    let item: ChecklistItem
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon).foregroundStyle(color).frame(width: 16)
                Text(item.title + (item.required ? "" : " (optional)")).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if item.confirmable {
                    Toggle("Done", isOn: Binding(get: { item.status == .ok },
                                                 set: { on in model.testing.editTarget(scope, target.id) { $0.confirm(item.id, on) } }))
                        .toggleStyle(.checkbox)
                        .fixedSize()
                }
                if item.status != .ok, !item.help.isEmpty {
                    Button(open ? "Hide Steps" : "How") { open.toggle() }.buttonStyle(.borderless).fixedSize()
                }
            }
            if open && item.status != .ok {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(item.help.enumerated()), id: \.offset) { i, step in
                        Text("\(i + 1). \(step)").font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    Button("Check Again") { Task { await model.gatherTestFacts() } }.controlSize(.small).padding(.top, 2)
                }
                .padding(.leading, 24)
            }
        }
    }

    private var icon: String {
        switch item.status {
        case .ok: return "checkmark.circle.fill"
        case .missing: return "xmark.circle"
        case .unknown: return "circle.dashed"
        }
    }

    private var color: Color {
        switch item.status {
        case .ok: return .green
        case .missing: return item.required ? .orange : .secondary
        case .unknown: return .secondary
        }
    }
}

private struct TargetOptions: View {
    @Environment(AppModel.self) private var model
    let scope: String
    let target: TestTarget
    let chosen: String

    var body: some View {
        let others = target.adapter.ordered(model.currentTestFacts).filter { $0.id != chosen }
            + (target.adapter.method(TestAdapters.preview.id) == nil && chosen != TestAdapters.preview.id ? [TestAdapters.preview] : [])
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            if !others.isEmpty {
                Text("Other ways").font(.callout.weight(.semibold))
                ForEach(others) { m in
                    AdaptiveCardLayout(spacing: 10, stackedSpacing: 6, minInfoWidth: 200) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.title).font(.callout)
                            Text(m.why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Use") { model.testing.editTarget(scope, target.id) { $0.method = m.id } }.fixedSize()
                    }
                }
            }
            Text("Settings").font(.callout.weight(.semibold))
            field("Start command", \.startCommand, "e.g. npm run dev -- --host")
            field("Build command", \.buildCommand, target.type == .android ? "./gradlew assembleDebug" : "optional")
            field("Test command", \.testCommand, "e.g. npm test")
            if target.type == .web || target.type == .backend {
                field("Local URL", \.url, "e.g. http://localhost:3000")
                TextField("Port", text: Binding(get: { target.port.map(String.init) ?? "" },
                                                set: { v in model.testing.editTarget(scope, target.id) { $0.port = Int(v) } }))
                ListField(placeholder: target.type == .backend ? "Endpoints to call, one per line (GET /health)" : "Pages to open first, one per line",
                          items: Binding(get: { target.pages },
                                         set: { v in model.testing.editTarget(scope, target.id) { $0.set("pages", v.joined(separator: "\n")) } }),
                          perLine: true)
                    .lineLimit(2...6)
            }
            if target.type == .ios {
                field("Scheme", \.scheme, "found automatically")
                field("App Store Connect key ID", \.ascKeyID, "for TestFlight")
                field("App Store Connect issuer ID", \.ascIssuer, "for TestFlight")
            }
            if target.type == .embedded { field("Serial output command", \.serialCommand, "e.g. pio device monitor") }
            let devices = model.currentTestFacts.devices
            if !devices.isEmpty, target.type == .ios || target.type == .android {
                Picker("Device", selection: Binding(get: { target.devices.first ?? "" },
                                                    set: { v in model.testing.editTarget(scope, target.id) { $0.devices = v.isEmpty ? [] : [v] } })) {
                    Text("Automatic").tag("")
                    ForEach(devices) { Text("\($0.name) (\($0.kind.rawValue))").tag($0.id) }
                }
            }
            Text("\(target.repo)\(target.path.isEmpty ? "" : "/" + target.path)").font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let log = model.testing.logs[target.id], !log.isEmpty {
                DisclosureGroup("Last run") {
                    ScrollView { Text(String(log.suffix(8000))).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 220)
                }
                .font(.callout)
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func field(_ title: String, _ key: WritableKeyPath<TestTarget, String?>, _ prompt: String) -> some View {
        LabeledContent(title) {
            TextField(title, text: Binding(get: { target[keyPath: key] ?? "" },
                                           set: { v in model.testing.editTarget(scope, target.id) { $0[keyPath: key] = v.isEmpty ? nil : v } }),
                      prompt: Text(prompt))
                .labelsHidden()
        }
    }
}

private struct DeliverWhenRow: View {
    @Environment(AppModel.self) private var model
    let scope: String

    var body: some View {
        LabeledContent("Deliver to the phone") {
            Picker("Deliver", selection: Binding(get: { model.testing.store[scope].deliverWhen },
                                                 set: { v in model.testing.edit(scope) { $0.deliverWhen = v } })) {
                ForEach(DeliverWhen.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        Toggle("Ask about testing in this project's sessions", isOn: Binding(get: { !model.testing.store[scope].dontAsk },
                                                                            set: { v in model.testing.edit(scope) { $0.dontAsk = !v } }))
    }
}

private struct RecentDeliveries: View {
    @Environment(AppModel.self) private var model
    let scope: String

    var body: some View {
        let list = model.testing.deliveries.filter { $0.scope == scope }.prefix(8)
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recent deliveries").font(.headline)
                ForEach(Array(list)) { d in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: d.state == .failed ? "xmark.circle" : d.state == .building ? "hammer" : "checkmark.circle")
                            .foregroundStyle(d.state == .failed ? Color.orange : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(d.title) · \(d.created.formatted(date: .omitted, time: .shortened))").font(.callout)
                            if let m = d.message { Text(m).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                }
            }
        }
    }
}

private struct InstallLinkView: View {
    let link: String

    var body: some View {
        AdaptiveCardLayout(spacing: 12, stackedSpacing: 8, minInfoWidth: 180) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Scan with the iPhone's camera to install").font(.callout)
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            QRCodeImage(text: link).frame(width: 120, height: 120)
        }
    }
}

/// Under a Build session (or a factory's) that changed code in a project without testing: asked once.
struct TestAskCard: View {
    @Environment(AppModel.self) private var model
    let session: WorkSession

    var body: some View {
        let scope = session.project ?? ""
        let type = model.testing.store[scope].targets.first?.type
        AdaptiveCardLayout(spacing: 10, stackedSpacing: 8, minInfoWidth: 220) {
            Image(systemName: "checkmark.seal").foregroundStyle(.green).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(TestAskText.question(type)).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(TestAskText.detail(type, facts: model.currentTestFacts))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ChipRow(spacing: 8) {
                Button("Don't Ask for This Project") { model.testAnswer(session, scope: scope, "never") }
                Button("Not Now") { model.testAnswer(session, scope: scope, "later") }
                Button("Set Up Testing") { model.testAnswer(session, scope: scope, "setup") }.buttonStyle(.borderedProminent)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.green.opacity(0.07))
        Divider()
    }
}

/// The session header's Test menu: deliver what the session builds to the phone, a preview or a link, or set it up.
struct TestHeaderButton: View {
    @Environment(AppModel.self) private var model
    let session: WorkSession

    var body: some View {
        let scope = session.project ?? ""
        let plan = model.testing.store[scope]
        let busy = plan.targets.contains { model.testing.working[$0.id] != nil }
        Menu {
            if plan.isSetUp {
                ForEach(plan.targets.filter { $0.method != nil }) { t in
                    Button(plan.targets.count > 1 ? "Deliver \(t.title)" : "Deliver to Phone") {
                        Task { await model.deliverTest(scope: scope, targetID: t.id, session: session.id) }
                    }
                    .disabled(model.testing.working[t.id] != nil || !model.testTargetReady(t))
                }
                Divider()
                Button("Open Test…") { model.openTestMenu(scope: scope) }
            } else {
                Button("Set Up Testing…") { model.openTestMenu(scope: scope) }
            }
        } label: {
            Label(busy ? "Delivering…" : "Test", systemImage: "iphone.and.arrow.forward")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Deliver what this session builds to your phone, a preview or a link")
    }
}
