import KBCore
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
                            Text(p.supported ? note(p) : "Mindmill can't work through \(p.shortName) yet. It needs Mindmill's skills and tools in \(p.shortName) first.")
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
