import KBCore
import KBEngine
import SwiftUI

extension EntrySharing {
    var color: Color {
        switch self {
        case .private, .noRepository: return .secondary
        case .uncommitted, .unpushed, .local, .missing: return .orange
        case .pushed: return .green
        }
    }
}

extension AppModel {
    func sharingHelp(_ id: EntryID) -> String {
        let repo = sharing.repos[id.project]
        return sharingState(id).help(repo: repo?.name, branch: repo?.branch)
    }

    /// Whether an entry can be shared at all: everything kept in a scope folder except inbox proposals.
    func canShare(_ id: EntryID) -> Bool { id.section != .inbox }
}

/// The small private/shared icon on an entry row; hover says what it means.
struct SharingIcon: View {
    @Environment(AppModel.self) private var model
    let id: EntryID

    var body: some View {
        if model.canShare(id) {
            let state = model.sharingState(id)
            Image(systemName: state.symbol)
                .font(.caption2)
                .foregroundStyle(state.color)
                .help(model.sharingHelp(id))
                .accessibilityLabel(state.title)
        }
    }
}

/// The entry header's sharing control: the state, why, and the switch between private and shared.
struct SharingMenu: View {
    @Environment(AppModel.self) private var model
    let id: EntryID

    var body: some View {
        if model.canShare(id) {
            let state = model.sharingState(id)
            Menu {
                SharingItems(id: id)
            } label: {
                HStack(spacing: 4) {
                    if model.sharingBusy.contains(id) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: state.symbol).foregroundStyle(state.color)
                    }
                    Text(state.title)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(model.sharingHelp(id))
        }
    }
}

/// Private / Shared choices, for the header menu and the list's right-click menu.
struct SharingItems: View {
    @Environment(AppModel.self) private var model
    let id: EntryID

    var body: some View {
        let state = model.sharingState(id)
        let repo = model.sharing.repos[id.project]?.name ?? "the repository"
        Text(state.title)
        Divider()
        Button {
            model.setShared(id, false)
        } label: {
            Label("Private (only in my knowledge base)", systemImage: state.isShared ? "lock" : "checkmark")
        }
        .disabled(!state.isShared)
        Button {
            model.setShared(id, true)
        } label: {
            Label("Shared with the team (copy in \(repo))", systemImage: state.isShared ? "checkmark" : "person.2")
        }
        .disabled(state.isShared || state == .noRepository)
    }
}
