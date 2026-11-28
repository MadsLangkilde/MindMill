import Foundation

/// Live voice in a work session through a real-time voice API: the voice model hears the user and speaks, hands what
/// they ask to the session (`send_to_session`), and says the session's progress and answer as they come. The session
/// does the work; the voice model only talks.
public enum SessionVoice {
    public static let send = "send_to_session"
    public static let stop = "stop_session"

    public static let tools: [JSONValue] = [
        [
            "name": .string(send),
            "description": "Give the work session what the user asks or tells it, in their words (add what they said before only when it's needed to understand it). Use it for every request about the work; the session does it and you'll be told its progress and answer.",
            "inputSchema": ["type": "object", "properties": ["message": ["type": "string", "description": "The message for the session"]], "required": ["message"]],
        ],
        [
            "name": .string(stop),
            "description": "Stop what the session is doing, when the user says stop, cancel or never mind.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
    ]

    /// `session` nil: a new session, which the first `send_to_session` starts.
    public static func instructions(session: String?, project: String?) -> String {
        let which = session.map { "the user's Mindmill work session \"\($0)\"" }
            ?? "a new Mindmill work session, which starts with the first thing you hand to it"
        return """
        You are the voice of \(which)\(project.map { " in the project \($0)" } ?? ""). \
        The user talks to you out loud while they're away from the screen. A capable assistant in that session does the \
        actual work: give it everything the user asks or tells about the work with send_to_session, and don't answer \
        such things yourself. While it works you get messages starting with [Progress]: say each in one short, plain \
        sentence. When you get [Answer], tell the user what it found or did in one to three short spoken sentences; \
        when it asks the user something, ask them that. [Done] with nothing else means it finished without saying \
        more: say so briefly. Leave out code, commands, file names and paths. Small talk, and questions about what \
        was just said, you answer yourself. When the user says stop or cancel, call stop_session. Speak the language \
        the user speaks.
        """
    }

    public static let sentResult = "Sent to the session; it's working on it. Say you're on it in a few words; you'll get its progress and answer."
    public static let stoppedResult = "The session stopped. Tell the user in a few words."
    public static let idleResult = "The session wasn't working on anything."

    /// What the voice model is told to say.
    public static func prompt(_ note: Note) -> String {
        switch note {
        case .progress(let text): return "[Progress] \(text)"
        case .answer(let text): return "[Answer] \(text)"
        case .doneQuietly: return "[Done]"
        }
    }

    public enum Note: Equatable, Sendable {
        case progress(String)
        case answer(String)
        case doneQuietly
    }
}

/// Follows one request in a session's transcript: each message the assistant finishes while the session works is
/// progress, the last one when it stops is the answer. A message counts as finished once something follows it,
/// since it may still be streaming.
public struct SessionVoiceFollower: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var role: String
        public var text: String

        public init(role: String, text: String) {
            self.role = role
            self.text = text
        }
    }

    private var next = -1
    private var sent = false
    private var saidAny = false

    public init() {}

    public var following: Bool { next >= 0 }

    /// A message is about to go; the transcript has `count` items.
    public mutating func begin(count: Int) {
        next = count
        sent = false
        saidAny = false
    }

    /// The message went: from now on a session that isn't busy has finished.
    public mutating func markSent() { sent = true }

    public mutating func reset() {
        next = -1
        sent = false
        saidAny = false
    }

    public mutating func update(items: [Item], busy: Bool) -> [SessionVoice.Note] {
        guard next >= 0 else { return [] }
        let done = sent && !busy
        let fresh = Array(items.dropFirst(next))
        let finishedCount = done ? fresh.count : max(0, fresh.count - 1)
        var notes: [SessionVoice.Note] = []
        let finished = fresh.prefix(finishedCount)
        let spoken = finished.enumerated().filter { $0.element.role == "assistant" || $0.element.role == "error" }
        for (i, item) in spoken {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let last = done && i == spoken.last?.offset
            notes.append(last ? .answer(text) : .progress(text))
            saidAny = true
        }
        next += finishedCount
        if done {
            if !saidAny { notes.append(.doneQuietly) }
            reset()
        }
        return notes
    }
}
