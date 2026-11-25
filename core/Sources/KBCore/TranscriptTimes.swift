import Foundation

/// When a conversation's messages were sent, shown the way chat apps do: a heading where a new day starts
/// ("Today", "Yesterday", a weekday, then a date) and a quiet time on the messages. A run of replies from the same
/// side in the same minute shows its time once.
public enum TranscriptTimes {
    public enum Side: Equatable, Sendable {
        /// The user's messages.
        case user
        /// Claude's replies and errors.
        case reply
        /// Tool steps and status lines: they never get a time of their own.
        case other
    }

    public struct Entry: Equatable, Sendable {
        public let at: Date?
        public let side: Side

        public init(at: Date?, side: Side) {
            self.at = at
            self.side = side
        }
    }

    public struct Mark: Equatable, Sendable {
        /// A heading above the entry, where a new day starts.
        public var day: String?
        /// A time under the entry.
        public var time: String?

        public init(day: String? = nil, time: String? = nil) {
            self.day = day
            self.time = time
        }
    }

    public static func marks(_ entries: [Entry], now: Date = Date(), calendar: Calendar = .current,
                             locale: Locale = .current) -> [Mark] {
        var lastDay: Date?
        var lastShown: (side: Side, minute: Date)?
        return entries.map { e in
            guard let at = e.at else { return Mark() }
            var mark = Mark()
            let day = calendar.startOfDay(for: at)
            if day != lastDay {
                mark.day = dayTitle(at, now: now, calendar: calendar, locale: locale)
                lastDay = day
                lastShown = nil
            }
            guard e.side != .other else { return mark }
            let minute = calendar.dateInterval(of: .minute, for: at)?.start ?? at
            if lastShown?.side != e.side || lastShown?.minute != minute {
                mark.time = time(at, locale: locale, calendar: calendar)
                lastShown = (e.side, minute)
            }
            return mark
        }
    }

    /// "Today", "Yesterday", the weekday within the past week, else the date (with the year when it isn't this year).
    public static func dayTitle(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let day = calendar.startOfDay(for: date), today = calendar.startOfDay(for: now)
        let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if daysAgo == 0 { return "Today" }
        if daysAgo == 1 { return "Yesterday" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let template = daysAgo > 1 && daysAgo < 7 ? "EEEE" : sameYear ? "EEEEdMMMM" : "EEEEdMMMMy"
        return formatter(template, locale: locale, calendar: calendar).string(from: date)
    }

    /// The time in the user's own clock style ("14:05" or "2:05 PM").
    public static func time(_ date: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
        formatter("jmm", locale: locale, calendar: calendar).string(from: date)
    }

    /// "14:05" for one time, "14:05–14:12" across minutes: for tool steps' tooltips.
    public static func span(_ dates: [Date], locale: Locale = .current, calendar: Calendar = .current) -> String? {
        guard let first = dates.min(), let last = dates.max() else { return nil }
        let a = time(first, locale: locale, calendar: calendar), b = time(last, locale: locale, calendar: calendar)
        return a == b ? a : "\(a)–\(b)"
    }

    private static func formatter(_ template: String, locale: Locale, calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }
}
