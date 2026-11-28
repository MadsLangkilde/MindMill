import KBCore
import KBEngine
import SwiftUI

/// Shown wherever Claude needs a tool (calendar, Teams, email, Jira…) that is signed out or failing: why, and the fix.
struct ConnectorBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    private var problems: [ClaudeConnectors.Problem] {
        var out = model.connectorProblems
        let calendar = model.calendarSource
        // A sync can find the calendar refused before `claude mcp list` has been read, or missing from it.
        if model.calendarNeedsSignIn, !out.contains(where: { $0.server.name == calendar.server }) {
            out.insert(calendar.problem(in: model.connectorServers, checked: model.connectorsChecked != nil), at: 0)
        }
        return out
    }

    var body: some View {
        let problems = problems
        if !problems.isEmpty {
            AdaptiveCardLayout(spacing: 10, stackedSpacing: 6, minInfoWidth: 220) {
                Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(problems) { p in
                        Text(p.headline).fontWeight(.semibold)
                        Text(p.advice).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if calendarAffected(problems) {
                        Text("Until then the calendar isn't synced.").foregroundStyle(.secondary)
                    }
                    Text(model.connectorsChecking ? "Checking now…"
                         : model.connectorsChecked.map { "Checked at \(MeetingController.clock($0)). Mindmill checks again by itself and syncs once it works." } ?? "")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ChipRow(spacing: 6, alignment: .top) {
                    Button("Reconnect…") { model.fixConnector(problems.first?.server) }
                        .buttonStyle(.borderedProminent)
                        .help(problems.first?.server.fromClaudeAI ?? true
                              ? "Opens claude.ai → Settings → Connectors. Mindmill checks again when you come back."
                              : "Opens Claude Code's /mcp in Terminal.")
                    if calendarAffected(problems) {
                        Button("Choose Calendar…") {
                            SettingsPane.connections.select()
                            openSettings()
                        }
                        .help("Pick another calendar, or none, in Settings → Connections")
                    }
                    if model.connectorsChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Check Again") { model.checkConnectors(force: true) }
                    }
                    Button("Troubleshoot with \(Brain.name)") { model.troubleshootConnections() }
                        .help("A \(Brain.name) session checks each tool, explains what's wrong and walks you through fixing it")
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func calendarAffected(_ problems: [ClaudeConnectors.Problem]) -> Bool {
        let calendar = model.calendarSource
        return calendar.isSet && problems.contains { $0.server.name == calendar.server }
    }
}

/// Calendar sync state and a button to sync now; without a calendar, a button to choose one.
struct CalendarSyncButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let s = model.calendarSync
        if !model.calendarSource.isSet {
            Button {
                SettingsPane.connections.select()
                openSettings()
            } label: {
                Image(systemName: "calendar.badge.plus")
            }
            .help("No calendar is connected, so meetings only show when you add them. Choose one in Settings → Connections to have them appear by themselves.")
        } else {
            Button {
                model.syncCalendar()
            } label: {
                if model.calendar.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: s.error == nil ? "calendar.badge.clock" : "calendar.badge.exclamationmark")
                        .foregroundStyle(s.error == nil ? Color.primary : .orange)
                }
            }
            .disabled(model.calendar.isRunning || model.morning.isBusy)
            .help(help(s))
        }
    }

    private func help(_ s: CalendarSyncState) -> String {
        if model.calendar.isRunning { return "Syncing the calendar…" }
        var lines = ["Sync \(model.calendarSource.title) now (today through the next two weeks)."]
        if let d = s.lastSuccess { lines.append("Last synced \(MeetingController.clock(d)): \(s.summary ?? "")") }
        if let e = s.error { lines.append("Last attempt failed: \(e)") }
        return lines.joined(separator: "\n")
    }
}

/// A day's meeting from the KB: time, project, status, and what can be done with it now.
struct MeetingDayRow: View {
    @Environment(AppModel.self) private var model
    let entry: KBEntry

    var body: some View {
        let status = entry.meetingStatus ?? .filed
        let start = entry.field("start") ?? ""
        let end = entry.field("end") ?? ""
        let guessed = ["true", "yes"].contains((entry.field("project_guessed") ?? "").lowercased())
        VStack(alignment: .leading, spacing: 4) {
            ChipRow(spacing: 6) {
                Text(start.isEmpty ? "No time" : (end.isEmpty ? start : "\(start)–\(end)"))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                ProjectChip(project: entry.project).fixedSize()
                if guessed {
                    Menu("guessed") {
                        Section("Move to") {
                            ForEach(model.index.projects.filter { $0.id != entry.project }, id: \.id) { p in
                                Button(p.title) { model.moveEntry(entry.id, to: p.id) }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .font(.caption)
                    .fixedSize()
                    .foregroundStyle(.orange)
                    .help("Calendar sync guessed the scope. Move it if it belongs elsewhere; later meetings in the series follow.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                status == .cancelled ? model.openLink(entry.id.rawValue) : model.openMeeting(entry.id)
            } label: {
                Text(entry.title)
                    .font(.body.weight(.medium))
                    .strikethrough(status == .cancelled)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Open the meeting window")
            HStack(spacing: 6) {
                actions(status)
                if model.busyEntries.contains(entry.id) { ProgressView().controlSize(.small) }
                Spacer(minLength: 4)
                let chip = MeetingDayRow.chip(entry)
                Chip(text: chip.text, color: chip.color).fixedSize()
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Ask \(Brain.name) About This…") { model.askAbout(.entry(entry.id, title: entry.title)) }
            Button("Work on It with \(Brain.name)…") { model.workWithClaude(.entry(entry.id, title: entry.title)) }
            Divider()
            Button("Open Meeting Window") { model.openMeeting(entry.id) }
            Button("Show in Mindmill") { model.openLink(entry.id.rawValue) }
            Button("Not Relevant Today") { model.setMeetingNotRelevant(entry.id, true) }
            Menu("Move to Scope") {
                ForEach(model.index.projects.filter { $0.id != entry.project }, id: \.id) { p in
                    Button(p.title) { model.moveEntry(entry.id, to: p.id) }
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { model.requestDelete(entry.id) }
        }
    }

    @ViewBuilder
    private func actions(_ status: MeetingStatus) -> some View {
        HStack(spacing: 6) {
            if let url = entry.field("online_url").flatMap(URL.init(string:)), status.isUpcoming || status == .live {
                Link(destination: url) { Image(systemName: "video") }
                    .help("Join online")
            }
            switch status {
            case .scheduled, .prepared:
                Button(status == .scheduled ? "Prepare" : "Prep") { model.prepareMeeting(entry.id) }
                    .help(status == .scheduled ? "\(Brain.name) looks back at earlier meetings and drafts topics and questions" : "Open the prep and keep working on it with \(Brain.name)")
                Button("Take Notes") { model.takeNotes(entry.id) }
                    .buttonStyle(.borderedProminent)
                    .help("Write notes; the meeting companion flags conflicts in a line or two")
            case .live where entry.meetingSummarizing:
                Button("Open") { model.openMeeting(entry.id) }
                    .help("\(Brain.name) is writing the summary; the review opens when it's done")
            case .live:
                Button("Resume") { model.openMeeting(entry.id) }.buttonStyle(.borderedProminent).tint(.red)
            case .review:
                Button("Review") { model.openMeeting(entry.id) }.buttonStyle(.borderedProminent)
            case .filed:
                Button("Add Notes") { model.takeNotes(entry.id) }
            case .cancelled:
                EmptyView()
            }
        }
        .controlSize(.small)
    }

    /// Before the meeting: Prepared once the user is done preparing, else To prepare; after it, the status.
    static func chip(_ entry: KBEntry) -> (text: String, color: Color) {
        let status = entry.meetingStatus ?? .filed
        if status.isUpcoming { return entry.meetingReady ? ("Prepared", .green) : ("To prepare", .orange) }
        if entry.meetingSummarizing { return ("Summarising", .indigo) }
        return (status.rawValue.capitalized, color(status))
    }

    static func color(_ status: MeetingStatus) -> Color {
        switch status {
        case .live: return .red
        case .filed: return .gray
        case .cancelled: return .secondary
        case .scheduled: return .teal
        default: return .indigo
        }
    }
}
