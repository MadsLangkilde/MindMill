import Foundation
import KBCore
import KBEngine

/// Whether a proposal waiting to be created already exists: at once from the cached tracker backlog and the KB, then
/// from `kb backlog duplicates` (a keyword search and the parent's children in the tracker), and for the uncertain
/// ones a short question to the brain, remembered per proposal and candidate.
extension AppModel {
    func duplicateFindings(for entries: [KBEntry]) -> [EntryID: DuplicateFinding] { engine.backlog.findings(for: entries) }

    /// The match that keeps a proposal from being created until the user drops it or says it isn't a duplicate.
    func unresolvedDuplicate(_ id: EntryID) -> DuplicateMatch? { engine.backlog.unresolved(id) }

    /// Searches the tracker for what the scope's proposals may duplicate: again after ten minutes, when a new
    /// proposal arrives, or when forced.
    func checkDuplicates(scope: String, force: Bool = false) { engine.backlog.check(scope: scope, force: force) }

    // MARK: Acting on a duplicate

    /// Rejects the proposal as a duplicate of `match`; with `comment`, its notes go on the existing item first.
    func dropDuplicate(_ id: EntryID, of match: DuplicateMatch, comment: Bool) {
        busyEntries.insert(id)
        let cli = cli
        Task {
            do {
                try await cli.dropBacklog(id, duplicateOf: match.key, comment: comment && match.number != nil)
                notice = comment ? "Dropped it and added its notes to \(match.label)." : "Dropped it as a duplicate of \(match.label)."
            } catch {
                errorMessage = error.localizedDescription
            }
            busyEntries.remove(id)
            reload()
        }
    }

    /// Links the existing item to the proposal's related work items, then drops the proposal.
    func linkInsteadOfDuplicate(_ id: EntryID, of match: DuplicateMatch, related: [String]) {
        guard let number = match.number else { return dropDuplicate(id, of: match, comment: false) }
        busyEntries.insert(id)
        let cli = cli
        Task {
            do {
                try await cli.linkBacklog([String(number)], parent: nil, related: related, scope: id.project)
                try await cli.dropBacklog(id, duplicateOf: match.key, comment: false)
                notice = "Linked \(match.label) to \(related.map { "#\($0)" }.joined(separator: ", ")) and dropped the proposal."
            } catch {
                errorMessage = error.localizedDescription
            }
            busyEntries.remove(id)
            reload()
        }
    }

    func markNotDuplicate(_ id: EntryID, of matches: [DuplicateMatch]) {
        runCLI([id], success: "Noted: not a duplicate.") { cli, id in try await cli.markNotDuplicate(id, of: matches.map(\.key)) }
    }
}
