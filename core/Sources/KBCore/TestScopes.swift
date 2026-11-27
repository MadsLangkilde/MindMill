import Foundation

/// Which scopes the Test page offers: a single scope tests itself; a scope that spans others (the Overview, a
/// project-wide or including scope) offers the scopes in it that build something, never itself.
public enum TestScopes {
    public static func choices(for current: String?, in index: KBIndex) -> [String] {
        guard let current, let scope = index.project(current) else { return [] }
        if !scope.wide && scope.includes.isEmpty { return [current] }
        let inside = index.members(of: current).compactMap(index.project)
            .filter { !$0.wide && $0.includes.isEmpty && $0.id != current }
            .sorted { ($0.title.localizedLowercase, $0.id) < ($1.title.localizedLowercase, $1.id) }
        return inside.isEmpty ? [current] : inside.map(\.id)
    }

    /// The one to show: the chosen one while it is on offer, else the first that is set up, else the first.
    public static func pick(_ choices: [String], chosen: String?, isSetUp: (String) -> Bool) -> String? {
        if let chosen, choices.contains(chosen) { return chosen }
        return choices.first(where: isSetUp) ?? choices.first
    }
}
