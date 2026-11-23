import Foundation
import Testing
@testable import KBCore

@Suite struct CleanupAnywayTests {
    private func pr(_ extra: String) throws -> CompletedPRs.PR {
        let json = """
        {"id": 5, "title": "t", "repo": "r", "scope": "s", "closed": "2026-11-19", "url": "", "branch": "test/1.0.0-57",
         "repo_path": "/repo", "worktrees": [{"path": "/repo/wt", "dirty": true}], "local_branch": true,
         "local_branch_safe": false, "checked_out_in_main": true, "remote_branch": true, \(extra)}
        """
        return try JSONDecoder().decode(CompletedPRs.PR.self, from: Data(json.utf8))
    }

    @Test func anywayRemovesEverythingAndSaysWhatThatLoses() throws {
        let p = try pr(#""target": "main", "main_dirty": true"#)
        #expect(p.forceCleanupArgs == ["pr", "cleanup", "5", "--worktree", "--branch", "--remote", "--force"])
        #expect(p.safeCleanupArgs(worktrees: true, localBranch: true, remote: true) == nil)
        let effects = p.anywayEffects.joined(separator: "\n")
        #expect(effects.contains("uncommitted changes"))
        #expect(effects.contains("didn't take"))
        #expect(effects.contains("Switches your main checkout (/repo) to main first; its uncommitted changes come along"))
        #expect(effects.contains("normally kept"))
        #expect(p.needsDecision.contains("a test branch kept on Azure DevOps"))
    }

    @Test func olderListsWithoutTheNewFieldsStillDecode() throws {
        let p = try pr(#""x": 1"#)
        #expect(p.target == nil && p.mainDirty == nil)
        #expect(p.anywayEffects.contains { $0.contains("to its target branch first.") })
    }
}
