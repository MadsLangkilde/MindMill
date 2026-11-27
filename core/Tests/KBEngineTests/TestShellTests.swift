import Foundation
import Testing
@testable import KBEngine

struct TestShellTests {
    @Test func returnsWhenTheCommandEndsEvenIfSomethingItStartedKeepsRunning() async {
        let start = Date()
        let r = await TestShell.run("echo hi; sleep 20 &", environment: ProcessInfo.processInfo.environment, timeout: 15)
        #expect(r.code == 0)
        #expect(r.output.contains("hi"))
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func manyAtOnceAllFinish() async {
        let probes = (0..<24).map { ("p\($0)", "echo \($0)") }
        let found = await TestShell.probe(probes, environment: ProcessInfo.processInfo.environment)
        #expect(found.count == 24)
    }

    @Test func stopsAtTheTimeout() async {
        let r = await TestShell.run("sleep 10", environment: ProcessInfo.processInfo.environment, timeout: 1)
        #expect(r.code == -2)
    }
}
