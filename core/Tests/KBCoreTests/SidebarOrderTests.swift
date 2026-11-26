import Foundation
import Testing
@testable import KBCore

struct SidebarOrderTests {
    @Test func notesThenInboxComeFirstByDefault() {
        #expect(SidebarOrder.resolve([], defaults: SidebarOrder.planning).prefix(2) == ["notes", "inbox"])
        #expect(SidebarOrder.resolve(["decisions", "inbox"], defaults: SidebarOrder.planning).first == "notes")
    }

    @Test func aSavedOrderWinsAndNewRowsFindTheirPlace() {
        let saved = ["meetings", "inbox", "decisions"]
        let resolved = SidebarOrder.resolve(saved, defaults: ["inbox", "overview", "decisions", "meetings", "facts"])
        #expect(resolved == ["meetings", "facts", "inbox", "overview", "decisions"])
    }

    @Test func unknownAndRepeatedKeysAreDropped() {
        #expect(SidebarOrder.resolve(["x", "work", "work"], defaults: ["work"]) == ["work"])
    }

    @Test func movingSkipsHiddenRows() {
        let full = ["inbox", "overview", "decisions", "meetings"]
        let visible = ["inbox", "decisions", "meetings"]
        // Drag Meetings to the top.
        let moved = SidebarOrder.move(full, visible: visible, from: IndexSet(integer: 2), to: 0)
        #expect(moved == ["meetings", "overview", "inbox", "decisions"])
        #expect(moved.filter(visible.contains) == ["meetings", "inbox", "decisions"])
    }

    @Test func movingDown() {
        let keys = ["a", "b", "c"]
        #expect(SidebarOrder.move(keys, visible: keys, from: IndexSet(integer: 0), to: 3) == ["b", "c", "a"])
    }

    @Test func roundTrip() {
        #expect(SidebarOrder.decode(SidebarOrder.encode(["a", "b"])) == ["a", "b"])
    }
}
