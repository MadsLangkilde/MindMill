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
}
