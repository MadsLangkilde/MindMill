import Foundation
import Testing
@testable import KBCore

struct PluginLocationTests {
    private func exists(_ paths: [String]) -> (String) -> Bool {
        { p in paths.contains { KBConfig.expandTilde($0) + "/scripts/kb.py" == p } }
    }

    @Test func aChosenFolderWinsWhenItHasTheScripts() {
        let r = PluginLocation.resolve(chosen: "/x/kb", bundled: "/App/plugin", exists: exists(["/x/kb", "/App/plugin"]))
        #expect(r.path == "/x/kb" && r.source == .chosen)
    }

    @Test func aFreshMacUsesTheCopyInsideTheApp() {
        let r = PluginLocation.resolve(chosen: nil, bundled: "/App/plugin", exists: exists(["/App/plugin"]))
        #expect(r.path == "/App/plugin" && r.source == .bundled)
        let stale = PluginLocation.resolve(chosen: "/gone", bundled: "/App/plugin", exists: exists(["/App/plugin"]))
        #expect(stale.source == .bundled)
    }

    @Test func aRepoCheckoutIsTheLastResort() {
        let r = PluginLocation.resolve(chosen: nil, bundled: nil, exists: exists([PluginLocation.developmentPath]))
        #expect(r.source == .development)
        #expect(PluginLocation.resolve(chosen: nil, bundled: "/App/plugin", exists: exists([])).source == .missing)
    }
}
