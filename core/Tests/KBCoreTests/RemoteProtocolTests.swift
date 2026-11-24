import Foundation
import Testing
@testable import KBCore

struct RemoteProtocolTests {
    @Test func messagesRoundTrip() {
        let msgs: [RemoteMessage] = [
            .request(id: "1", method: "entries.list", params: ["scope": "app", "section": "facts"]),
            .response(id: "1", result: ["entries": [["id": "app/facts/x", "title": "X"]]]),
            .failure(id: "2", code: "unauthorized", message: "Pair first"),
            .event(name: "session.item", data: ["session": "s1", "text": "Hi"]),
        ]
        for m in msgs { #expect(RemoteMessage.decode(m.encoded()) == m) }
        #expect(RemoteMessage.decode("not json") == nil)
        #expect(RemoteMessage.decode(#"{"method":"x"}"#) == nil)
    }

    @Test func pairedTokensAreKnownOnlyByTheirHash() {
        var d = RemoteDevices()
        let (device, token) = d.pair(name: "Pixel")
        #expect(device.tokenHash != token && device.tokenHash.count == 64)
        #expect(d.device(token: token)?.id == device.id)
        #expect(d.device(token: token + "x") == nil)
        d.remove(device.id)
        #expect(d.device(token: token) == nil)
    }

    @Test func pairingCodesExpire() {
        let now = Date()
        let c = PairingCode(code: "123456", expires: now.addingTimeInterval(60))
        #expect(c.accepts(" 123456", now: now))
        #expect(!c.accepts("123457", now: now))
        #expect(!c.accepts("123456", now: now.addingTimeInterval(61)))
        #expect(PairingCode.new().code.count == 6)
    }

    @Test func invitesRoundTripThroughTheQRText() {
        let i = PairingInvite(hosts: ["192.168.1.5", "100.101.1.2", "mac.tail1234.ts.net"], port: 7878,
                              fingerprint: "ab:cd", code: "123456", name: "Mads's MacBook")
        #expect(PairingInvite.parse(i.url) == i)
        #expect(PairingInvite.parse("https://example.com") == nil)
    }

    @Test func addressesPutTheLANFirstThenTailscale() {
        #expect(RemoteAddresses.isTailscale("100.101.2.3") && !RemoteAddresses.isTailscale("100.20.2.3"))
        #expect(RemoteAddresses.isPrivateLAN("172.20.0.1") && !RemoteAddresses.isPrivateLAN("8.8.8.8"))
        #expect(RemoteAddresses.ordered(ips: ["127.0.0.1", "100.101.2.3", "192.168.1.50", "169.254.1.1"], names: ["mac.ts.net"])
                == ["192.168.1.50", "100.101.2.3", "mac.ts.net"])
    }

    @Test func platformsMatchOrAcceptEverything() {
        #expect(RemotePlatform.parse("iOS") == "ios")
        #expect(RemotePlatform.parse("Android") == "android")
        #expect(RemotePlatform.parse("windows") == nil)
        #expect(RemotePlatform.accepts(phone: "ios", item: "ios"))
        #expect(!RemotePlatform.accepts(phone: "ios", item: "android"))
        #expect(RemotePlatform.accepts(phone: nil, item: "android"), "a phone that doesn't say gets everything")
        #expect(RemotePlatform.accepts(phone: "android", item: nil))
        var d = RemoteDevices()
        let (device, _) = d.pair(name: "iPhone")
        let first = d.setPlatform(device.id, "ios")
        let same = d.setPlatform(device.id, "ios")
        let none = d.setPlatform(device.id, nil)
        #expect(first)
        #expect(!same)
        #expect(!none, "saying nothing keeps what it said before")
        #expect(d.devices[0].platform == "ios")
    }

    @Test func oldDeviceListsStillLoad() throws {
        let old = #"{"devices":[{"id":"a","name":"Pixel","tokenHash":"h","paired":0}]}"#
        let d = try JSONDecoder().decode(RemoteDevices.self, from: Data(old.utf8))
        #expect(d.devices[0].platform == nil && d.devices[0].push == nil)
    }

    @Test func pushTargetsAndNotes() throws {
        #expect(PushTarget(token: "nothex", environment: "sandbox", topic: "dk.x") == nil)
        let t = try #require(PushTarget(token: String(repeating: "AB", count: 32), environment: "production", topic: "dk.langkilde.mindmill"))
        #expect(t.token == String(repeating: "ab", count: 32))
        #expect(t.host == "api.push.apple.com")
        #expect(PushTarget(token: String(repeating: "a", count: 64), environment: "x", topic: "t")?.host == "api.sandbox.push.apple.com")

        var d = RemoteDevices()
        let (iphone, _) = d.pair(name: "iPhone")
        let (pixel, _) = d.pair(name: "Pixel")
        let (away, _) = d.pair(name: "iPad")
        d.setPlatform(iphone.id, "ios")
        d.setPlatform(pixel.id, "android")
        d.setPush(iphone.id, t)
        d.setPush(pixel.id, t)
        d.setPush(away.id, t)
        let card = try #require(PushNote.from(event: "review.card", data: ["id": "c1", "title": "Apple Pay", "platform": "ios"]))
        #expect(card.route == "test")
        #expect(d.pushTargets(for: card, connected: [away.id]).map(\.id) == [iphone.id], "not Android, not a connected phone")
        #expect(card.payload["aps"]?["alert"]?["title"]?.string == "Ready for review")
        #expect(card.payload["route"]?.string == "test")

        #expect(PushNote.from(event: "session.changed", data: ["id": "s1", "state": "waiting"])?.route == "session")
        #expect(PushNote.from(event: "session.changed", data: ["id": "s1", "state": "waiting"], wasWaiting: true) == nil)
        #expect(PushNote.from(event: "session.changed", data: ["id": "s1", "state": "working"]) == nil)
        #expect(PushNote.from(event: "factory.changed", data: ["id": "f"], factoryQuestions: 0) == nil)
        #expect(PushNote.from(event: "factory.changed", data: ["id": "f"], factoryQuestions: 2)?.body == "It has 2 questions.")
        #expect(PushNote.from(event: "index.changed", data: [:]) == nil)
    }
}
