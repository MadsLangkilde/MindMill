import Foundation
import KBCore

/// The JSON shapes of docs/remote-api.md that don't need the app's state: every host builds them the same way.
public enum RemotePayloads {
    public static let summaryFields = ["status", "kind", "owner", "due", "waiting_on", "start", "end", "work_item", "raised_in",
                                       "proposed_by", "reason"]

    /// An entry in `entries.list` and `entries.search`.
    public static func entrySummary(_ e: KBEntry) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        for k in summaryFields {
            if let v = e.field(k) { fields[k] = .string(v) }
        }
        return ["id": .string(e.id.rawValue), "section": .string(e.section.rawValue), "scope": .string(e.project),
                "title": .string(e.title), "date": .string(e.date), "summary": .string(e.summary),
                "tags": .array(e.tags.map(JSONValue.string)), "fields": .object(fields)]
    }

    /// A strategy in `strategies.list` and `strategy.get`.
    public static func strategy(_ st: Strategy) -> JSONValue {
        ["slug": .string(st.slug), "title": .string(st.title), "summary": .string(st.summary), "origin": .string(st.origin.rawValue),
         "model": .string(st.model), "sessions": .number(Double(st.sessionCount)), "spawns": .bool(st.spawns)]
    }

    /// A factory in `factories.list` and the factory actions.
    public static func factory(_ f: Factory) -> JSONValue {
        let run = f.run
        let status = run == nil ? "never" : run!.isPaused ? "paused" : run!.status.rawValue
        return [
            "id": .string(f.id), "name": .string(f.name), "status": .string(status),
            "progress": run?.progress().map { .number($0) } ?? .null,
            "maxParallel": .number(Double(f.rules.maxParallel)), "questionsMode": .string(f.rules.questions.rawValue),
            "tasks": .array((run?.activeTasks ?? []).map { t in
                ["workItem": .number(Double(t.workItem)), "title": .string(t.title), "session": .string(t.sessionID),
                 "milestone": run?.lastMilestone(for: t.workItem).map { .string($0.text) } ?? .null]
            }),
            "questions": .array((run?.openQuestions ?? []).map { q in
                ["id": .string(q.id.uuidString), "text": .string(q.text), "options": .array(q.options.map(JSONValue.string)),
                 "workItem": q.workItem.map { .number(Double($0)) } ?? .null]
            }),
        ]
    }
}

extension VoiceOutput {
    /// The event a phone gets for this, per docs/remote-api.md; nil for what stays with the host.
    public func remoteEvent(conversation: String) -> (String, JSONValue)? {
        let c = JSONValue.string(conversation)
        switch self {
        case .sentence(let turn, let index, let text):
            return ("voice.sentence", ["conversation": c, "turn": .string(turn), "index": .number(Double(index)), "text": .string(text)])
        case .done(let turn, let text):
            return ("voice.done", ["conversation": c, "turn": .string(turn), "text": .string(text)])
        case .action(let name, let status, let speech, let data):
            return ("voice.action", ["conversation": c, "name": .string(name), "status": .string(status), "speech": .string(speech), "data": data])
        case .error(let message):
            return ("voice.error", ["conversation": c, "message": .string(message)])
        case .state(let s):
            return ("voice.state", ["conversation": c, "state": .string(s.rawValue)])
        case .transcript(let role, let text, let final):
            return ("voice.transcript", ["conversation": c, "role": .string(role), "text": .string(text), "final": .bool(final)])
        case .clear:
            return ("voice.clear", ["conversation": c])
        case .fallback(let reason, let speech, let message):
            return ("voice.fallback", ["conversation": c, "reason": .string(reason.rawValue), "speech": .string(speech), "message": .string(message)])
        case .userSaid:
            return nil
        }
    }
}
