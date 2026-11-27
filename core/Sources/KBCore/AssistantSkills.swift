import Foundation

/// Mindmill's built-in skills in the assistants that use them. Claude Code gets them through Mindmill's plugin
/// (`mindmill:<skill>`); Codex and Gemini CLI read plain skill folders from `~/.agents/skills`, so Mindmill copies each
/// skill there as `mindmill-<skill>`, adapted to that assistant, and takes its copies away when no assistant in use
/// needs them. Only folders Mindmill placed (they hold `marker`) are ever changed or removed.
public enum AssistantSkills {
    public static let marker = ".mindmill-skill"
    public static let prefix = "mindmill-"
    /// Skills that only make sense in Claude Code.
    public static let claudeOnly: Set<String> = ["migrate-memory"]

    /// The folder an assistant reads skills from; nil when Mindmill's plugin carries them.
    public static func folder(for provider: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        switch provider {
        case AIProvider.codex.id, AIProvider.gemini.id:
            return home.appendingPathComponent(".agents/skills", isDirectory: true)
        default:
            return nil
        }
    }

    /// How the assistant's user calls a skill by name, for the "where it is" line in Settings.
    public static func invocation(_ skill: String, provider: String) -> String {
        switch provider {
        case AIProvider.codex.id: return "$\(prefix)\(skill)"
        case AIProvider.gemini.id: return "\(prefix)\(skill)"
        default: return "/mindmill:\(skill)"
        }
    }

    /// The assistants whose folders get the skills: the brain, those tasks run on, and those the user asked for.
    /// The first of them decides the wording when two share a folder.
    public static func providers(_ setup: AISetup) -> [String] {
        var out: [String] = []
        for p in [setup.brainProvider.id] + AITask.allCases.map({ setup.provider(for: $0).id }) + (setup.skillsIn ?? [])
        where !out.contains(p) { out.append(p) }
        return out
    }

    /// A skill's SKILL.md as another assistant reads it: named `mindmill-<skill>`, without Claude Code's tool list,
    /// with other skills named the way that assistant calls them, and a line on finding `kb` and the user's tools.
    public static func adapt(_ text: String, skill: String, provider: String, kbCommand: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var body = 0
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            var front = Array(lines[1..<end])
            front.removeAll { $0.hasPrefix("allowed-tools:") }
            front = front.map { $0.hasPrefix("name:") ? "name: \(prefix)\(skill)" : $0 }
            lines = ["---"] + front + ["---"] + lines[(end + 1)...]
            body = front.count + 2
        }
        let note = "> Mindmill's command line is `kb` (when it isn't found, run `\(kbCommand)`). `kb tools` says which mail, chat, calendar, documents and work tracker the user works with: use those."
        lines.insert(contentsOf: ["", note], at: body)
        var out = lines.joined(separator: "\n")
        let call = provider == AIProvider.codex.id ? "\\$" + prefix : prefix
        out = out.replacingOccurrences(of: #"/mindmill:([a-z][a-z-]*)"#, with: call + "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"mindmill:([a-z][a-z-]*)"#, with: prefix + "$1", options: .regularExpression)
        return out
    }

    public struct Change: Equatable, Sendable {
        public var written: [String] = []
        public var removed: [String] = []
        public var isEmpty: Bool { written.isEmpty && removed.isEmpty }
    }

    /// The skill folders in Mindmill's plugin.
    public static func sources(_ skills: URL, fm: FileManager = .default) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: skills.path)) ?? [])
            .filter { !$0.hasPrefix(".") && !claudeOnly.contains($0)
                && fm.fileExists(atPath: skills.appendingPathComponent($0).appendingPathComponent("SKILL.md").path) }
            .sorted()
    }

    /// The `mindmill-` folders Mindmill placed in `folder`.
    public static func placed(in folder: URL, fm: FileManager = .default) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix(prefix) && fm.fileExists(atPath: folder.appendingPathComponent($0).appendingPathComponent(marker).path) }
            .sorted()
    }

    /// Brings `folder` in line with the plugin's skills: writes what changed and removes Mindmill's copies of skills
    /// that are gone. A `mindmill-` folder the user made (without `marker`) is left alone.
    @discardableResult
    public static func place(from skills: URL, into folder: URL, provider: String, kbCommand: String,
                             fm: FileManager = .default) throws -> Change {
        var change = Change()
        let names = sources(skills, fm: fm)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names {
            let dest = folder.appendingPathComponent(prefix + name, isDirectory: true)
            if fm.fileExists(atPath: dest.path), !fm.fileExists(atPath: dest.appendingPathComponent(marker).path) { continue }
            let src = skills.appendingPathComponent(name, isDirectory: true)
            var wanted: [String: Data] = [marker: Data("Placed by Mindmill for \(provider); it is replaced when Mindmill's skills change.\n".utf8)]
            for rel in files(in: src, fm: fm) {
                guard let data = fm.contents(atPath: src.appendingPathComponent(rel).path) else { continue }
                if rel == "SKILL.md", let text = String(data: data, encoding: .utf8) {
                    wanted[rel] = Data(adapt(text, skill: name, provider: provider, kbCommand: kbCommand).utf8)
                } else {
                    wanted[rel] = data
                }
            }
            let existing = Set(files(in: dest, fm: fm))
            var touched = false
            for (rel, data) in wanted where fm.contents(atPath: dest.appendingPathComponent(rel).path) != data {
                let url = dest.appendingPathComponent(rel)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                touched = true
            }
            for rel in existing.subtracting(wanted.keys) {
                try fm.removeItem(at: dest.appendingPathComponent(rel))
                touched = true
            }
            if touched { change.written.append(name) }
        }
        for dir in placed(in: folder, fm: fm) where !names.contains(String(dir.dropFirst(prefix.count))) {
            try fm.removeItem(at: folder.appendingPathComponent(dir))
            change.removed.append(String(dir.dropFirst(prefix.count)))
        }
        return change
    }

    /// Takes away every skill Mindmill placed in `folder`.
    @discardableResult
    public static func remove(from folder: URL, fm: FileManager = .default) throws -> [String] {
        let dirs = placed(in: folder, fm: fm)
        for dir in dirs { try fm.removeItem(at: folder.appendingPathComponent(dir)) }
        return dirs.map { String($0.dropFirst(prefix.count)) }
    }

    /// Brings every assistant's folder in line with `setup`: the skills where an assistant in use reads them, and
    /// none of Mindmill's copies where none does.
    @discardableResult
    public static func sync(_ setup: AISetup, skills: URL, kbCommand: String,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            fm: FileManager = .default) throws -> Change {
        var wordingFor: [URL: String] = [:]
        for p in providers(setup) {
            if let f = folder(for: p, home: home), wordingFor[f] == nil { wordingFor[f] = p }
        }
        var change = Change()
        for (f, p) in wordingFor {
            let c = try place(from: skills, into: f, provider: p, kbCommand: kbCommand, fm: fm)
            change.written += c.written
            change.removed += c.removed
        }
        let all = Set(AIProvider.all.compactMap { folder(for: $0.id, home: home) })
        for f in all where wordingFor[f] == nil {
            change.removed += try remove(from: f, fm: fm)
        }
        return change
    }

    private static func files(in dir: URL, fm: FileManager) -> [String] {
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let base = dir.standardizedFileURL.path
        return e.compactMap { item -> String? in
            guard let url = item as? URL, (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { return nil }
            return String(path.dropFirst(base.count + 1))
        }
    }
}
