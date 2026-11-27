import KBCore
import KBEngine
import SwiftUI

/// The assistants to pick the brain from: the one KB runs everything through, and whose name the app uses.
struct BrainPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(AIProvider.all) { p in
                let picked = model.aiSetup.brainProvider.id == p.id
                Button {
                    if p.supported { model.aiSetup.brain = p.id }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: picked ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(picked ? Color.accentColor : .secondary)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).fontWeight(.medium)
                            Text(p.supported ? note(p) : "Mindmill can't run its sessions through \(p.shortName) yet. Its skills can already go in \(p.shortName): see Mindmill's skills below.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(picked ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!p.supported)
                .opacity(p.supported ? 1 : 0.6)
            }
        }
    }

    private func note(_ p: AIProvider) -> String {
        p.id == AIProvider.claudeCode.id
            ? "Runs sessions, questions and the background work, with Mindmill's skills and your connected tools."
            : "Runs sessions, questions and the background work."
    }
}

/// Which assistant and model each task uses. Unset tasks use the brain with its default model.
struct TaskAssignments: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(AITask.allCases) { task in
                AdaptiveCardLayout(spacing: 10, stackedSpacing: 4, minInfoWidth: 200) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(task.title)
                        Text(task.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Picker(task.title, selection: binding(task)) {
                        Text("\(model.brainName), its default").tag("")
                        ForEach(AIProvider.all.filter(\.supported)) { p in
                            ForEach(p.models, id: \.self) { m in
                                Text("\(p.shortName) · \(m)").tag("\(p.id)|\(m)")
                            }
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }

    private func binding(_ task: AITask) -> Binding<String> {
        Binding(
            get: {
                guard let a = model.aiSetup.tasks[task], !a.model.isEmpty else { return "" }
                return "\(a.provider)|\(a.model)"
            },
            set: { value in
                let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
                model.aiSetup.tasks[task] = parts.count == 2 ? .init(provider: parts[0], model: parts[1]) : nil
            })
    }
}

/// Where each assistant finds Mindmill's skills: Claude Code through the plugin, Codex and Gemini CLI in
/// `~/.agents/skills`, placed while the assistant is in use or the user asked for them there.
struct SkillPlacesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let inUse = AssistantSkills.providers(model.aiSetup)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(AIProvider.all) { p in
                AdaptiveCardLayout(spacing: 10, stackedSpacing: 4, minInfoWidth: 200) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).fontWeight(.medium)
                        Text(place(p, placed: inUse.contains(p.id)))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if AssistantSkills.folder(for: p.id) != nil {
                        Toggle("Put Them Here", isOn: binding(p.id))
                            .disabled(inUse.contains(p.id) && !(model.aiSetup.skillsIn ?? []).contains(p.id))
                            .help("Use Mindmill's skills in \(p.shortName) directly, even when it isn't the brain")
                            .fixedSize()
                    }
                }
            }
        }
    }

    private func place(_ p: AIProvider, placed: Bool) -> String {
        guard let folder = AssistantSkills.folder(for: p.id) else {
            return "Through Mindmill's plugin, as \(AssistantSkills.invocation("notes", provider: p.id)) and the rest."
        }
        let path = KBConfig.abbreviateTilde(folder.path)
        return placed
            ? "In \(path), as \(AssistantSkills.invocation("notes", provider: p.id)) and the rest. They follow Mindmill's updates."
            : "Not placed. Turned on, or once \(p.shortName) is in use, they go in \(path)."
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { AssistantSkills.providers(model.aiSetup).contains(id) },
            set: { on in
                var list = model.aiSetup.skillsIn ?? []
                list.removeAll { $0 == id }
                if on { list.append(id) }
                model.aiSetup.skillsIn = list.isEmpty ? nil : list
            })
    }
}
