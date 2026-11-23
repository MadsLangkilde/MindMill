import Foundation
import KBCore

/// Meetings run from the phone: it hears the room and shows its screen; the Mac keeps the notes and writes the
/// summary, the same as a meeting started on the Mac.
extension AppModel {
    func remoteMeeting(_ method: String, _ p: JSONValue) async throws -> JSONValue? {
        switch method {
        case "meeting.start":
            guard let scope = p["scope"]?.string ?? meetingScope ?? projectID else { throw RemoteError.badParams("scope") }
            let now = Date()
            let title = (p["title"]?.string).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                ?? "Meeting \(MeetingController.clock(now))"
            let doc = try MeetingFile.create(project: scope, title: title, date: KBDate.today(now), start: MeetingController.clock(now),
                                             attendees: p["attendees"]?.strings ?? [], root: rootURL)
            reload()
            let c = meetingController(for: doc.id)
            c.load()
            c.startMeeting()
            broadcastMeeting(c)
            return ["meeting": .string(doc.id.rawValue)]

        case "meeting.line":
            let c = try liveMeeting(p)
            c.addRemoteLine(speaker: p["speaker"]?.string ?? "Room", text: p["text"]?.string ?? "", language: p["language"]?.string ?? "")
            return ["added": true]

        case "meeting.note":
            let c = try liveMeeting(p)
            c.appendRemoteNote(p["text"]?.string ?? "")
            return ["added": true]

        case "meeting.stop":
            let c = try liveMeeting(p)
            c.finishMeeting()
            broadcastMeeting(c)
            return ["stopped": true]

        case "meeting.get":
            guard let raw = p["meeting"]?.string, let id = EntryID(raw) else { throw RemoteError.badParams("meeting") }
            let doc = try KBStore.load(id, root: rootURL)
            let c = meetingControllers[id]
            let transcript = c?.transcript.map { l -> JSONValue in ["time": .string(l.time), "speaker": .string(l.speaker), "text": .string(l.text)] } ?? []
            let state = c?.remoteState ?? (MeetingFile.status(of: doc) == .live ? "live" : "done")
            return [
                "meeting": .string(raw), "title": .string(doc.frontmatter.string("title") ?? raw),
                "notes": .string(c?.notes ?? doc.meetingSection(.rawNotes) ?? ""),
                "transcript": .array(transcript),
                "summary": doc.meetingSection(.summary).map(JSONValue.string) ?? .null,
                "state": .string(state),
            ]

        default:
            return nil
        }
    }

    private func liveMeeting(_ p: JSONValue) throws -> MeetingController {
        guard let raw = p["meeting"]?.string, let id = EntryID(raw) else { throw RemoteError.badParams("meeting") }
        let c = meetingController(for: id)
        if c.stage != .live, c.title.isEmpty { c.load() }
        guard c.stage == .live || c.stage == .prepare else { throw RemoteError(code: "failed", message: "That meeting has ended.") }
        if c.stage == .prepare { c.startMeeting() }
        return c
    }

    func broadcastMeeting(_ c: MeetingController) {
        guard remote.isRunning else { return }
        remote.broadcast("meeting.changed", ["meeting": .string(c.id.rawValue), "state": .string(c.remoteState)])
    }
}
