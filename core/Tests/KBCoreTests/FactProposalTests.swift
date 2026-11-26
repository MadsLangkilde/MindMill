import Foundation
import Testing
@testable import KBCore

struct FactProposalTests {
    private func entry(_ id: String, _ fm: String) -> KBEntry {
        KBEntry(id: EntryID(id)!, url: URL(fileURLWithPath: "/x.md"), text: "---\ntitle: T\n\(fm)\n---\n")
    }

    @Test func aProposedNewFactWaitsUnderFactsNotInTheInbox() {
        let e = entry("alpha/inbox/2026-11-18-t", "proposed_section: facts\nproposed_by: session:abc")
        #expect(e.isFactProposal)
        #expect(!e.isFactChange)
        #expect(!e.waitsInInbox)
    }

    @Test func aChangeToAFactIsNotANewProposal() {
        let e = entry("alpha/inbox/2026-11-18-t", "proposed_section: facts\nupdates: alpha/facts/t")
        #expect(e.isFactChange)
        #expect(!e.isFactProposal)
        #expect(!e.waitsInInbox)
    }

    @Test func otherProposalsStayInTheInbox() {
        let e = entry("alpha/inbox/2026-11-18-t", "proposed_section: decisions")
        #expect(e.waitsInInbox)
        #expect(!e.isFactProposal)
    }

    @Test func anApprovedFactIsNoProposal() {
        let e = entry("alpha/facts/t", "proposed_section: facts")
        #expect(!e.isFactProposal)
        #expect(!e.waitsInInbox)
    }

    @Test func everyBuildSessionButTheOverviewIsAskedToProposeFacts() {
        for role in [SessionRole.solo, .lead, .member] {
            let p = ClaudeModes.crew(role: role, sessionID: "s1", leadTitle: nil, leadID: nil, project: "alpha")
            #expect(p.contains("kb inbox add --project alpha --section <facts|decisions|ideas|followups|references|architecture|notes> --proposed-by session:s1"))
            #expect(p.contains("kb goal propose"))
        }
        #expect(!ClaudeModes.crew(role: .overseer, sessionID: "s1", leadTitle: nil, leadID: nil, project: nil).contains("--section <facts"))
    }
}
