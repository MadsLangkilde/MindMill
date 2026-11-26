import Testing
@testable import KBCore

struct SessionVoiceTests {
    typealias Item = SessionVoiceFollower.Item

    @Test func progressAsMessagesFinishThenTheAnswer() {
        var f = SessionVoiceFollower()
        var items = [Item(role: "user", text: "earlier"), Item(role: "assistant", text: "earlier answer")]
        f.begin(count: items.count)
        items.append(Item(role: "user", text: "find the bug"))
        f.markSent()
        #expect(f.update(items: items, busy: true).isEmpty)

        items.append(Item(role: "assistant", text: "Looking at the login flow"))
        #expect(f.update(items: items, busy: true).isEmpty, "it may still be streaming")
        items.append(Item(role: "tool", text: "Read Login.kt"))
        #expect(f.update(items: items, busy: true) == [.progress("Looking at the login flow")])

        items.append(Item(role: "assistant", text: "Found it: the token expires too early."))
        #expect(f.update(items: items, busy: false) == [.answer("Found it: the token expires too early.")])
        #expect(!f.following)
        #expect(f.update(items: items + [Item(role: "assistant", text: "late")], busy: false).isEmpty)
    }

    @Test func aSessionThatFinishesWithoutWordsIsDoneQuietly() {
        var f = SessionVoiceFollower()
        f.begin(count: 0)
        f.markSent()
        #expect(f.update(items: [Item(role: "user", text: "archive it"), Item(role: "tool", text: "kb …")], busy: false) == [.doneQuietly])
    }

    @Test func notBusyBeforeTheMessageWentIsNotTheEnd() {
        var f = SessionVoiceFollower()
        f.begin(count: 0)
        #expect(f.update(items: [], busy: false).isEmpty)
        #expect(f.following)
    }

    @Test func promptsAndTools() {
        #expect(SessionVoice.prompt(.progress("x")) == "[Progress] x")
        #expect(SessionVoice.prompt(.answer("y")) == "[Answer] y")
        #expect(SessionVoice.tools.compactMap { $0["name"]?.string } == [SessionVoice.send, SessionVoice.stop])
        #expect(SessionVoice.instructions(session: "Login bug", project: "Web").contains("\"Login bug\" in the project Web"))
    }
}
