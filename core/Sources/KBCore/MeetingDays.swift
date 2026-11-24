import Foundation

/// The day pills over the meetings list: Earlier, Yesterday, Today, Tomorrow, the next working week by day,
/// Later and All. A pill's key is an ISO date, or `earlier`, `later` or `all`.
public enum MeetingDays {
    public struct Pill: Equatable, Sendable {
        public let key: String
        public let title: String
        /// The days it covers, as ISO dates; `nil` bounds are open.
        public let from: String?
        public let to: String?

        public func contains(_ date: String) -> Bool {
            guard KBDate.isISODate(date) else { return key == "all" || key == "earlier" }
            if let from, date < from { return false }
            if let to, date > to { return false }
            return true
        }
    }

    public static let today = "today"

    static let calendar = Calendar(identifier: .gregorian)

    static func shift(_ iso: String, _ days: Int) -> String {
        guard let d = KBDate.parse(iso), let n = calendar.date(byAdding: .day, value: days, to: d) else { return iso }
        return KBDate.today(n)
    }

    static func short(_ iso: String) -> String {
        guard let d = KBDate.parse(iso) else { return iso }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.dateFormat = "EEE d"
        return f.string(from: d)
    }

    /// The pills around `today`: the days from yesterday through `ahead` days on, each its own pill.
    public static func pills(today: String, ahead: Int = 6) -> [Pill] {
        let yesterday = shift(today, -1)
        let last = shift(today, ahead)
        var out = [Pill(key: "earlier", title: "Earlier", from: nil, to: shift(yesterday, -1))]
        for n in -1...ahead {
            let day = shift(today, n)
            let title = n == -1 ? "Yesterday" : n == 0 ? "Today" : n == 1 ? "Tomorrow" : short(day)
            out.append(Pill(key: day, title: title, from: day, to: day))
        }
        out.append(Pill(key: "later", title: "Later", from: shift(last, 1), to: nil))
        out.append(Pill(key: "all", title: "All", from: nil, to: nil))
        return out
    }

    /// The pill for `key`; the stored key `today` (and a date no longer shown) means today's pill.
    public static func pill(_ key: String, today: String) -> Pill {
        let all = pills(today: today)
        return all.first { $0.key == key } ?? all.first { $0.key == today }!
    }

    /// Whether the pill lists its meetings newest first: the days before today.
    public static func newestFirst(_ pill: Pill, today: String) -> Bool {
        pill.key == "earlier" || (pill.to.map { $0 < today } ?? false)
    }
}

/// The month calendar over the meetings: whole weeks, Monday first, as ISO dates.
public enum MonthGrid {
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        return c
    }

    /// The first day of the month `iso` falls in.
    public static func month(of iso: String) -> String {
        guard let d = KBDate.parse(iso), let first = calendar.dateInterval(of: .month, for: d)?.start else { return iso }
        return KBDate.today(first)
    }

    public static func shift(month m: String, by n: Int) -> String {
        guard let d = KBDate.parse(month(of: m)), let shifted = calendar.date(byAdding: .month, value: n, to: d) else { return m }
        return KBDate.today(shifted)
    }

    /// Every day of the weeks the month touches, from the Monday before its first day to the Sunday after its last.
    public static func days(month m: String) -> [String] {
        guard let first = KBDate.parse(month(of: m)), let range = calendar.range(of: .day, in: .month, for: first) else { return [] }
        let lead = (calendar.component(.weekday, from: first) + 5) % 7
        let total = Int((Double(lead + range.count) / 7).rounded(.up)) * 7
        return (0..<total).compactMap { calendar.date(byAdding: .day, value: $0 - lead, to: first).map { KBDate.today($0) } }
    }

    /// The Monday and Sunday of the week `iso` is in.
    public static func week(of iso: String) -> (from: String, to: String) {
        guard let d = KBDate.parse(iso), let start = calendar.dateInterval(of: .weekOfYear, for: d)?.start,
              let end = calendar.date(byAdding: .day, value: 6, to: start) else { return (iso, iso) }
        return (KBDate.today(start), KBDate.today(end))
    }

    public static func weekNumber(_ iso: String) -> Int {
        KBDate.parse(iso).map { calendar.component(.weekOfYear, from: $0) } ?? 0
    }

    /// "November 2026".
    public static func title(month m: String) -> String {
        guard let d = KBDate.parse(month(of: m)) else { return m }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.dateFormat = "LLLL yyyy"
        return f.string(from: d)
    }

    public static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    public static func dayNumber(_ iso: String) -> String {
        iso.count == 10 ? String(Int(iso.suffix(2)) ?? 0) : ""
    }
}
