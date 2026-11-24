import Foundation

/// Someone to name as an attendee or owner: from Azure DevOps (name, initials, mail) or added by name only.
public struct Person: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var name: String
    public var initials: String
    public var email: String
    public var source: String
    /// In the knowledge base's people.json: chosen or added before, so it ranks first.
    public var known = false

    public var id: String { name.lowercased() }
    public var isManual: Bool { source == "manual" }

    public init(name: String, initials: String? = nil, email: String = "", source: String = "ado") {
        self.name = name
        self.email = email
        self.source = source
        self.initials = initials.flatMap { $0.isEmpty ? nil : $0 } ?? People.initials(name: name, email: email)
    }

    enum CodingKeys: String, CodingKey { case name, initials, email, source }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        let email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        self.init(name: name, initials: try c.decodeIfPresent(String.self, forKey: .initials), email: email,
                  source: try c.decodeIfPresent(String.self, forKey: .source) ?? "ado")
    }
}

/// The knowledge base's `people.json` (people chosen before or added by name) over the Azure DevOps directory cache.
public struct People: Equatable, Sendable {
    public var all: [Person]
    public var fetched: Date?

    public init(all: [Person] = [], fetched: Date? = nil) {
        self.all = all
        self.fetched = fetched
    }

    public static var cacheURL: URL {
        if let p = ProcessInfo.processInfo.environment["KB_PEOPLE_CACHE"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("KB/people-directory.json")
    }

    public static func registryURL(root: URL) -> URL { KBLayout.home(root: root).appendingPathComponent("people.json") }

    private struct File: Decodable {
        var fetched: String?
        var people: [Person]
    }

    public static func load(root: URL, cache: URL = cacheURL) -> People {
        func read(_ u: URL) -> File? { (try? Data(contentsOf: u)).flatMap { try? JSONDecoder().decode(File.self, from: $0) } }
        let own = (read(registryURL(root: root))?.people ?? []).map { p -> Person in
            var p = p
            p.known = true
            return p
        }
        let dir = read(cache)
        var seen = Set<String>()
        var out: [Person] = []
        for p in own + (dir?.people ?? []) {
            let key = (p.email.isEmpty ? p.name : p.email).lowercased()
            guard !seen.contains(key), !seen.contains(p.name.lowercased()) else { continue }
            seen.insert(key)
            seen.insert(p.name.lowercased())
            out.append(p)
        }
        let fetched = dir?.fetched.flatMap { ISO8601DateFormatter().date(from: $0) }
        return People(all: out, fetched: fetched)
    }

    public func person(named name: String) -> Person? {
        let n = name.lowercased()
        return all.first { $0.name.lowercased() == n || $0.initials.lowercased() == n }
    }

    /// Best matches first: exact initials, name prefix, a word's prefix, initials or mail prefix, then anywhere.
    public func search(_ query: String, excluding: Set<String> = [], limit: Int = 8) -> [Person] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var scored: [(Int, Int, String, Person)] = []
        for p in all where !excluding.contains(p.name.lowercased()) {
            let name = p.name.lowercased(), ini = p.initials.lowercased(), mail = p.email.lowercased()
            let words = name.split(whereSeparator: { $0 == " " || $0 == "-" })
            let score: Int
            if ini == q { score = 0 }
            else if name.hasPrefix(q) { score = 1 }
            else if words.contains(where: { $0.hasPrefix(q) }) { score = 2 }
            else if ini.hasPrefix(q) || mail.hasPrefix(q) { score = 3 }
            else if name.contains(q) { score = 4 }
            else { continue }
            scored.append((score, p.known ? 0 : 1, name, p))
        }
        return scored.sorted { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }.prefix(limit).map(\.3)
    }

    /// Mail addresses that are initials (`abc@`) give those; otherwise the first letters of the first and last name.
    public static func initials(name: String, email: String) -> String {
        let local = email.split(separator: "@").first.map { String($0).lowercased() } ?? ""
        if (2...5).contains(local.count), local.allSatisfy({ $0.isLetter && $0.isASCII }) { return local.uppercased() }
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" }).filter { $0.first?.isLetter == true }
        guard let first = words.first?.first else { return "" }
        let last = words.count > 1 ? String(words.last!.first!) : ""
        return (String(first) + last).uppercased()
    }
}
