import KBCore
import KBEngine
import SwiftUI

struct FactoryEditRequest: Identifiable {
    let id = UUID()
    /// Nil for a new factory.
    var factoryID: String?
}

/// The software factories run in the engine (`FactoryLoop`); these are what the views call, and which factory
/// Build shows.
extension AppModel {
    static let factoryTag = "factory:"

    var factories: [Factory] { engine.factories.list }

    var factoryAsides: [UUID: ClaudeChat] { engine.factories.asides }

    func loadFactoriesIfNeeded() { engine.factories.loadIfNeeded() }

    func saveFactories() { engine.factories.save() }

    func factory(_ id: String?) -> Factory? { engine.factories.factory(id) }

    var selectedFactoryID: String? {
        guard let raw = buildSelection, raw.hasPrefix(Self.factoryTag) else { return nil }
        return String(raw.dropFirst(Self.factoryTag.count))
    }

    func showFactory(_ id: String?) {
        mode = .build
        buildSelection = Self.factoryTag + (id ?? factories.first?.id ?? "")
    }

    /// Questions waiting on the user, across the factories.
    var factoryQuestionCount: Int { engine.factories.questionCount }

    // MARK: Setting up

    @discardableResult
    func saveFactory(id: String?, name: String, rules: FactoryRules) -> String { engine.factories.save(id: id, name: name, rules: rules) }

    func renameFactory(_ id: String, _ name: String) { engine.factories.rename(id, name) }

    func editFactoryDashboard(_ id: String, _ edit: (inout FactoryDashboard) -> Void) { engine.factories.editDashboard(id, edit) }

    /// Fetches a work item's description and criteria once, for the context of a question about it.
    func loadWorkItemDetail(_ id: Int, scope: String) {
        guard workItemDetails[id] == nil, !workItemDetailLoading.contains(id) else { return }
        workItemDetailLoading.insert(id)
        let cli = cli
        Task {
            if let out = try? await cli.run(["tracker", "item", String(id), "--json", "--scope", scope]),
               let detail = try? WorkItemDetail.decode(out) {
                workItemDetails[id] = detail
            }
            workItemDetailLoading.remove(id)
        }
    }

    func deleteFactory(_ id: String) { engine.factories.delete(id) }

    var factoryScopes: [KBProject] { engine.factories.scopes }

    var overviewScopeID: String? { engine.factories.overviewScopeID }

    // MARK: Running

    func startFactory(_ id: String) { engine.factories.start(id) }

    func stopFactory(_ id: String, reason: String = "You stopped it.") { engine.factories.stop(id, reason: reason) }

    func pauseFactory(_ id: String) { engine.factories.pause(id) }

    func resumeFactory(_ id: String) { engine.factories.resume(id) }

    func skipFactoryItem(_ id: String, _ item: Int) { engine.factories.skipItem(id, item) }

    func occupiesSlot(_ t: FactoryTask, in f: Factory) -> Bool { engine.factories.occupiesSlot(t, in: f) }

    func nextItems(_ f: Factory, backlog: TrackerBacklog) -> [TrackerBacklog.Item] { engine.factories.nextItems(f, backlog: backlog) }

    func factFingerprints(_ rules: FactoryRules) -> [String: String] { engine.factories.factFingerprints(rules) }

    func factoryProposals(_ f: Factory) -> [KBEntry] { engine.factories.proposals(f) }

    // MARK: Questions

    func answerFactoryQuestion(_ fid: String, _ qid: UUID, answer: String) { engine.factories.answer(fid, qid, answer: answer) }

    func allOpenQuestions() -> [FactoryQuestion] { engine.factories.allOpenQuestions() }

    func dismissAnsweredForYou(_ fid: String, _ qid: UUID) { engine.factories.dismissAnsweredForYou(fid, qid) }

    func addToAnsweredForYou(_ fid: String, _ qid: UUID, _ text: String) { engine.factories.addToAnsweredForYou(fid, qid, text) }

    func skipFactoryQuestion(_ fid: String, _ qid: UUID) { engine.factories.skipQuestion(fid, qid) }

    /// One prompt to Claude, never saved; nil when it fails or takes longer than `timeout`.
    func claudeOnce(_ prompt: String, system: String, model: String = "sonnet", tools: [String] = [],
                    timeout: TimeInterval = 120) async -> String? {
        await engine.claudeOnce(prompt, system: system, model: model, tools: tools, timeout: timeout)
    }

    // MARK: Side conversations on questions

    static let asideTools = FactoryLoop.asideTools

    func canStartAside(_ q: FactoryQuestion) -> Bool { engine.factories.canStartAside(q) }

    func startFactoryAside(_ q: FactoryQuestion) { engine.factories.startAside(q) }

    func askFactoryAside(_ qid: UUID, _ text: String) { engine.factories.askAside(qid, text) }

    func endFactoryAside(_ qid: UUID) { engine.factories.endAside(qid) }
}
