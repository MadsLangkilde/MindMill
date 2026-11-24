import Foundation
import KBCore
import KBEngine

/// Handlers for the work side that need the app: the tracker and pull requests (with its busy marks and caches),
/// sprints, testing and projects. Sessions, strategies and factories are the engine's.
/// Each calls the function its button calls.
extension AppModel {
    func registerWorkActions() {
        let a = actions

        // MARK: Backlog

        a.register("workitem.search") { [unowned self] p in
            let q = (p["query"]?.string ?? "").trimmingCharacters(in: .whitespaces)
            let found = try TrackerBacklog.decode(try await cli.run(["tracker", "backlog", "--search", q, "--json"])).items
            guard let first = found.first else { return ActionResult("No work items match \(q).") }
            return ActionResult("\(Self.count(found.count, "work item")). The first is \(first.id), \(first.title), \(first.state).",
                                data: ["items": .from(found)])
        }

        a.register("workitem.tasks") { [unowned self] p in
            let ids = (p["ids"]?.strings ?? p["ids"]?.string.map { [$0] } ?? []).compactMap { Self.intParam(.string($0)) }
            guard !ids.isEmpty, let state = p["state"]?.string else { throw ActionError("Which tasks?") }
            setTasks(ids, state: state)
            return ActionResult("Setting \(Self.count(ids.count, "task")) to \(state).")
        }

        a.register("workitem.implement") { [unowned self] p in
            let scope = try scopeParam(p)
            guard let id = Self.intParam(p["id"]) else { throw ActionError("Which work item?") }
            guard let item = implementable(id, scope: scope) ?? trackerItems(scope: scope).first(where: { $0.id == id })?.asMyWork
            else { throw ActionError("I can't find work item \(id) in \(scope)'s backlog.") }
            let strategy = try p["strategy"]?.string.map { try strategyParam($0) }
            let mode: ImplementMode = p["mode"]?.string == "fast" ? .fast : .guided
            beginImplement(item, mode: mode, strategy: strategy, show: false)
            return ActionResult("Started \(id) in a Build session.")
        }

        a.register("workitem.tags.align") { [unowned self] p in
            let scope = try scopeParam(p)
            guard let id = Self.intParam(p["id"]), let item = trackerItems(scope: scope).first(where: { $0.id == id }) ?? workItem(id)
            else { throw ActionError("I can't find that work item.") }
            guard canAlignTags(item) else { throw ActionError("This tracker doesn't take Mindmill's tags.") }
            alignTags(item)
            return ActionResult("Writing its tags to the tracker.")
        }

        a.register("backlog.propose") { [unowned self] p in
            let scope = try scopeParam(p)
            let title = p["title"]?.string ?? ""
            let details = p["details"]?.string ?? ""
            let bug = p["bug"]?.bool ?? false
            if let raw = p["source"]?.string, let source = EntryID(raw) {
                addProposedPBI(source: source, title: title, details: details, bug: bug, scope: scope)
            } else {
                try await engine.backlog.propose(title: title, details: details, bug: bug, scope: scope, source: nil)
            }
            return ActionResult("Proposed it in the backlog. Create it in the tracker when you're ready.")
        }

        a.register("backlog.create") { [unowned self] p in
            let id = try entryParam(p)
            guard index.entry(id)?.backlogStatus == .proposed else { throw ActionError("That isn't a proposal waiting to be created.") }
            if let related = p["related"] {
                let values = WorkItemLinks.relatedValues(related.strings.isEmpty ? (related.string.map { [$0] } ?? []) : related.strings)
                var doc = try KBStore.load(id, root: rootURL)
                doc.frontmatter.set("related", values.isEmpty ? nil : .list(values))
                if doc.isDirty { _ = try KBStore.save(&doc, root: rootURL) }
            }
            if let dup = unresolvedDuplicate(id) {
                guard p["not_duplicate"]?.bool == true else {
                    throw ActionError("It may duplicate \(dup.label) “\(dup.title)” (\(dup.state)). Check it: drop the proposal, or create it with not_duplicate.")
                }
                try await cli.markNotDuplicate(id, of: duplicateFindings(for: index.entry(id).map { [$0] } ?? [])[id]?.matches.map(\.key) ?? [dup.key])
            }
            let parent = p["parent"]?.string ?? Self.intParam(p["parent"]).map(String.init)
            createBacklog(id, sprint: p["sprint"]?.string.flatMap(Sprint.init(rawValue:)) ?? .none,
                          parent: parent.map { $0.lowercased() == "none" ? "" : $0.filter(\.isNumber) })
            return ActionResult("Creating it in the tracker.")
        }

        a.register("backlog.reject") { [unowned self] p in
            rejectBacklog(try entryParam(p))
            return ActionResult("Rejected it.")
        }

        // MARK: Pull requests

        a.register("prs.list") { [unowned self] _ in
            let list = try PullRequestList.decode(try await cli.run(["pr", "list", "--json"]))
            refreshPullRequests(force: true)
            guard !list.prs.isEmpty else { return ActionResult("You have no open pull requests.") }
            let ready = list.prs.filter(\.canComplete).count
            let comments = list.needingAnswers
            var parts = [Self.count(list.prs.count, "open pull request")]
            if ready > 0 { parts.append("\(ready) ready to complete") }
            if comments > 0 { parts.append("\(comments) with open comments") }
            return ActionResult("You have " + Self.list(parts) + ".", data: ["prs": .from(list.prs)])
        }

        a.register("pr.get") { [unowned self] p in
            let id = try prParam(p)
            let pr = try JSONDecoder().decode(PullRequest.self, from: Data(try await cli.run(["pr", "show", String(id), "--json"]).utf8))
            prDetails[id] = pr
            return ActionResult("\(pr.title). \(Self.count(pr.openThreads, "open comment")), \(Self.count(pr.approvals, "approval"))"
                                + (pr.canComplete ? ", ready to complete." : "."), data: .from(pr))
        }

        a.register("pr.comment") { [unowned self] p in
            let id = try prParam(p)
            commentOnPR(id, text: p["text"]?.string ?? "")
            return ActionResult("Posting the comment.")
        }

        a.register("pr.reply") { [unowned self] p in
            let id = try prParam(p)
            guard let thread = Self.intParam(p["thread"]) else { throw ActionError("Which thread?") }
            replyToThread(pr: id, thread: thread, text: p["text"]?.string ?? "", resolve: p["resolve"]?.bool ?? false)
            return ActionResult("Posting the reply.")
        }

        a.register("pr.thread") { [unowned self] p in
            let id = try prParam(p)
            guard let thread = Self.intParam(p["thread"]), let status = p["status"]?.string else { throw ActionError("Which thread?") }
            setThreadStatus(pr: id, thread: thread, status: status)
            return ActionResult("Marking the thread \(status).")
        }

        a.register("pr.approve") { [unowned self] p in
            castVote(.approve, on: try prParam(p), from: nil)
            return ActionResult("Approving it.")
        }

        a.register("pr.vote") { [unowned self] p in
            guard let vote = p["vote"]?.string.flatMap(ReviewVote.init(rawValue:)) else { throw ActionError("Which vote?") }
            castVote(vote, on: try prParam(p), from: nil)
            return ActionResult("Voting \(vote.rawValue.replacingOccurrences(of: "-", with: " ")).")
        }

        a.register("pr.complete") { [unowned self] p in
            let id = try prParam(p)
            let pr = try await prModel(p)
            let auto = p["auto"]?.bool ?? false
            if !auto, !pr.canComplete { throw ActionError("It can't complete yet: " + pr.blockers.joined(separator: "; ") + ". Ask for auto-complete instead.") }
            let strategy = p["strategy"]?.string.flatMap { pr.strategies.contains($0) ? $0 : nil } ?? pr.strategies.first ?? "squash"
            completePR(id, strategy: strategy, deleteBranch: p["delete_branch"]?.bool ?? !pr.keepBranch,
                       completeWorkItems: p["complete_work_items"]?.bool ?? true,
                       message: p["message"]?.string ?? "Merged PR \(id): \(pr.title)", auto: auto)
            return ActionResult(auto ? "It completes by itself when it's ready." : "Completing it.")
        }

        a.register("pr.autocomplete.cancel") { [unowned self] p in
            cancelAutoComplete(try prParam(p))
            return ActionResult("Cancelled auto-complete.")
        }

        a.register("pr.comments.handle") { [unowned self] p in
            let pr = try await prModel(p)
            handlePRComments(pr, mode: p["mode"]?.string.flatMap(PRCommentsMode.init(rawValue:)) ?? .withMe)
            return ActionResult("A session is working through the comments.")
        }

        a.register("pr.conflicts") { [unowned self] p in
            resolveConflicts(try await prModel(p))
            return ActionResult("A session is resolving the conflicts.")
        }

        a.register("pr.build.fix") { [unowned self] p in
            fixFailedBuild(try await prModel(p))
            return ActionResult("A session is fixing the build.")
        }

        a.register("pr.build.rerun") { [unowned self] p in
            rerunBuild(try await prModel(p))
            return ActionResult("Running the build again.")
        }

        // MARK: Projects

        a.register("repos.pull") { [unowned self] p in
            pullRepos(scope: try scopeParam(p))
            return ActionResult("Pulling the repositories.")
        }
    }

    // MARK: Helpers

    func prParam(_ p: JSONValue) throws -> Int {
        guard let id = Self.intParam(p["id"]) else { throw ActionError("Which pull request?") }
        return id
    }

    func prModel(_ p: JSONValue) async throws -> PullRequest {
        let id = try prParam(p)
        if let pr = pullRequest(id) { return pr }
        let list = try PullRequestList.decode(try await cli.run(["pr", "list", "--json"]))
        guard let pr = list.pr(id) else { throw ActionError("Pull request \(id) isn't one of yours that's open.") }
        return pr
    }

    func strategyParam(_ key: String) throws -> Strategy { try engine.sessions.strategy(key) }

    func sessionParam(_ p: JSONValue) throws -> WorkSession { try engine.sessionParam(p) }

    /// A new factory's rules as the editor starts them: the current scope when it has a tracker, the last
    /// parallel count used.
    func newFactoryRules() -> FactoryRules { engine.factories.newRules() }

    static func strategyJSON(_ st: Strategy) -> JSONValue { RemotePayloads.strategy(st) }

}
