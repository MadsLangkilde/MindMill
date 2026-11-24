import Foundation
import KBCore

/// The tracker and pull request actions over the engine's `TrackerCache` and the `kb` CLI. The Mac registers its own
/// versions over some of these (busy marks, its caches of past sprints and PR threads).
extension MindmillEngine {
    func registerTrackerActions() {
        let a = actions

        a.register("overview") { [unowned self] p in
            let scope = try scopeParam(p)
            let proposed = factProposals(project: scope).count
            let open = openFollowups(scope)
            let mine = open.filter { $0.responsibility(me: myNames()) == .me }.count
            let items = tracker.items(scope: scope).filter { $0.mine && $0.stage != .done && $0.stage != .resolved }
            factories.loadIfNeeded()
            sessions.loadIfNeeded()
            let running = factories.list.filter(\.isRunning)
            let questions = factories.allOpenQuestions().count
            let waiting = sessions.list.filter { !sessions.sessionArchived($0) && $0.crewState.needsUser }
            var parts: [String] = []
            if proposed > 0 { parts.append(ActionText.count(proposed, "proposed fact")) }
            if mine > 0 { parts.append(ActionText.count(mine, "follow-up") + " on you") }
            if open.count > mine { parts.append("\(open.count - mine) waiting on others") }
            if !items.isEmpty { parts.append(ActionText.count(items.count, "work item") + " assigned to you") }
            if !running.isEmpty { parts.append(ActionText.count(running.count, "factory", plural: "factories") + " running") }
            if questions > 0 { parts.append(ActionText.count(questions, "factory question")) }
            if !waiting.isEmpty { parts.append(ActionText.count(waiting.count, "session") + " waiting for you") }
            let speech = parts.isEmpty ? "Nothing needs you right now." : "You have " + ActionText.list(parts) + "."
            return ActionResult(speech, data: [
                "scope": .string(scope), "proposedFacts": .number(Double(proposed)), "followupsMine": .number(Double(mine)),
                "followupsWaiting": .number(Double(open.count - mine)), "workItems": .number(Double(items.count)),
                "factoriesRunning": .number(Double(running.count)), "factoryQuestions": .number(Double(questions)),
                "sessionsWaiting": .array(waiting.map(sessionJSON)),
            ])
        }

        // MARK: Work items

        a.register("backlog.list") { [unowned self] p in
            let scope = try scopeParam(p)
            await tracker.freshBacklog()
            if tracker.backlog == nil { tracker.backlog = try TrackerBacklog.decode(try await cli.run(["tracker", "backlog", "--json"])) }
            var items = tracker.items(scope: scope).filter { $0.stage != .done }
            if p["mine"]?.bool == true { items = items.filter(\.mine) }
            if let state = p["state"]?.string, !state.isEmpty { items = items.filter { $0.state.lowercased() == state.lowercased() } }
            guard let first = items.first else { return ActionResult("No work items match.") }
            return ActionResult("\(ActionText.count(items.count, "work item")). The first is \(first.id), \(first.title), \(first.state).",
                                data: ["items": .from(items)])
        }

        a.register("workitem.get") { [unowned self] p in
            guard let id = ActionText.intParam(p["id"]) else { throw ActionError("Which work item?") }
            let out = try await cli.run(["tracker", "item", String(id)])
            let item = tracker.backlog?.items.first { $0.id == id }
            return ActionResult(item.map { "\($0.id): \($0.title), \($0.state), assigned to \($0.assignee.isEmpty ? "nobody" : $0.assignee)." } ?? "Work item \(id).",
                                data: ["id": .number(Double(id)), "text": .string(String(out.prefix(12000)))])
        }

        a.register("workitem.update") { [unowned self] p in
            guard let id = ActionText.intParam(p["id"]).map(String.init) else { throw ActionError("Which work item?") }
            var said: [String] = []
            if let state = p["state"]?.string, !state.isEmpty {
                _ = try await cli.run(["tracker", "state", "--state", state, id]); said.append("set to \(state)")
            }
            if let who = p["assignee"]?.string, !who.isEmpty {
                _ = try await cli.run(["tracker", "assign", "--to", who, id]); said.append("assigned to \(who)")
            }
            if let sprint = p["sprint"]?.string, !sprint.isEmpty {
                var args = ["tracker", "move", "--sprint", sprint, id]
                if let scope = p["scope"]?.string { args += ["--project", scope] }
                _ = try await cli.run(args); said.append("moved to \(sprint)")
            }
            if let comment = p["comment"]?.string, !comment.isEmpty {
                _ = try await cli.run(["tracker", "note", id, "--text", comment, "--comment"]); said.append("commented")
            }
            tracker.refreshBacklog(force: true)
            return ActionResult(said.isEmpty ? "Nothing to change." : "Work item \(id) " + ActionText.list(said) + ".")
        }

        a.register("workitem.search") { [unowned self] p in
            let q = (p["query"]?.string ?? "").trimmingCharacters(in: .whitespaces)
            let found = try TrackerBacklog.decode(try await cli.run(["tracker", "backlog", "--search", q, "--json"])).items
            guard let first = found.first else { return ActionResult("No work items match \(q).") }
            return ActionResult("\(ActionText.count(found.count, "work item")). The first is \(first.id), \(first.title), \(first.state).",
                                data: ["items": .from(found)])
        }

        a.register("workitem.tasks") { [unowned self] p in
            let ids = (p["ids"]?.strings ?? p["ids"]?.string.map { [$0] } ?? []).compactMap { ActionText.intParam(.string($0)) }
            guard !ids.isEmpty, let state = p["state"]?.string else { throw ActionError("Which tasks?") }
            _ = try await cli.run(["tracker", "task-state"] + ids.map(String.init) + ["--state", state])
            tracker.backlog = tracker.backlog?.settingTasks(Set(ids), to: state)
            tracker.refreshBacklog(force: true)
            return ActionResult("Set \(ActionText.count(ids.count, "task")) to \(state).")
        }

        a.register("workitem.implement") { [unowned self] p in
            let scope = try scopeParam(p)
            guard let id = ActionText.intParam(p["id"]) else { throw ActionError("Which work item?") }
            guard let item = tracker.myWork?.items.first(where: { $0.id == id })
                    ?? tracker.items(scope: scope).first(where: { $0.id == id })?.asMyWork
            else { throw ActionError("I can't find work item \(id) in \(scope)'s backlog.") }
            let strategy = try p["strategy"]?.string.map { try sessions.strategy($0) }
            sessions.beginImplement(item, fast: p["mode"]?.string == "fast", strategy: strategy, show: false)
            return ActionResult("Started \(id) in a Build session.")
        }

        // MARK: Pull requests

        a.register("prs.list") { [unowned self] _ in
            let list = try PullRequestList.decode(try await cli.run(["pr", "list", "--json"]))
            tracker.refreshPullRequests(force: true)
            guard !list.prs.isEmpty else { return ActionResult("You have no open pull requests.") }
            let ready = list.prs.filter(\.canComplete).count
            let comments = list.needingAnswers
            var parts = [ActionText.count(list.prs.count, "open pull request")]
            if ready > 0 { parts.append("\(ready) ready to complete") }
            if comments > 0 { parts.append("\(comments) with open comments") }
            return ActionResult("You have " + ActionText.list(parts) + ".", data: ["prs": .from(list.prs)])
        }

        a.register("prs.reviews") { [unowned self] _ in
            let reviews = try await reviewsToDo()
            guard !reviews.isEmpty else { return ActionResult("No pull requests wait for your review.", data: ["reviews": []]) }
            let rows: [JSONValue] = reviews.map { r in
                var o: [String: JSONValue] = ["id": .number(Double(r.id)), "title": .string(r.title), "repo": .string(r.repo),
                                              "url": .string(r.url), "author": .string(r.author), "draft": .bool(r.draft),
                                              "required": .bool(r.required), "project": .string(r.project)]
                if let s = sessions.list.first(where: { $0.about == r.sessionKey }) { o["session"] = .string(s.id) }
                return .object(o)
            }
            return ActionResult("\(ActionText.count(reviews.count, "pull request")) \(reviews.count == 1 ? "waits" : "wait") for your review.",
                                data: ["reviews": .array(rows)])
        }

        a.register("pr.review") { [unowned self] p in
            guard let id = ActionText.intParam(p["id"] ?? p["pr"]) else { throw ActionError("Which pull request?") }
            if let s = sessions.list.first(where: { $0.about == "pr:\(id)" }) {
                return ActionResult("Pull request \(id) already has a review session.", data: ["session": .string(s.id)])
            }
            guard let r = try await reviewsToDo().first(where: { $0.id == id }) else {
                throw ActionError("Pull request \(id) isn't waiting for your review.")
            }
            let s = sessions.startReview(r)
            return ActionResult("Started reviewing pull request \(id).", data: ["session": .string(s.id)])
        }

        a.register("pr.get") { [unowned self] p in
            let id = try prParam(p)
            let pr = try JSONDecoder().decode(PullRequest.self, from: Data(try await cli.run(["pr", "show", String(id), "--json"]).utf8))
            return ActionResult("\(pr.title). \(ActionText.count(pr.openThreads, "open comment")), \(ActionText.count(pr.approvals, "approval"))"
                                + (pr.canComplete ? ", ready to complete." : "."), data: .from(pr))
        }

        a.register("pr.comment") { [unowned self] p in
            let id = try prParam(p)
            _ = try await cli.run(["pr", "comment", String(id)], stdin: p["text"]?.string ?? "")
            return ActionResult("Commented.")
        }

        a.register("pr.reply") { [unowned self] p in
            let id = try prParam(p)
            guard let thread = ActionText.intParam(p["thread"]) else { throw ActionError("Which thread?") }
            let resolve = p["resolve"]?.bool ?? false
            var args = ["pr", "reply", String(id), String(thread)]
            if resolve { args += ["--status", "fixed"] }
            _ = try await cli.run(args, stdin: p["text"]?.string ?? "")
            return ActionResult(resolve ? "Replied and resolved." : "Replied.")
        }

        a.register("pr.thread") { [unowned self] p in
            let id = try prParam(p)
            guard let thread = ActionText.intParam(p["thread"]), let status = p["status"]?.string else { throw ActionError("Which thread?") }
            _ = try await cli.run(["pr", "thread", String(id), String(thread), "--status", status])
            return ActionResult("Marked the thread \(status).")
        }

        a.register("pr.approve") { [unowned self] p in
            try await vote(.approve, on: try prParam(p))
        }

        a.register("pr.vote") { [unowned self] p in
            guard let vote = p["vote"]?.string.flatMap(ReviewVote.init(rawValue:)) else { throw ActionError("Which vote?") }
            return try await self.vote(vote, on: try prParam(p))
        }

        a.register("pr.complete") { [unowned self] p in
            let id = try prParam(p)
            let pr = try await prModel(p)
            let auto = p["auto"]?.bool ?? false
            if !auto, !pr.canComplete { throw ActionError("It can't complete yet: " + pr.blockers.joined(separator: "; ") + ". Ask for auto-complete instead.") }
            let strategy = p["strategy"]?.string.flatMap { pr.strategies.contains($0) ? $0 : nil } ?? pr.strategies.first ?? "squash"
            var args = ["pr", "complete", String(id), "--strategy", strategy, (p["delete_branch"]?.bool ?? !pr.keepBranch) ? "--delete-branch" : "--keep-branch"]
            if p["complete_work_items"]?.bool ?? true { args.append("--complete-work-items") }
            let message = p["message"]?.string ?? "Merged PR \(id): \(pr.title)"
            if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { args += ["--message", message] }
            if auto { args.append("--auto") }
            _ = try await cli.run(args)
            tracker.refreshAll()
            return ActionResult(auto ? "It completes by itself when it's ready." : "Completed it.")
        }

        a.register("pr.autocomplete.cancel") { [unowned self] p in
            let id = try prParam(p)
            _ = try await cli.run(["pr", "complete", String(id), "--cancel-auto"])
            tracker.refreshAll()
            return ActionResult("Cancelled auto-complete.")
        }

        a.register("pr.comments.handle") { [unowned self] p in
            let pr = try await prModel(p)
            sessions.handlePRComments(pr, mode: p["mode"]?.string.flatMap(PRCommentsMode.init(rawValue:)) ?? .withMe)
            return ActionResult("A session is working through the comments.")
        }

        a.register("pr.conflicts") { [unowned self] p in
            let pr = try await prModel(p)
            sessions.askAboutPR(pr, message: PRFix.conflicts(pr), display: "Resolve the merge conflicts in !\(pr.id)")
            return ActionResult("A session is resolving the conflicts.")
        }

        a.register("pr.build.fix") { [unowned self] p in
            let pr = try await prModel(p)
            sessions.askAboutPR(pr, message: PRFix.failedBuild(pr), display: "Fix the failed build of !\(pr.id)")
            return ActionResult("A session is fixing the build.")
        }

        a.register("pr.build.rerun") { [unowned self] p in
            let pr = try await prModel(p)
            _ = try await cli.run(["pr", "checks", String(pr.id), "--requeue", "--log-lines", "0"])
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                self?.tracker.refreshPullRequests(force: true)
            }
            return ActionResult("Running the build again.")
        }
    }

    private func vote(_ vote: ReviewVote, on id: Int) async throws -> ActionResult {
        let out = try await cli.run(["pr", "vote", String(id), "--vote", vote.rawValue])
        tracker.refreshMyWork(force: true)
        let line = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return ActionResult(line.isEmpty ? "Voted on !\(id)." : line)
    }

    public func prParam(_ p: JSONValue) throws -> Int {
        guard let id = ActionText.intParam(p["id"]) else { throw ActionError("Which pull request?") }
        return id
    }

    /// The pull request a call names: from the cache, else the open list.
    public func prModel(_ p: JSONValue) async throws -> PullRequest {
        let id = try prParam(p)
        if let pr = tracker.pullRequest(id) { return pr }
        let list = try PullRequestList.decode(try await cli.run(["pr", "list", "--json"]))
        guard let pr = list.pr(id) else { throw ActionError("Pull request \(id) isn't one of yours that's open.") }
        return pr
    }
}

extension MindmillEngine {
    /// Pull requests waiting for the user's review, from "my work" (fetched now when it's missing or old).
    func reviewsToDo() async throws -> [MyWork.Review] {
        if let work = tracker.myWork, let at = tracker.myWorkFetched, Date().timeIntervalSince(at) < 120 { return work.reviews }
        let work = try MyWork.decode(try await cli.run(["tracker", "mine", "--json"]))
        tracker.myWork = work
        tracker.myWorkFetched = Date()
        return work.reviews
    }
}
