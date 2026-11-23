import Foundation

/// Cuts a reply that arrives in pieces into sentences to speak, so speech starts on the first sentence while the
/// rest is still being written. Markdown is turned into plain speech on the way.
public struct SpeechChunker: Equatable, Sendable {
    private var pending = ""
    private var inCode = false
    public private(set) var count = 0

    /// A sentence shorter than this waits for the next one, so "OK." and "1." don't come out alone.
    public static let minimumLength = 12

    public init() {}

    /// Adds a piece; returns the sentences it completed.
    public mutating func add(_ piece: String) -> [String] {
        pending += piece
        var out: [String] = []
        while let end = Self.sentenceEnd(in: pending) {
            let raw = String(pending[..<end])
            let speakable = clean(raw)
            if speakable.count < Self.minimumLength, !raw.contains("\n") {
                guard let next = Self.sentenceEnd(in: pending, after: end) else { break }
                let joined = clean(String(pending[..<next]))
                pending = String(pending[next...])
                if !joined.isEmpty { out.append(joined) }
                continue
            }
            pending = String(pending[end...])
            if !speakable.isEmpty { out.append(speakable) }
        }
        count += out.count
        return out
    }

    /// What is left when the reply ends.
    public mutating func finish() -> [String] {
        defer { pending = "" }
        let rest = clean(pending)
        if rest.isEmpty { return [] }
        count += 1
        return [rest]
    }

    /// The index just past a sentence's end: `.`, `!`, `?` or `:` followed by white space, or a line break. A dot
    /// between digits ("3.5") or after a lone capital or a common abbreviation ("e.g.") doesn't end one.
    static func sentenceEnd(in text: String, after start: String.Index? = nil) -> String.Index? {
        var i = start ?? text.startIndex
        while i < text.endIndex {
            let c = text[i]
            let next = text.index(after: i)
            if c == "\n" { return next }
            if ".!?:".contains(c), next < text.endIndex, text[next] == " " || text[next] == "\n" {
                if c == ".", isAbbreviation(text, dot: i) { i = next; continue }
                return next
            }
            i = next
        }
        return nil
    }

    static let abbreviations: Set<String> = ["e.g", "i.e", "etc", "vs", "mr", "mrs", "dr", "no", "nr", "ca", "fx", "bl.a", "osv", "f.eks"]

    static func isAbbreviation(_ text: String, dot: String.Index) -> Bool {
        var start = dot
        while start > text.startIndex {
            let p = text.index(before: start)
            if text[p] == " " || text[p] == "\n" || text[p] == "(" { break }
            start = p
        }
        let word = text[start..<dot].lowercased()
        if word.count == 1, word.first?.isLetter == true { return true }
        return abbreviations.contains(word)
    }

    /// Markdown to speech: no code, no bullets or emphasis marks, links by their text, bare URLs as "a link".
    mutating func clean(_ raw: String) -> String {
        var lines: [String] = []
        for line in raw.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { inCode.toggle(); continue }
            if inCode || t.hasPrefix("|") || t.allSatisfy({ "-=*_ ".contains($0) }) && !t.isEmpty { continue }
            lines.append(t)
        }
        return Self.plain(lines.joined(separator: " "))
    }

    public static func plain(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"https?://\S+"#, with: "a link", options: .regularExpression)
        s = s.replacingOccurrences(of: #"`([^`]*)`"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^\s*(#{1,6}|[-*+•]|\d+[.)])\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\*\*|__|\*|_|~~)(?=\S)(.+?)(?<=\S)\1"#, with: "$2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }
}

/// Which voice engine a conversation uses.
public enum VoiceEngineKind: String, Codable, Sendable, CaseIterable {
    /// On-device speech recognition and speech, the brain on the Mac doing the thinking. Always works.
    case keyless
    /// A real-time voice API, with the key in the Mac's Keychain.
    case api
}

/// Picks the engine: the API only when the user chose it, a provider is active, its key is stored, and it hasn't
/// failed in this conversation; otherwise keyless, which needs no setup.
public struct VoiceEngineChoice: Equatable, Sendable {
    public var preferred: VoiceEngineKind
    public var provider: String?
    public var hasKey: Bool

    public init(preferred: VoiceEngineKind, provider: String?, hasKey: Bool) {
        self.preferred = preferred
        self.provider = provider
        self.hasKey = hasKey
    }

    public func engine(failed: Bool = false, forceKeyless: Bool = false) -> VoiceEngineKind {
        guard !forceKeyless, !failed, preferred == .api, provider?.isEmpty == false, hasKey else { return .keyless }
        return .api
    }

    /// Why a working API connection fell back, in a sentence to say.
    public static func fallbackSpeech(_ reason: VoiceFailure) -> String {
        switch reason {
        case .badKey: return "The voice API key didn't work, so I'm switching to the built-in voice."
        case .quota: return "The voice API's quota ran out, so I'm switching to the built-in voice."
        case .network: return "I lost the voice API connection, so I'm switching to the built-in voice."
        case .other: return "The voice API stopped working, so I'm switching to the built-in voice."
        }
    }
}

public enum VoiceFailure: String, Codable, Sendable {
    case badKey, quota, network, other

    /// From an HTTP status or a provider's error text.
    public static func classify(status: Int?, message: String) -> VoiceFailure {
        let m = message.lowercased()
        if status == 401 || status == 403 || m.contains("api key") || m.contains("unauthorized") || m.contains("permission") { return .badKey }
        if status == 429 || m.contains("quota") || m.contains("rate limit") || m.contains("insufficient") || m.contains("billing") { return .quota }
        if m.contains("network") || m.contains("timed out") || m.contains("offline") || m.contains("connection") { return .network }
        return .other
    }
}

public enum VoicePrompt {
    /// The voice brain: short spoken replies, the action tools for everything in Mindmill, deep work handed to
    /// Plan and Build sessions.
    public static func system(project: String?, projectTitle: String?, date: Date = Date()) -> String {
        let day = date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        return """
        You are Mindmill's voice: the user talks to you out loud and hears your replies spoken, on their Mac or phone, \
        maybe while walking or driving. Today is \(day). \(projectTitle.map { "The current project is \($0) (`\(project ?? "")`)." } ?? "")

        Speak, don't write: one to three short sentences, no Markdown, lists, tables, code, ids or links. Say numbers \
        the way people say them. Lead with the answer. When there are several items, say how many and the first one \
        or two, then offer the rest. Reply in the language the user speaks.

        You can do everything in Mindmill with the mindmill tools (mcp__mindmill__*): they are the same actions as \
        the app's buttons, and what you change shows in the app at once. Knowledge, facts, follow-ups, reminders, \
        goals, meetings (start one on the Mac with live transcription, add notes, end it), the backlog, pull \
        requests, factories (make, change, start, stop), strategies, sessions, testing, settings, and showing a \
        screen on the Mac (`app.show`). Start with `overview` when asked what needs attention. Use \
        `knowledge.search` and `entry.read` for questions about facts, decisions and meetings, and `kb` commands \
        only for what the tools don't cover.

        Some actions answer that they need confirmation. Then ask the user exactly the question they give, and call \
        confirm_action with the token only after a clear yes; on anything else call cancel_action. Never confirm \
        on your own.

        For deeper work (planning a work item, implementing, a long investigation), start a Plan or Build session \
        with session_start and a clear first message, tell the user it's started, and check on it with session_read \
        when asked. Don't do long work yourself: the user is waiting to hear you.

        If you didn't catch what the user said, ask briefly. Keep going until the user says goodbye.
        """
    }
}
