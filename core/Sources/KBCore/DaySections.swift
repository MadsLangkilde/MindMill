import Foundation

/// Groups dated items into Today, Yesterday (or Tomorrow), the weekdays of the week around today, then
/// Older (or Later). Items keep their order inside a section.
public enum DaySections {
    public enum Direction: Sendable { case past, future }

    public struct Section<T>: Identifiable {
        public let title: String
        public var items: [T]
        public var id: String { title }
    }

    static let calendar = Calendar(identifier: .gregorian)

    public static func label(_ iso: String, today: String, direction: Direction) -> String {
        guard let day = KBDate.parse(iso), let now = KBDate.parse(today),
              let diff = calendar.dateComponents([.day], from: now, to: day).day else { return "No date" }
        let weekday: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = calendar
            f.dateFormat = "EEEE d MMM"
            return f.string(from: day)
        }()
        switch direction {
        case .past:
            switch diff {
            case 0: return "Today"
            case -1: return "Yesterday"
            case -6 ... -2: return weekday
            case ..<(-6): return "Older"
            default: return "Upcoming"
            }
        case .future:
            switch diff {
            case 0: return "Today"
            case 1: return "Tomorrow"
            case 2...6: return weekday
            case 7...: return "Later"
            default: return "Earlier"
            }
        }
    }

    public static func group<T>(_ items: [T], date: (T) -> String, today: String = KBDate.today(),
                                direction: Direction = .past) -> [Section<T>] {
        var out: [Section<T>] = []
        for item in items {
            let title = label(date(item), today: today, direction: direction)
            if let i = out.firstIndex(where: { $0.title == title }) {
                out[i].items.append(item)
            } else {
                out.append(Section(title: title, items: [item]))
            }
        }
        return out
    }
}

extension KBDate {
    /// The next day that is not a Saturday or Sunday.
    public static func nextWorkingDay(after iso: String) -> String {
        guard var d = parse(iso) else { return iso }
        let cal = Calendar(identifier: .gregorian)
        repeat {
            d = cal.date(byAdding: .day, value: 1, to: d) ?? d
        } while [1, 7].contains(cal.component(.weekday, from: d))
        return today(d)
    }
}

extension KBEntry {
    /// Held or over: an earlier day, or today once it is in review or filed. Undated meetings count as past.
    public func meetingIsPast(today: String = KBDate.today()) -> Bool {
        if date.isEmpty || date < today { return true }
        if date > today { return false }
        return meetingStatus == .review || meetingStatus == .filed
    }

    /// Waiting on the user: live or in review, or coming up by the next working day and not prepared yet.
    public func meetingNeedsAttention(today: String = KBDate.today()) -> Bool {
        guard section == .meetings, !isDraft, let status = meetingStatus else { return false }
        switch status {
        case .live, .review: return true
        case .scheduled, .prepared: return !meetingReady && date >= today && date <= KBDate.nextWorkingDay(after: today)
        case .filed, .cancelled: return false
        }
    }
}
