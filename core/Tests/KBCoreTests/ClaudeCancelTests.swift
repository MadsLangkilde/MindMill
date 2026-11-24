import Foundation
import Testing
@testable import KBCore

private final class FakeProcess: ClaudeProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var _written: [String] = []
    var written: [String] { lock.withLock { _written } }

    func start(onLine: @escaping @Sendable (String) -> Void, onStderr: @escaping @Sendable (String) -> Void,
               onExit: @escaping @Sendable (Int32) -> Void) throws {}
    func write(_ line: String) throws { lock.withLock { _written.append(line) } }
    func terminate() {}
}

@Suite struct ClaudeCancelTests {
    @Test func queuedMessageIsDroppedAndRunningOneInterrupted() throws {
        let process = FakeProcess()
        let session = ClaudeSession(process: process)
        try session.start()
        session.send("first", tag: "a")
        session.send("second", tag: "b")
        #expect(process.written.count == 1)

        #expect(session.cancel(tag: "b") == .removed)
        #expect(session.queuedCount == 0)

        #expect(session.cancel(tag: "a") == .interrupted)
        let last = try #require(process.written.last)
        let json = try JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any]
        #expect(json?["type"] as? String == "control_request")
        #expect((json?["request"] as? [String: Any])?["subtype"] as? String == "interrupt")

        // The turn ends as usual; nothing else is sent, since "second" was taken back.
        session.handle(line: #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":""}"#)
        #expect(!session.isBusy)
        #expect(process.written.count == 2)
        #expect(session.cancel(tag: "zzz") == .notFound)
    }
}
