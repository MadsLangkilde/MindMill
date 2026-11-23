import Foundation
import KBCore

/// Handlers for the work side: the tracker, pull requests, factories, strategies, sessions, testing and projects.
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

        a.register("backlog.proposed") { [unowned self] p in
            let scope = try scopeParam(p)
            let list = index.entries(project: scope, section: .backlog).filter { $0.backlogStatus == .proposed }
            guard let first = list.first else { return ActionResult("No proposed backlog items.") }
            return ActionResult("\(Self.count(list.count, "proposed item")). The first: \(first.title).",
                                data: ["entries": .array(list.map(Self.remoteSummary))])
        }

        a.register("backlog.propose") { [unowned self] p in
            let scope = try scopeParam(p)
            let title = p["title"]?.string ?? ""
            let details = p["details"]?.string ?? ""
            let bug = p["bug"]?.bool ?? false
            if let raw = p["source"]?.string, let source = EntryID(raw) {
                addProposedPBI(source: source, title: title, details: details, bug: bug, scope: scope)
            } else {
                _ = try await createEntryWithCLI(scope: scope, section: "backlog", title: title, summary: nil, tags: [],
                                                 fields: ["kind": bug ? "bug" : "pbi"], body: details.isEmpty ? nil : details)
            }
            return ActionResult("Proposed it in the backlog. Create it in the tracker when you're ready.")
        }

        a.register("backlog.create") { [unowned self] p in
            let id = try entryParam(p)
            createBacklog(id, sprint: p["sprint"]?.string.flatMap(Sprint.init(rawValue:)) ?? .none)
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

        // MARK: Factories

        a.register("factory.get") { [unowned self] p in
            let f = try factoryParam(p)
            var data = Self.factoryJSON(f)
            if case .object(var o) = data {
                o["rules"] = FactoryConfig.json(f.rules)
                o["problems"] = .array(f.rules.problems.map(JSONValue.string))
                data = .object(o)
            }
            let scopes = f.rules.scopes.map { index.project($0)?.title ?? $0 }
            return ActionResult("\(f.name) takes work from \(scopes.isEmpty ? "no scope yet" : Self.list(scopes)), \(f.rules.maxParallel) at a time.",
                                data: data)
        }

        a.register("factory.create") { [unowned self] p in
            loadFactoriesIfNeeded()
            let rules = try FactoryConfig.merge(newFactoryRules(), with: FactoryConfig.patch(fromAction: p))
            let id = saveFactory(id: nil, name: p["name"]?.string ?? "", rules: rules)
            let problems = rules.problems
            return ActionResult("Made the factory." + (problems.isEmpty ? " Start it when you're ready." : " Before it can start: " + problems.joined(separator: " ")),
                                data: ["id": .string(id), "problems": .array(problems.map(JSONValue.string))])
        }

        a.register("factory.update") { [unowned self] p in
            let f = try factoryParam(p)
            let rules = try FactoryConfig.merge(f.rules, with: FactoryConfig.patch(fromAction: p))
            let name = p["name"]?.string.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? f.name
            guard rules != f.rules || name != f.name else { return ActionResult("Nothing to change.") }
            saveFactory(id: f.id, name: name, rules: rules)
            return ActionResult("Changed \(name)." + (f.isRunning && rules != f.rules ? " The sessions at work were told." : ""))
        }

        a.register("factory.duplicate") { [unowned self] p in
            let f = try factoryParam(p)
            let name = p["name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "\(f.name) copy"
            let id = saveFactory(id: nil, name: name, rules: f.rules)
            return ActionResult("Made \(name).", data: ["id": .string(id)])
        }

        a.register("factory.delete") { [unowned self] p in
            let f = try factoryParam(p)
            if f.run?.status == .running { stopFactory(f.id) }
            deleteFactory(f.id)
            return ActionResult("Deleted \(f.name).")
        }

        a.register("factory.question.skip") { [unowned self] p in
            let (f, q) = try factoryQuestion(p)
            skipFactoryQuestion(f.id, q.id)
            return ActionResult("It decides that one itself.")
        }

        a.register("factory.item.skip") { [unowned self] p in
            let f = try factoryParam(p)
            guard let item = Self.intParam(p["work_item"]) else { throw ActionError("Which work item?") }
            skipFactoryItem(f.id, item)
            return ActionResult("\(f.name) skips \(item) this run.")
        }

        // MARK: Strategies

        a.register("strategies.list") { [unowned self] _ in
            if strategies.isEmpty { reloadStrategies() }
            return ActionResult("\(Self.count(strategies.count, "strategy", plural: "strategies")): " + Self.list(strategies.prefix(5).map(\.title)) + ".",
                                data: ["strategies": .array(strategies.map(Self.strategyJSON))])
        }

        a.register("strategy.get") { [unowned self] p in
            let st = try strategyParam(p["slug"]?.string ?? "")
            var data = Self.strategyJSON(st)
            if case .object(var o) = data { o["instructions"] = .string(st.instructions); data = .object(o) }
            return ActionResult("\(st.title). \(st.summary)", data: data)
        }

        a.register("strategy.save") { [unowned self] p in
            if strategies.isEmpty { reloadStrategies() }
            let title = (p["title"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw ActionError("A strategy needs a title.") }
            var st: Strategy
            if let slug = p["slug"]?.string, !slug.isEmpty {
                st = try strategyParam(slug)
            } else {
                var slug = Strategy.slugify(title)
                var n = 2
                while strategies.contains(where: { $0.slug == slug }) { slug = Strategy.slugify(title) + "-\(n)"; n += 1 }
                st = Strategy(slug: slug, title: title)
            }
            st.title = title
            if let s = p["summary"]?.string { st.summary = s }
            if let s = p["instructions"]?.string { st.instructions = s }
            if let s = p["model"]?.string { st.model = s }
            st.origin = .custom
            st.spawns = !st.roles.isEmpty
            saveStrategy(st)
            return ActionResult("Saved the strategy \(st.title).", data: ["slug": .string(st.slug)])
        }

        a.register("strategy.delete") { [unowned self] p in
            let st = try strategyParam(p["slug"]?.string ?? "")
            guard st.origin != .builtIn else { throw ActionError("\(st.title) is built in; it can't be deleted.") }
            deleteStrategy(st)
            return ActionResult(st.origin == .override ? "\(st.title) is back to the original." : "Deleted \(st.title).")
        }

        a.register("strategy.draft") { [unowned self] _ in
            draftStrategyWithClaude()
            return ActionResult("Started a session to draft a strategy with you.")
        }

        // MARK: Sessions

        a.register("session.lead") { [unowned self] p in
            let scope = try scopeParam(p)
            var r = NewLeadRequest(title: p["title"]?.string ?? "", project: scope, brief: p["brief"]?.string ?? "")
            r.strategy = try p["strategy"]?.string.map { try strategyParam($0).slug }
            if let n = Self.intParam(p["helpers"]) { r.helpers = .fixed; r.helperCount = max(1, min(8, n)) } else { r.helpers = .auto }
            startLead(r)
            return ActionResult("Started a lead session in Build.")
        }

        a.register("session.stop") { [unowned self] p in
            let s = try sessionParam(p)
            stopSession(s)
            return ActionResult("Stopped \(s.title).")
        }
        a.register("session.retry") { [unowned self] p in
            retryLast(in: try sessionParam(p))
            return ActionResult("Sent it again.")
        }
        a.register("session.allow") { [unowned self] p in
            allowDenied(in: try sessionParam(p))
            return ActionResult("Allowed it for that session.")
        }
        a.register("session.strategy") { [unowned self] p in
            let s = try sessionParam(p)
            let slug = p["strategy"]?.string ?? ""
            if slug.isEmpty {
                clearStrategy(s)
                return ActionResult("It follows no strategy now.")
            }
            let st = try strategyParam(slug)
            applyStrategy(st, to: s)
            return ActionResult("It follows \(st.title) now.")
        }
        a.register("session.to_build") { [unowned self] p in
            let s = try sessionParam(p)
            guard s.space == .plan else { throw ActionError("It's already in Build.") }
            moveToBuild(s)
            return ActionResult("Moved it to Build.")
        }
        a.register("session.archive") { [unowned self] p in
            let on = p["archived"]?.bool ?? true
            loadMeetingChatsIfNeeded()
            if let item = planItem(p["id"]?.string) {
                setArchived(item, on)
            } else {
                setArchived(try sessionParam(p), on)
            }
            return ActionResult(on ? "Archived it." : "Took it out of the archive.")
        }
        a.register("session.delete") { [unowned self] p in
            let s = try sessionParam(p)
            deleteSession(s)
            return ActionResult("Deleted \(s.title).")
        }

        // MARK: Testing

        a.register("test.detect") { [unowned self] p in
            let scope = try scopeParam(p)
            detectTestTargets(scope)
            return ActionResult("Looking again for what can be tested.")
        }
        a.register("test.check") { [unowned self] p in
            let scope = try scopeParam(p)
            await gatherTestFacts()
            await runCompatibilityCheck(scope, force: true)
            return testStatusResult(scope: scope)
        }
        a.register("test.deliver") { [unowned self] p in
            let scope = try scopeParam(p)
            guard let target = p["target"]?.string else { throw ActionError("Which target?") }
            guard let d = await deliverTest(scope: scope, targetID: target) else { throw ActionError("The delivery didn't work; see Test on the Mac.") }
            return ActionResult("Delivered \(d.title).", data: .from(d))
        }
        a.register("test.server.stop") { [unowned self] p in
            guard let id = p["id"]?.string, testing.servers[id] != nil else { throw ActionError("That server isn't running.") }
            stopDevServer(id)
            return ActionResult("Stopped it.")
        }

        // MARK: Projects

        a.register("scans.list") { [unowned self] _ in
            loadScansIfNeeded()
            guard !scans.isEmpty else { return ActionResult("No scans yet.") }
            let running = scans.filter { $0.finished == nil && !$0.failed }.count
            return ActionResult("\(Self.count(scans.count, "scan"))" + (running > 0 ? ", \(running) running." : "."),
                                data: ["scans": .array(scans.map { s in
                                    ["id": .string(s.id), "scope": .string(s.scope), "kinds": .array(s.kinds.map { .string($0.rawValue) }),
                                     "running": .bool(s.finished == nil && !s.failed), "failed": .bool(s.failed), "note": .string(s.note),
                                     "findings": .array(s.findings.map { f in
                                         ["id": .string(f.id), "kind": .string(f.kind.rawValue), "title": .string(f.title),
                                          "summary": .string(f.summary), "status": .string(f.status.rawValue)]
                                     })]
                                })])
        }
        a.register("scan.start") { [unowned self] p in
            let scopes = p["scopes"]?.strings.isEmpty == false ? p["scopes"]!.strings : [try scopeParam(p)]
            let kinds = (p["kinds"]?.strings ?? []).compactMap(ScanKind.init(rawValue:))
            let sources = (p["sources"]?.strings ?? []).compactMap(ScanSource.init(rawValue:))
            startScans(scopes: scopes, kinds: kinds.isEmpty ? ScanKind.allCases : kinds,
                       sources: sources.isEmpty ? ScanSource.allCases : sources, focus: p["focus"]?.string ?? "")
            return ActionResult("Started scanning " + Self.list(scopes) + ".")
        }
        a.register("scan.stop") { [unowned self] p in
            stopScan(p["id"]?.string ?? "")
            return ActionResult("Stopped the scan.")
        }
        a.register("scan.apply") { [unowned self] p in
            loadScansIfNeeded()
            guard let id = p["id"]?.string, let run = scans.first(where: { $0.id == id }) else { throw ActionError("No such scan.") }
            let picked = p["findings"]?.strings ?? []
            let ids = picked.isEmpty ? run.findings.filter { $0.status == .pending }.map(\.id) : picked
            applyFindings(run: id, ids: ids)
            return ActionResult("Adding \(Self.count(ids.count, "finding")) to the knowledge base.")
        }
        a.register("repos.pull") { [unowned self] p in
            pullRepos(scope: try scopeParam(p))
            return ActionResult("Pulling the repositories.")
        }
        a.register("people.list") { [unowned self] p in
            let q = (p["query"]?.string ?? "").lowercased()
            let list = people.all.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.email.lowercased().contains(q) }
            return ActionResult("\(Self.count(list.count, "person", plural: "people")).",
                                data: ["people": .array(list.prefix(100).map { ["name": .string($0.name), "email": .string($0.email)] })])
        }
        a.register("people.refresh") { [unowned self] _ in
            refreshPeople(force: true)
            return ActionResult("Reading the people directory again.")
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

    func strategyParam(_ key: String) throws -> Strategy {
        if strategies.isEmpty { reloadStrategies() }
        let k = key.lowercased()
        if let st = strategies.first(where: { $0.slug == k || $0.title.lowercased() == k }) { return st }
        if !k.isEmpty, let st = strategies.first(where: { $0.title.lowercased().contains(k) }) { return st }
        throw ActionError("There's no strategy \(key).")
    }

    func sessionParam(_ p: JSONValue) throws -> WorkSession {
        loadSessionsIfNeeded()
        guard let s = session(p["id"]?.string) else { throw ActionError("No such session.") }
        return s
    }

    private func factoryQuestion(_ p: JSONValue) throws -> (Factory, FactoryQuestion) {
        let raw = (p["question"]?.string ?? "").lowercased()
        guard !raw.isEmpty, let found = factories.lazy.compactMap({ f in
            f.run?.openQuestions.first { $0.id.uuidString.lowercased().hasPrefix(raw) }.map { (f, $0) }
        }).first else { throw ActionError("That question is already answered or gone.") }
        return found
    }

    /// A new factory's rules as the editor starts them: the current scope when it has a tracker, the last
    /// parallel count used.
    func newFactoryRules() -> FactoryRules {
        var rules = FactoryRules()
        if let p = projectID, factoryScopes.contains(where: { $0.id == p }) { rules.scopes = [p] }
        let last = UserDefaults.standard.integer(forKey: FactoryRulesSheet.parallelKey)
        if last > 0 { rules.maxParallel = last }
        return rules
    }

    static func strategyJSON(_ st: Strategy) -> JSONValue {
        ["slug": .string(st.slug), "title": .string(st.title), "summary": .string(st.summary), "origin": .string(st.origin.rawValue),
         "model": .string(st.model), "sessions": .number(Double(st.sessionCount)), "spawns": .bool(st.spawns)]
    }
}
