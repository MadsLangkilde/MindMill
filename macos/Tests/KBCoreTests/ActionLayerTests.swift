import Foundation
import Testing
@testable import KBCore

@MainActor
struct ActionLayerTests {
    func layer(_ ran: Recorder) -> ActionLayer {
        let a = ActionLayer()
        var n = 0
        a.makeToken = { n += 1; return "t\(n)" }
        a.onRun = { name, channel, _ in ran.calls.append("\(name)@\(channel.rawValue)") }
        a.register("overview") { _ in ActionResult("All calm.") }
        a.register("factory.stop") { p in ActionResult("Stopping \(p["factory"]?.string ?? "").") }
        a.register("factory.pause") { _ in ActionResult("Paused.") }
        a.register("workitem.create") { p in ActionResult("Created \(p["title"]?.string ?? "").") }
        return a
    }

    final class Recorder { var calls: [String] = [] }

    @Test func everyChannelRunsTheSameHandler() async {
        let ran = Recorder()
        let a = layer(ran)
        for channel in [ActionChannel.ui, .voice, .remote, .model] {
            #expect(await a.run("factory.pause", ["factory": "Nightly"], channel: channel) == .done(ActionResult("Paused.")))
        }
        #expect(ran.calls == ["factory.pause@ui", "factory.pause@voice", "factory.pause@remote", "factory.pause@model"])
    }

    @Test func destructiveActionsWaitForConfirmationExceptFromTheUI() async {
        let ran = Recorder()
        let a = layer(ran)
        let asked = await a.run("factory.stop", ["factory": "Nightly"], channel: .voice)
        #expect(asked == .confirm(token: "t1", question: "Stop the factory Nightly?"))
        #expect(ran.calls.isEmpty)
        #expect(await a.confirm("t1", channel: .voice) == .done(ActionResult("Stopping Nightly.")))
        #expect(ran.calls == ["factory.stop@voice"])
        // A token works once.
        if case .failed = await a.confirm("t1", channel: .voice) {} else { Issue.record("token reused") }
        #expect(await a.run("factory.stop", ["factory": "Nightly"], channel: .ui) == .done(ActionResult("Stopping Nightly.")))
    }

    @Test func externalWritesAreConfirmedToo() async {
        let a = layer(Recorder())
        let out = await a.run("workitem.create", ["title": "Dark mode"], channel: .remote)
        #expect(out == .confirm(token: "t1", question: "Create the work item “Dark mode” in the tracker?"))
    }

    @Test func confirmationsExpire() async {
        let a = layer(Recorder())
        let now = Date()
        _ = await a.run("factory.stop", ["factory": "X"], channel: .voice, now: now)
        let late = now.addingTimeInterval(ActionLayer.confirmationLifetime + 1)
        if case .failed = await a.confirm("t1", channel: .voice, now: late) {} else { Issue.record("expired token ran") }
    }

    @Test func cancelledConfirmationsNeverRun() async {
        let ran = Recorder()
        let a = layer(ran)
        _ = await a.run("factory.stop", ["factory": "X"], channel: .voice)
        a.cancel("t1")
        _ = await a.confirm("t1", channel: .voice)
        #expect(ran.calls.isEmpty)
    }

    @Test func confirmationCanBeTurnedOff() async {
        let a = layer(Recorder())
        a.confirmsRisky = false
        #expect(await a.run("factory.stop", ["factory": "X"], channel: .voice) == .done(ActionResult("Stopping X.")))
    }

    @Test func checksParameters() async {
        let a = layer(Recorder())
        #expect(await a.run("factory.stop", [:], channel: .ui) == .failed("factory.stop needs factory."))
        #expect(await a.run("nope", [:], channel: .ui) == .failed("I can't do nope."))
        let spec = ActionCatalog.all.first { $0.name == "followups.list" }!
        #expect(spec.problem(with: ["filter": "someone"]) == "filter must be one of mine, waiting, all.")
        #expect(spec.problem(with: ["filter": "mine"]) == nil)
    }

    @Test func toolNamesAreValidForMCPAndRealtimeAPIs() {
        for s in ActionCatalog.all {
            #expect(s.toolName.range(of: "^[a-zA-Z0-9_-]{1,64}$", options: .regularExpression) != nil, "\(s.toolName)")
        }
        #expect(Set(ActionCatalog.all.map(\.name)).count == ActionCatalog.all.count)
    }

    @Test func riskyActionsHaveTheRightRisk() {
        let risk = Dictionary(uniqueKeysWithValues: ActionCatalog.all.map { ($0.name, $0.risk) })
        #expect(risk["factory.stop"] == .destructive)
        #expect(risk["workitem.create"] == .external)
        #expect(risk["workitem.update"] == .external)
        #expect(risk["overview"] == .read)
    }

    @Test func mcpListsAndCallsTheSameActions() async throws {
        let ran = Recorder()
        let mcp = MCPActions(layer: layer(ran))
        let list = await mcp.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let names = list?["result"]?["tools"]?.array?.compactMap { $0["name"]?.string } ?? []
        #expect(names.contains("factory_stop"))
        #expect(names.contains("confirm_action"))

        let call = await mcp.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                     "params": ["name": "factory_stop", "arguments": ["factory": "Nightly"]]])
        let text = call?["result"]?["content"]?.array?.first?["text"]?.string ?? ""
        #expect(text.contains("Stop the factory Nightly?"))
        #expect(text.contains("token t1"))
        #expect(ran.calls.isEmpty)

        _ = await mcp.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                              "params": ["name": "confirm_action", "arguments": ["token": "t1"]]])
        #expect(ran.calls == ["factory.stop@model"])
        #expect(await mcp.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
    }

    @Test func mcpConfigPointsAtLocalhostWithTheToken() throws {
        let config = MCPActions.config(port: 5123, token: "abc")
        #expect(config.contains("\"url\":\"http://127.0.0.1:5123/mcp\""))
        #expect(config.contains("Bearer abc"))
    }

    @Test func readsHTTPRequestsInPieces() {
        var buffer = Data("POST /mcp HTTP/1.1\r\nContent-Length: 4\r\nAuthorization: Bearer x\r\n\r\nab".utf8)
        #expect(HTTPRequest.take(from: &buffer) == nil)
        buffer += Data("cdPOST".utf8)
        let r = HTTPRequest.take(from: &buffer)
        #expect(r?.method == "POST")
        #expect(r?.header("Authorization") == "Bearer x")
        #expect(r?.body == Data("abcd".utf8))
        #expect(buffer == Data("POST".utf8))
    }

    @Test func parsesStreamedTextDeltas() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}}"#
        #expect(ClaudeStreamLine.parse(line) == [.textDelta("Hel")])
    }

    @Test func launchAddsMCPAndPartialMessages() {
        var l = ClaudeLaunch(executable: URL(fileURLWithPath: "/bin/claude"), pluginRoot: "/p", systemPrompt: "s", sessionID: "id",
                             workingDirectory: URL(fileURLWithPath: "/tmp"))
        l.mcpConfig = "{}"
        l.partialMessages = true
        #expect(l.arguments.suffix(3) == ["--mcp-config", "{}", "--include-partial-messages"])
    }
}
