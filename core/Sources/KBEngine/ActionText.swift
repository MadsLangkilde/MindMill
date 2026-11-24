import Foundation
import KBCore

/// A failure an action reports to whoever ran it (a button, voice, a phone), in the user's words.
public struct ActionError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Parameter parsing and phrasing the action handlers share.
public enum ActionText {
    /// A number from a JSON number or a string like `#123`.
    public static func intParam(_ v: JSONValue?) -> Int? {
        switch v {
        case .number(let n)?: return Int(n)
        case .string(let s)?: return Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
        default: return nil
        }
    }

    /// `today`, `tomorrow`, `yesterday` or a `yyyy-MM-dd` date, as `yyyy-MM-dd`.
    public static func day(_ raw: String?, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        switch raw?.lowercased() {
        case "tomorrow"?: return f.string(from: Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now)
        case "yesterday"?: return f.string(from: Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now)
        case let s? where s.count == 10 && s.first?.isNumber == true: return s
        default: return f.string(from: now)
        }
    }

    /// A `yyyy-MM-dd` day as "24 Nov" (in the user's language), for speech.
    public static func shortDate(_ iso: String) -> String {
        guard let date = KBDate.parse(iso) else { return iso }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f.string(from: date)
    }

    /// A `yyyy-MM-dd` day as "24 Nov 2026".
    public static func displayDate(_ iso: String) -> String {
        guard let date = KBDate.parse(iso) else { return iso }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("dMMMyyyy")
        return f.string(from: date)
    }

    /// A time of day as `HH:mm`.
    public static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    public static func count(_ n: Int, _ word: String, plural: String? = nil) -> String {
        "\(n) " + (n == 1 ? word : plural ?? word + "s")
    }

    public static func list(_ parts: [String], or: Bool = false) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + (or ? " or " : " and ") + parts.last!
        }
    }
}
