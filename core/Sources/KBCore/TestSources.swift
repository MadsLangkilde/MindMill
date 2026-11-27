import Foundation

/// Which copy of the code a test builds: the project's own folder on this Mac, or the separate copy a session works
/// in (a git worktree; the app calls it the session's version). A session's copy is the folder it reported
/// (`kb crew folder`), else the copy its conversation names last.
public enum TestSources {
    public struct Checkout: Equatable, Sendable {
        public var path: String
        public var branch: String?

        public init(path: String, branch: String? = nil) {
            self.path = path
            self.branch = branch
        }
    }

    /// `git worktree list --porcelain`: the main folder first, then each separate copy.
    public static func checkouts(porcelain: String) -> [Checkout] {
        var out: [Checkout] = []
        for block in porcelain.components(separatedBy: "\n\n") {
            var c: Checkout?
            for line in block.components(separatedBy: "\n") {
                if line.hasPrefix("worktree ") { c = Checkout(path: String(line.dropFirst(9))) }
                if line.hasPrefix("branch "), c != nil {
                    c?.branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "")
                }
            }
            if let c { out.append(c) }
        }
        return out
    }

    /// The copy of `checkouts` (main folder first) a session works in, or nil when it works in the main folder.
    /// `reported` are folders the session named with `kb crew folder`; `texts` its conversation, oldest first.
    public static func sessionCopy(_ checkouts: [Checkout], reported: [String], texts: [String]) -> Checkout? {
        let copies = Array(checkouts.dropFirst())
        guard !copies.isEmpty else { return nil }
        func norm(_ p: String) -> String { URL(fileURLWithPath: p).standardizedFileURL.path }
        for r in reported.reversed() {
            let p = norm(r)
            if let c = copies.first(where: { p == norm($0.path) || p.hasPrefix(norm($0.path) + "/") }) { return c }
        }
        let main = checkouts.first.map { URL(fileURLWithPath: $0.path).lastPathComponent }
        for text in texts.reversed() {
            if let c = copies.first(where: { text.contains($0.path) }) { return c }
            if let c = copies.first(where: { c in
                let name = URL(fileURLWithPath: c.path).lastPathComponent
                return name != main && name.count >= 6 && text.contains("worktree") && text.contains(name)
            }) { return c }
        }
        return nil
    }
}
