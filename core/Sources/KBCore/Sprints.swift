import Foundation

/// A sprint as every tracker gives it: Azure DevOps iterations (`path` is the iteration path), Mindmill's own tracker
/// (`path` is the name), and whatever a tracker added later reports.
public struct SprintInfo: Codable, Equatable, Sendable, Hashable {
    public var name: String
    public var path: String
    public var start: String
    public var finish: String

    public init(name: String, path: String? = nil, start: String = "", finish: String = "") {
        self.name = name
        self.path = path ?? name
        self.start = start
        self.finish = finish
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? name
        start = try c.decodeIfPresent(String.self, forKey: .start) ?? ""
        finish = try c.decodeIfPresent(String.self, forKey: .finish) ?? ""
    }
}

/// One tracker's sprints around today, from `kb sprint status --json`. Scopes that share an Azure DevOps project and
/// iteration root share one entry; every other tracker has one per scope.
public struct TrackerSprints: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        /// A sprint runs today.
        case running
        /// One sprint ended and the next is planned but hasn't started.
        case between
        /// The last sprint ended and nothing comes after it.
        case ended
        /// Only future sprints.
        case upcoming
        /// No sprints at all.
        case none
        /// The scope's own tracker has sprints turned off.
        case off
        /// Not readable by the CLI: a tracker reached through Claude, or one that failed.
        case unknown
    }

    public var key: String
    public var kind: String
    public var scopes: [String]
    public var reachable: Bool
    public var state: State
    public var current: SprintInfo?
    public var previous: SprintInfo?
    public var next: SprintInfo?
    public var daysSinceEnd: Int?
    /// Mindmill can add the next sprint itself (its own tracker).
    public var canCreate: Bool
    /// Where to add the next sprint by hand, when Mindmill can't.
    public var createURL: String
    public var note: String

    public var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, kind, scopes, reachable, state, current, previous, next, note
        case daysSinceEnd = "days_since_end", canCreate = "can_create", createURL = "create_url"
    }

    public init(key: String, kind: String, scopes: [String], reachable: Bool = true, state: State, current: SprintInfo? = nil,
                previous: SprintInfo? = nil, next: SprintInfo? = nil, daysSinceEnd: Int? = nil, canCreate: Bool = false,
                createURL: String = "", note: String = "") {
        self.key = key
        self.kind = kind
        self.scopes = scopes
        self.reachable = reachable
        self.state = state
        self.current = current
        self.previous = previous
        self.next = next
        self.daysSinceEnd = daysSinceEnd
        self.canCreate = canCreate
        self.createURL = createURL
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        scopes = try c.decodeIfPresent([String].self, forKey: .scopes) ?? []
        reachable = try c.decodeIfPresent(Bool.self, forKey: .reachable) ?? true
        state = (try? c.decode(State.self, forKey: .state)) ?? .unknown
        current = try c.decodeIfPresent(SprintInfo.self, forKey: .current)
        previous = try c.decodeIfPresent(SprintInfo.self, forKey: .previous)
        next = try c.decodeIfPresent(SprintInfo.self, forKey: .next)
        daysSinceEnd = try c.decodeIfPresent(Int.self, forKey: .daysSinceEnd)
        canCreate = try c.decodeIfPresent(Bool.self, forKey: .canCreate) ?? false
        createURL = try c.decodeIfPresent(String.self, forKey: .createURL) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    /// The tracker's name for the user.
    public var trackerName: String { Self.trackerName(kind) }

    public static func trackerName(_ kind: String) -> String {
        switch kind {
        case "azure-devops": return "Azure DevOps"
        case "local": return "Mindmill's tracker"
        case "jira": return "Jira"
        case "github": return "GitHub"
        default: return kind.prefix(1).uppercased() + kind.dropFirst()
        }
    }

    /// Only Claude can read it (Jira, GitHub, Linear and the like), so Mindmill can't notice its sprints by itself.
    public var throughClaude: Bool { !["azure-devops", "local"].contains(kind) }
}

/// `kb sprint status --json`.
public struct SprintReport: Codable, Equatable, Sendable {
    public var today: String
    public var trackers: [TrackerSprints]

    public init(today: String = "", trackers: [TrackerSprints] = []) {
        self.today = today
        self.trackers = trackers
    }

    public static func decode(_ json: String) throws -> SprintReport {
        try JSONDecoder().decode(SprintReport.self, from: Data(json.utf8))
    }

    public func tracker(scope: String) -> TrackerSprints? { trackers.first { $0.scopes.contains(scope) } }
}

/// What Mindmill remembers of each tracker's sprints between launches, in Application Support (never in the KB): the
/// last current sprint it saw, and the review of a finished sprint waiting for the user.
public struct SprintWatch: Codable, Equatable, Sendable {
    public struct Pending: Codable, Equatable, Sendable {
        /// The sprint whose leftovers are to be reviewed.
        public var sprint: SprintInfo
        /// The sprint that took over, if any.
        public var target: SprintInfo?
        /// The day the change was noticed.
        public var noticed: String

        public init(sprint: SprintInfo, target: SprintInfo?, noticed: String) {
            self.sprint = sprint
            self.target = target
            self.noticed = noticed
        }
    }

    public struct Memory: Codable, Equatable, Sendable {
        /// The current sprint's path when last read; nil when no sprint ran.
        public var current: String?
        public var seen = false
        public var pending: Pending?
        /// "Not now": hidden until this day.
        public var snoozedUntil: String?
        /// Sprints whose review the user finished, newest last.
        public var reviewed: [String] = []

        public init() {}
    }

    /// A sprint that just started counts as new on first sight for this many days, so the first launch after the
    /// change still offers the review.
    public static let freshDays = 2

    public var trackers: [String: Memory] = [:]

    public init() {}

    /// Takes a fresh reading of a tracker. Returns the pending review when this reading is what made it pending.
    @discardableResult
    public mutating func observe(_ t: TrackerSprints, today: String) -> Pending? {
        guard t.reachable, t.state != .unknown, t.state != .off else { return nil }
        var m = trackers[t.key] ?? Memory()
        defer { trackers[t.key] = m }
        let now = t.current?.path
        let firstSight = !m.seen
        m.seen = true
        let changed = !firstSight && now != m.current
        m.current = now
        let started = t.current.map { firstSight ? (Self.days(from: $0.start, to: today).map { $0 <= Self.freshDays } ?? false) : changed } ?? false
        let ended = t.state == .ended && t.previous != nil && (changed || firstSight)
        guard started || ended, let previous = t.previous, !m.reviewed.contains(previous.path),
              m.pending?.sprint.path != previous.path else {
            if let p = m.pending, let target = t.current ?? t.next, p.target == nil { m.pending?.target = target }
            return nil
        }
        m.pending = Pending(sprint: previous, target: t.current, noticed: today)
        m.snoozedUntil = nil
        return m.pending
    }

    /// The review to offer today, if any: pending, not reviewed, not put off.
    public func pending(_ key: String, today: String) -> Pending? {
        guard let m = trackers[key], let p = m.pending, !m.reviewed.contains(p.sprint.path) else { return nil }
        if let until = m.snoozedUntil, today < until { return nil }
        return p
    }

    /// "Not now": comes back tomorrow.
    public mutating func snooze(_ key: String, today: String) {
        trackers[key, default: Memory()].snoozedUntil = Self.adding(1, to: today)
    }

    /// "Done reviewing": that sprint's review never comes back.
    public mutating func finish(_ key: String, sprint: String) {
        var m = trackers[key] ?? Memory()
        if !m.reviewed.contains(sprint) { m.reviewed = Array((m.reviewed + [sprint]).suffix(20)) }
        if m.pending?.sprint.path == sprint { m.pending = nil }
        m.snoozedUntil = nil
        trackers[key] = m
    }

    /// Offers a review on demand ("Review Last Sprint"), even one done before.
    public mutating func request(_ key: String, sprint: SprintInfo, target: SprintInfo?, today: String) {
        var m = trackers[key] ?? Memory()
        m.reviewed.removeAll { $0 == sprint.path }
        m.pending = Pending(sprint: sprint, target: target, noticed: today)
        m.snoozedUntil = nil
        trackers[key] = m
    }

    // MARK: File

    public static func url(base: URL? = nil) -> URL {
        (base.map { $0.appendingPathComponent("KB") } ?? AppPaths.instanceData).appendingPathComponent("sprints.json")
    }

    public static func load(from url: URL) -> SprintWatch {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(SprintWatch.self, from: $0) } ?? SprintWatch()
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: url, options: .atomic)
    }

    // MARK: Days

    static func calendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    static func date(_ day: String) -> Date? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar().date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    public static func days(from a: String, to b: String) -> Int? {
        guard let x = date(a), let y = date(b) else { return nil }
        return calendar().dateComponents([.day], from: x, to: y).day
    }

    public static func adding(_ n: Int, to day: String) -> String {
        guard let d = date(day), let e = calendar().date(byAdding: .day, value: n, to: d) else { return day }
        let c = calendar().dateComponents([.year, .month, .day], from: e)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// What the app tells the user about a tracker's sprints today: a review to do, a sprint that ended with nothing
/// after it, or both.
public struct SprintMoment: Equatable, Sendable, Identifiable {
    public var tracker: TrackerSprints
    public var review: SprintWatch.Pending?

    public var id: String { tracker.key }

    public init(tracker: TrackerSprints, review: SprintWatch.Pending?) {
        self.tracker = tracker
        self.review = review
    }

    /// Ended with no next sprint: the tracker needs a new one.
    public var needsNextSprint: Bool { tracker.state == .ended }

    public var headline: String {
        if needsNextSprint, let p = tracker.previous {
            return "\(p.name) ended \(Self.ago(tracker.daysSinceEnd)); no next sprint in \(tracker.trackerName) yet"
        }
        if let r = review {
            return r.target.map { "\($0.name) has started" } ?? "\(r.sprint.name) has ended"
        }
        return ""
    }

    public var detail: String {
        guard let r = review else {
            return tracker.canCreate ? "Add the next sprint here." : "Add the next sprint in \(tracker.trackerName)."
        }
        return "Decide what happens to what \(r.sprint.name) left unfinished: done, moved on, back to the backlog or removed."
    }

    static func ago(_ days: Int?) -> String {
        switch days ?? 0 {
        case ...0: return "today"
        case 1: return "yesterday"
        case let n: return "\(n) days ago"
        }
    }

    /// The moments to show for these trackers today, in their order.
    public static func list(_ report: SprintReport, watch: SprintWatch, today: String) -> [SprintMoment] {
        report.trackers.compactMap { t in
            let review = watch.pending(t.key, today: today)
            let snoozed = watch.trackers[t.key]?.snoozedUntil.map { today < $0 } ?? false
            let reviewedEnd = t.previous.map { watch.trackers[t.key]?.reviewed.contains($0.path) ?? false } ?? false
            if review != nil || (t.state == .ended && !snoozed && !reviewedEnd) { return SprintMoment(tracker: t, review: review) }
            return nil
        }
    }
}
