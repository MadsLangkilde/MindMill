import Foundation

/// A factory's rules as plain JSON, for an editor that isn't the Mac's (the phone). The keys are `FactoryRules`'
/// own Codable keys; dates are ISO 8601.
public enum FactoryConfig {
    public struct Choice: Equatable, Sendable {
        public var id: String
        public var title: String
        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
        public var json: JSONValue { ["id": .string(id), "title": .string(title)] }
    }

    public struct ConfigError: LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func json(_ rules: FactoryRules) -> JSONValue {
        guard let data = try? encoder.encode(rules), let v = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [:] }
        return v
    }

    /// `base` with the known keys of `patch` laid over it. Unknown keys and nulls are ignored; rules and asks
    /// without an id get one.
    public static func merge(_ base: FactoryRules, with patch: JSONValue) throws -> FactoryRules {
        guard case .object(let p) = patch else { throw ConfigError(message: "rules must be an object.") }
        guard case .object(var out) = json(base) else { throw ConfigError(message: "Could not read the factory's rules.") }
        for key in FactoryRules.CodingKeys.allCases.map(\.rawValue) {
            guard let v = p[key], v != .null else { continue }
            switch key {
            case "strategyRules", "customCheckpoints": out[key] = withIDs(v)
            default: out[key] = v
            }
        }
        do {
            return try decoder.decode(FactoryRules.self, from: try JSONEncoder().encode(JSONValue.object(out)))
        } catch DecodingError.typeMismatch(_, let ctx), DecodingError.dataCorrupted(let ctx),
                DecodingError.valueNotFound(_, let ctx), DecodingError.keyNotFound(_, let ctx) {
            let at = ctx.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
            throw ConfigError(message: "rules.\(at) isn't valid.")
        }
    }

    /// The action parameters (`factory.create`, `factory.update`) as a `rules` patch for `merge`.
    public static func patch(fromAction p: JSONValue) -> JSONValue {
        let keys = ["scopes": "scopes", "assigned_to_me": "assignedToMe", "unassigned": "unassigned", "pbis": "pbis",
                    "bugs": "bugs", "sprint": "sprint", "resume_started": "resumeStarted", "new_work_items": "newWorkItems",
                    "questions": "questions", "strategy": "defaultStrategy", "checkpoints": "checkpoints",
                    "open_prs": "openPRs", "complete_prs": "completePRs", "max_parallel": "maxParallel"]
        var out: [String: JSONValue] = [:]
        for (from, to) in keys {
            guard var v = p[from], v != .null else { continue }
            if to == "scopes" || to == "checkpoints", case .string(let s) = v {
                v = .array(s.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) })
            }
            if to == "maxParallel", let n = v.int ?? v.string.flatMap(Int.init) { v = .number(Double(max(1, min(10, n)))) }
            out[to] = v
        }
        if case .number(let h)? = p["hours"] {
            out["duration"] = h <= 0 ? "untilStopped" : "hours"
            if h > 0 { out["hours"] = .number(h) }
        }
        if let until = p["until"]?.string, !until.isEmpty {
            out["duration"] = "until"
            out["until"] = .string(until)
        }
        return .object(out)
    }

    private static func withIDs(_ v: JSONValue) -> JSONValue {
        guard case .array(let items) = v else { return v }
        return .array(items.map { item in
            guard case .object(var o) = item else { return item }
            if o["id"]?.string.flatMap(UUID.init(uuidString:)) == nil { o["id"] = .string(UUID().uuidString) }
            return .object(o)
        })
    }

    /// Every choice the editor offers. `scopes` are those with a tracker; `strategies` as slug and title.
    public static func options(scopes: [Choice], strategies: [(slug: String, title: String)]) -> JSONValue {
        func choices<E: RawRepresentable & CaseIterable>(_ type: E.Type, _ title: (E) -> String) -> JSONValue where E.RawValue == String {
            .array(E.allCases.map { Choice(id: $0.rawValue, title: title($0)).json })
        }
        let checkpoints = FactoryCheckpoint.allCases.filter { $0 != .newWorkItems }.map { cp -> JSONValue in
            let requires: JSONValue = switch cp {
            case .beforePR: ["openPRs"]
            case .beforeComplete: ["openPRs", "completePRs"]
            default: []
            }
            return ["id": .string(cp.rawValue), "title": .string(cp.title), "detail": .string(cp.detail), "requires": requires]
        }
        return [
            "scopes": .array(scopes.map(\.json)),
            "strategies": .array([["slug": "", "title": "No strategy (one session)"]]
                                 + strategies.map { ["slug": .string($0.slug), "title": .string($0.title)] }),
            "checkpoints": .array(checkpoints),
            "unsureAsk": ["id": .string(FactoryRules.unsureID), "title": "When it's unsure about something that matters",
                          "instruction": .string(FactoryRules.unsureInstruction)],
            "sprint": choices(FactoryRules.SprintFilter.self, \.title),
            "questions": choices(FactoryRules.Questions.self, \.title),
            "newWorkItems": choices(FactoryRules.NewWorkItems.self, \.title),
            "duration": choices(FactoryRules.Duration.self, \.title),
            "strategyMatch": .array(FactoryStrategyRule.Match.allCases.map {
                ["id": .string($0.rawValue), "title": .string($0.title), "needsValue": .bool($0.needsValue)]
            }),
            "maxParallel": .array(FactoryRules.parallelChoices.map { .number(Double($0)) }),
        ]
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            if let n = try? c.decode(Double.self) { return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }
            let s = try c.decode(String.self)
            let f = ISO8601DateFormatter()
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not an ISO 8601 date: \(s)")
        }
        return d
    }()
}
