import AppKit
import KBCore
import KBEngine
import SwiftUI

/// Plan is the knowledge base and planning; Build is the implementation sessions.
enum AppMode: String, CaseIterable, Identifiable {
    case plan, build

    var id: String { rawValue }
    var title: String { self == .plan ? "Plan" : "Build" }
    var icon: String { self == .plan ? "books.vertical" : "hammer" }
}

struct StrategiesSheetRequest: Identifiable {
    let id = UUID()
    var selected: String?
}

/// The crew lives in the engine (`SessionHub`); these are what the views call.
extension AppModel {
    var crewDirectory: URL { engine.sessions.crewDirectory }

    var overseer: WorkSession? { engine.sessions.overseer }
    var buildSessions: [WorkSession] { engine.sessions.buildSessions }
    var buildSessionsNeedingUser: [WorkSession] { engine.sessions.buildSessionsNeedingUser }
    /// The overview session is waiting on the user: a question or a choice it asked.
    var overseerNeedsUser: Bool { overseer?.crewState.needsUser ?? false }
    /// Everything in Build that waits on the user, the overview session included.
    var waitingTally: WaitingTally {
        WaitingTally(buildSessions: buildSessionsNeedingUser.count, overseer: overseerNeedsUser,
                     factoryQuestions: factoryQuestionCount, planSessions: planSessionsNeedingUser.count)
    }
    var leads: [WorkSession] { engine.sessions.leads }
    var topLevelBuildSessions: [WorkSession] { engine.sessions.topLevelBuildSessions }
    func members(of lead: WorkSession) -> [WorkSession] { engine.sessions.members(of: lead) }
    var otherSessions: [WorkSession] { engine.sessions.otherSessions }
    func session(_ id: String?) -> WorkSession? { engine.sessions.session(id) }
    func sessions(about id: EntryID) -> [WorkSession] { engine.sessions.sessions(about: id) }

    var strategies: [Strategy] { engine.sessions.strategies }

    // MARK: Engine

    func startCrewEngine() { engine.sessions.startTicking() }

    func crewChanged() { engine.sessions.crewChanged() }

    func crewSnapshot() -> CrewState { engine.sessions.crewSnapshot() }

    func archiveFinished(_ s: WorkSession) { engine.sessions.archiveFinished(s) }

    func askFinishedSessions() { engine.sessions.askFinishedSessions() }

    func deliver(_ text: String, to s: WorkSession, from label: String) { engine.sessions.deliver(text, to: s, from: label) }

    // MARK: Actions

    @discardableResult
    func ensureOverseer() -> WorkSession { engine.sessions.ensureOverseer() }

    func askOverseer(_ text: String, attachments: [Attachment] = []) { engine.sessions.askOverseer(text, attachments: attachments) }

    @discardableResult
    func startLead(_ r: NewLeadRequest) -> WorkSession { engine.sessions.startLead(r) }

    func userAnswered(_ s: WorkSession, _ text: String) { engine.sessions.userAnswered(s, text) }

    /// A blank Build session, shown at once; listed once something is written in it.
    func quickStartSession(project: String?) {
        let s = engine.sessions.startQuick(project: project)
        mode = .build
        buildSelection = s.id
    }

    func workKey(_ about: String?) -> String? { engine.sessions.workKey(about) }

    func mainSession(forWork key: String) -> WorkSession? { engine.sessions.mainSession(forWork: key) }

    func groupSessionsByWork() { engine.sessions.groupSessionsByWork() }

    func promoteToLead(_ s: WorkSession) { engine.sessions.promoteToLead(s) }

    func makeLead(_ s: WorkSession) { engine.sessions.makeLead(s) }

    func move(_ s: WorkSession, under lead: WorkSession) { engine.sessions.move(s, under: lead) }

    func detach(_ s: WorkSession) { engine.sessions.detach(s) }

    /// Starts a stopped session again: it continues its own conversation where it left off.
    func resumeSession(_ s: WorkSession) {
        if !engine.sessions.resume(s) { buildSelection = s.id }
    }

    func deleteCrew(_ lead: WorkSession) { engine.sessions.deleteCrew(lead) }

    func stopCrew(_ lead: WorkSession) { engine.sessions.stopCrew(lead) }

    func message(_ s: WorkSession, _ text: String) { engine.sessions.message(s, text) }

    func applyStrategy(_ st: Strategy, to s: WorkSession) { engine.sessions.applyStrategy(st, to: s) }

    func start(_ task: String, with st: Strategy, in s: WorkSession, attachments: [Attachment] = []) {
        engine.sessions.start(task, with: st, in: s, attachments: attachments)
    }

    func clearStrategy(_ s: WorkSession) { engine.sessions.clearStrategy(s) }

    func reloadStrategies() { engine.sessions.reloadStrategies() }

    func saveStrategy(_ st: Strategy) {
        do { try engine.sessions.saveStrategy(st) } catch {
            errorMessage = "Could not save the strategy: \(error.localizedDescription)"
        }
    }

    func deleteStrategy(_ st: Strategy) {
        do { try engine.sessions.deleteStrategy(st) } catch {
            errorMessage = "Could not delete the strategy: \(error.localizedDescription)"
        }
    }

    /// Opens a session that helps write a new strategy and saves it with `kb strategy new`.
    func draftStrategyWithClaude() {
        strategiesSheet = nil
        engine.sessions.draftStrategy(space: mode == .build ? .build : .plan)
    }

    /// A Plan session continues in Build mode, for example once it turns into implementation work.
    func moveToBuild(_ s: WorkSession) {
        engine.sessions.moveToBuild(s)
        showInBuild(s)
    }

    func showInBuild(_ s: WorkSession) {
        mode = .build
        buildSelection = s.id
    }
}
