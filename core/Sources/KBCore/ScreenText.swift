import Foundation

/// What a new read of the watched window adds: the lines that were not on it last time, so a scrolled document
/// gives only what scrolled in and a clock or a typing indicator gives nothing.
public enum ScreenText {
    /// At most this much text goes into one transcript line.
    public static let maxLength = 1200

    public static func normalized(_ line: String) -> String {
        line.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters)
    }

    /// The lines of `current` not in `previous`, or `nil` when they add too little to mention.
    public static func added(_ current: [String], since previous: [String]) -> [String]? {
        let seen = Set(previous.map(normalized))
        var fresh: [String] = []
        var taken = Set<String>()
        for line in current {
            let key = normalized(line)
            guard key.count >= 3, !seen.contains(key), !taken.contains(key) else { continue }
            taken.insert(key)
            fresh.append(line.trimmingCharacters(in: .whitespaces))
        }
        let words = fresh.reduce(0) { $0 + $1.split(separator: " ").count }
        // A changed clock or counter alone is not worth a line.
        return words >= 4 ? fresh : nil
    }

    /// One transcript line: the screen's lines joined with ` / `, cut at `maxLength`.
    public static func line(_ lines: [String]) -> String {
        let joined = lines.map { $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: " / ")
        guard joined.count > maxLength else { return joined }
        return String(joined.prefix(maxLength)) + " …"
    }

    /// How different two small grayscale thumbnails are, 0…255 on average per pixel.
    public static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 255 }
        var sum = 0
        for i in a.indices { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(a.count)
    }
}
