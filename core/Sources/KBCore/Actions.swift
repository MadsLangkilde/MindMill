import Foundation

/// How much an action changes. Destructive and external ones are confirmed before they run, unless the caller is
/// the UI, which asks in its own dialogs.
public enum ActionRisk: String, Codable, Sendable {
    /// Only reads.
    case read
    /// Changes something in Mindmill that is easy to undo.
    case write
    /// Stops work or throws something away.
    case destructive
    /// Writes to a tool outside Mindmill (Azure DevOps, Jira, GitHub).
    case external

    public var needsConfirmation: Bool { self == .destructive || self == .external }
}

/// Who asked for an action.
public enum ActionChannel: String, Codable, Sendable {
    case ui, voice, remote, model
}

public struct ActionParam: Equatable, Sendable {
    public enum Kind: String, Sendable { case string, integer, number, boolean, strings }

    public var name: String
    public var kind: Kind
    public var about: String
    public var required: Bool
    public var choices: [String]

    public init(_ name: String, _ kind: Kind = .string, _ about: String, required: Bool = false, choices: [String] = []) {
        self.name = name
        self.kind = kind
        self.about = about
        self.required = required
        self.choices = choices
    }

    public init(_ name: String, _ about: String, required: Bool = false, choices: [String] = []) {
        self.init(name, .string, about, required: required, choices: choices)
    }

    var schema: JSONValue {
        var s: [String: JSONValue] = ["description": .string(about)]
        switch kind {
        case .string: s["type"] = "string"
        case .integer: s["type"] = "integer"
        case .number: s["type"] = "number"
        case .boolean: s["type"] = "boolean"
        case .strings: s["type"] = "array"; s["items"] = ["type": "string"]
        }
        if !choices.isEmpty { s["enum"] = .array(choices.map(JSONValue.string)) }
        return .object(s)
    }

    func accepts(_ v: JSONValue) -> Bool {
        switch (kind, v) {
        case (.string, .string(let s)): return choices.isEmpty || choices.contains(s)
        case (.integer, .number(let n)): return n.rounded() == n
        case (.integer, .string(let s)): return Int(s) != nil
        case (.number, .number): return true
        case (.boolean, .bool): return true
        case (.strings, .array(let a)): return a.allSatisfy { $0.string != nil }
        case (.strings, .string): return true
        default: return false
        }
    }
}

/// One thing the voice brain, the phone or the UI can ask Mindmill to do.
public struct ActionSpec: Equatable, Sendable, Identifiable {
    public var name: String
    public var about: String
    public var params: [ActionParam]
    public var risk: ActionRisk
    /// The question asked before a destructive or external action runs; `{param}` is replaced by its value.
    public var confirm: String
    /// The group it belongs to, for an action browser: "Factories", "Meetings"…
    public var area = ""

    public var id: String { name }

    public init(_ name: String, _ about: String, risk: ActionRisk = .read, params: [ActionParam] = [], confirm: String = "") {
        self.name = name
        self.about = about
        self.params = params
        self.risk = risk
        self.confirm = confirm
    }

    /// The name as a tool name: letters, digits, `_` and `-` only.
    public var toolName: String { name.replacingOccurrences(of: ".", with: "_") }

    public var inputSchema: JSONValue {
        var props: [String: JSONValue] = [:]
        for p in params { props[p.name] = p.schema }
        return ["type": "object", "properties": .object(props),
                "required": .array(params.filter(\.required).map { .string($0.name) })]
    }

    /// Checks required and typed parameters. Returns a short, speakable problem, or nil.
    public func problem(with p: JSONValue) -> String? {
        for param in params {
            let v = p[param.name]
            if v == nil || v == .null {
                if param.required { return "\(name) needs \(param.name)." }
                continue
            }
            if let v, !param.accepts(v) {
                if !param.choices.isEmpty { return "\(param.name) must be one of \(param.choices.joined(separator: ", "))." }
                return "\(param.name) should be \(param.kind.rawValue == "strings" ? "a list of text" : "a \(param.kind.rawValue)")."
            }
        }
        return nil
    }

    public func confirmQuestion(_ p: JSONValue) -> String {
        var q = confirm.isEmpty ? "Should I \(name.replacingOccurrences(of: ".", with: " "))?" : confirm
        for param in params {
            let value: String
            switch p[param.name] {
            case .string(let s)?: value = s
            case .number(let n)?: value = n.rounded() == n ? String(Int(n)) : String(n)
            case .bool(let b)?: value = b ? "yes" : "no"
            case .array(let a)?: value = a.compactMap(\.string).joined(separator: ", ")
            default: value = ""
            }
            q = q.replacingOccurrences(of: "{\(param.name)}", with: value)
        }
        return q.replacingOccurrences(of: "  ", with: " ")
    }
}

/// What an action did: a short sentence to speak, and the data for a screen.
public struct ActionResult: Equatable, Sendable {
    public var speech: String
    public var data: JSONValue

    public init(_ speech: String, data: JSONValue = .null) {
        self.speech = speech
        self.data = data
    }

    public var json: JSONValue { ["speech": .string(speech), "data": data] }
}

public enum ActionOutcome: Equatable, Sendable {
    case done(ActionResult)
    /// Runs only once confirmed with this token.
    case confirm(token: String, question: String)
    case failed(String)

    public var json: JSONValue {
        switch self {
        case .done(let r): return ["status": "done", "speech": .string(r.speech), "data": r.data]
        case .confirm(let token, let question):
            return ["status": "needs_confirmation", "token": .string(token), "speech": .string(question)]
        case .failed(let message): return ["status": "failed", "speech": .string(message)]
        }
    }

    /// For a model: the sentence first, then the data.
    public var text: String {
        switch self {
        case .done(let r):
            guard r.data != .null, let d = try? JSONEncoder.sorted.encode(r.data) else { return r.speech }
            return r.speech + "\n\n" + String(decoding: d, as: UTF8.self)
        case .confirm(let token, let question):
            return "Not done yet. Ask the user exactly: \(question) Only when they say yes, call confirm_action with token \(token). If they say no, call cancel_action."
        case .failed(let message): return "Failed: \(message)"
        }
    }
}

private extension JSONEncoder {
    static let sorted: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}

/// The one place every action runs through, whoever asks: UI, voice, the phone or a real-time voice model.
/// Destructive and external actions asked for by anyone but the UI wait for a confirmation token.
@MainActor
public final class ActionLayer {
    public typealias Handler = @MainActor (JSONValue) async throws -> ActionResult

    struct Pending {
        let name: String
        let params: JSONValue
        let expires: Date
    }

    public let catalog: [ActionSpec]
    private var handlers: [String: Handler] = [:]
    private var pending: [String: Pending] = [:]
    /// Off: voice and the phone run destructive and external actions without asking first.
    public var confirmsRisky = true
    public static let confirmationLifetime: TimeInterval = 120
    /// Called for every action that ran, with what it did.
    public var onRun: ((String, ActionChannel, ActionResult) -> Void)?
    public var makeToken: () -> String = { String(UUID().uuidString.prefix(8)).lowercased() }
    /// What an action without a handler answers: the host doesn't have it (yet), such as a Mac-only one on Windows.
    public var unavailable: (String) -> String = { "\($0) isn't available on this Mac yet." }

    public init(catalog: [ActionSpec] = ActionCatalog.all) {
        self.catalog = catalog
    }

    public func spec(_ name: String) -> ActionSpec? {
        catalog.first { $0.name == name || $0.toolName == name }
    }

    public func register(_ name: String, _ handler: @escaping Handler) {
        precondition(spec(name) != nil, "No action \(name) in the catalog")
        handlers[name] = handler
    }

    public var unhandled: [String] { catalog.map(\.name).filter { handlers[$0] == nil } }

    public func handles(_ name: String) -> Bool { spec(name).map { handlers[$0.name] != nil } ?? false }

    public func run(_ name: String, _ params: JSONValue = [:], channel: ActionChannel, now: Date = Date()) async -> ActionOutcome {
        guard let spec = spec(name) else { return .failed("I can't do \(name).") }
        let params = params == .null ? [:] : params
        if let problem = spec.problem(with: params) { return .failed(problem) }
        if spec.risk.needsConfirmation, channel != .ui, confirmsRisky {
            prune(now)
            let token = makeToken()
            pending[token] = Pending(name: spec.name, params: params, expires: now.addingTimeInterval(Self.confirmationLifetime))
            return .confirm(token: token, question: spec.confirmQuestion(params))
        }
        return await perform(spec, params, channel: channel)
    }

    /// Runs the action a token stands for, once.
    public func confirm(_ token: String, channel: ActionChannel, now: Date = Date()) async -> ActionOutcome {
        prune(now)
        guard let p = pending.removeValue(forKey: token), let spec = spec(p.name) else {
            return .failed("That confirmation has expired. Ask again.")
        }
        return await perform(spec, p.params, channel: channel)
    }

    public func cancel(_ token: String) {
        pending.removeValue(forKey: token)
    }

    public var waitingConfirmations: Int { pending.count }

    private func prune(_ now: Date) {
        pending = pending.filter { $0.value.expires > now }
    }

    private func perform(_ spec: ActionSpec, _ params: JSONValue, channel: ActionChannel) async -> ActionOutcome {
        guard let handler = handlers[spec.name] else { return .failed(unavailable(spec.name)) }
        do {
            let result = try await handler(params)
            onRun?(spec.name, channel, result)
            return .done(result)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The catalog as tool definitions (name, description, JSON schema), the same for MCP and real-time APIs.
    public var toolDefinitions: [JSONValue] { toolDefinitions(only: nil) }

    /// Tool definitions for some actions only (nil: all).
    public func toolDefinitions(only names: Set<String>?) -> [JSONValue] {
        catalog.filter { names?.contains($0.name) ?? true }.map { s in
            var about = s.about
            if s.risk.needsConfirmation { about += " Asks the user to confirm first." }
            return ["name": .string(s.toolName), "description": .string(about), "inputSchema": s.inputSchema]
        }
    }

    /// Runs a tool call: an action by its tool name, or one of `ActionTools` (confirm, cancel, find, run).
    public func callTool(_ name: String, _ args: JSONValue, channel: ActionChannel) async -> ActionOutcome {
        switch name {
        case ActionTools.confirmName:
            return await confirm(args["token"]?.string ?? "", channel: channel)
        case ActionTools.cancelName:
            cancel(args["token"]?.string ?? "")
            return .done(ActionResult("Dropped it."))
        case ActionTools.findName:
            return .done(find(args["query"]?.string ?? "", area: args["area"]?.string))
        case ActionTools.runName:
            guard let action = args["name"]?.string else { return .failed("run_action needs name.") }
            var params = args["params"] ?? [:]
            if case .string(let text) = params { params = .parse(text) }
            return await run(action, params, channel: channel)
        default:
            return await run(name, args, channel: channel)
        }
    }

    /// Actions whose name, area or description match the words, with their parameters, for a model that has only
    /// some of them as tools.
    public func find(_ query: String, area: String?) -> ActionResult {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { w -> String in
            var w = String(w)
            for suffix in ["ies", "es", "s", "y"] where w.count > suffix.count + 3 && w.hasSuffix(suffix) {
                w.removeLast(suffix.count)
                break
            }
            return w
        }
        func score(_ s: ActionSpec) -> Int {
            words.reduce(0) { n, w in
                n + (s.name.lowercased().contains(w) ? 3 : 0) + (s.area.lowercased().contains(w) ? 2 : 0) + (s.about.lowercased().contains(w) ? 1 : 0)
            }
        }
        let inArea = catalog.filter { s in area.map { $0.isEmpty || s.area.lowercased() == $0.lowercased() } ?? true }
        let hits = words.isEmpty ? inArea : inArea.map { ($0, score($0)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.map(\.0)
        let list = hits.prefix(25).map { s -> JSONValue in
            ["name": .string(s.name), "area": .string(s.area), "about": .string(s.about), "risk": .string(s.risk.rawValue),
             "params": s.inputSchema]
        }
        return ActionResult(hits.isEmpty ? "No action matches." : "\(hits.count) actions match.", data: ["actions": .array(Array(list))])
    }

}

/// The confirmation pair every model gets with the actions, and the pair that reaches actions it has no tool for.
public enum ActionTools {
    public static let confirmName = "confirm_action"
    public static let cancelName = "cancel_action"
    public static let findName = "find_actions"
    public static let runName = "run_action"

    public static let find: JSONValue = [
        "name": .string(findName),
        "description": "Find Mindmill actions you have no tool for (anything the app can do: factories, pull requests, goals, settings…). Returns their names and parameters; run one with run_action.",
        "inputSchema": ["type": "object", "properties": [
            "query": ["type": "string", "description": "Words for what the user wants"],
            "area": ["type": "string", "description": "Only this area, e.g. Factories"],
        ]],
    ]
    public static let run: JSONValue = [
        "name": .string(runName),
        "description": "Run a Mindmill action found with find_actions, by its name, with its parameters.",
        "inputSchema": ["type": "object", "properties": [
            "name": ["type": "string", "description": "The action's name, e.g. factory.create"],
            "params": ["type": "object", "description": "Its parameters"],
        ], "required": ["name"]],
    ]

    public static let confirm: JSONValue = [
        "name": "confirm_action",
        "description": "Run an action the user just confirmed out loud, by the token it gave.",
        "inputSchema": ["type": "object", "properties": ["token": ["type": "string"]], "required": ["token"]],
    ]
    public static let cancel: JSONValue = [
        "name": "cancel_action",
        "description": "Drop an action the user declined, by its token.",
        "inputSchema": ["type": "object", "properties": ["token": ["type": "string"]], "required": ["token"]],
    ]
}

