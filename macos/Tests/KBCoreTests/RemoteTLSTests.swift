import Foundation
import Network
import Security
import Testing
@testable import KBCore

/// The remote server's identity is read into memory only; a phone must still get a TLS connection with the pinned
/// certificate. Runs a real listener on loopback with a throwaway identity.
struct RemoteTLSTests {
    private final class Box: @unchecked Sendable {
        var peerFingerprint: String?
        var reply: String?
        var server: [NWConnection] = []
    }

    @Test func aClientReachesTheListenerOverTLSWithThePinnedCertificate() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kb-remote-tls-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try RemoteIdentity.load(folder: folder)
        #expect(id.fingerprint.count == 64)
        #expect(try RemoteIdentity.load(folder: folder).fingerprint == id.fingerprint)

        let queue = DispatchQueue(label: "tls-test")
        let box = Box()
        let listener = try NWListener(using: RemoteIdentity.parameters(id), on: .any)
        listener.newConnectionHandler = { conn in
            box.server.append(conn)
            conn.start(queue: queue)
            conn.receiveMessage { data, _, _, _ in
                let meta = NWProtocolWebSocket.Metadata(opcode: .text)
                let ctx = NWConnection.ContentContext(identifier: "echo", metadata: [meta])
                conn.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; cont.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let e): resumed = true; cont.resume(throwing: e)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        defer { listener.cancel() }

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
            if let leaf = chain?.first { box.peerFingerprint = RemoteIdentity.fingerprint(der: SecCertificateCopyData(leaf) as Data) }
            complete(true)
        }, queue)
        let params = NWParameters(tls: tls)
        params.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        let client = NWConnection(to: .url(URL(string: "wss://127.0.0.1:\(port)/")!), using: params)
        defer { client.cancel() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            client.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    let meta = NWProtocolWebSocket.Metadata(opcode: .text)
                    let ctx = NWConnection.ContentContext(identifier: "hi", metadata: [meta])
                    client.send(content: Data("hello".utf8), contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
                    client.receiveMessage { data, _, _, error in
                        box.reply = data.map { String(decoding: $0, as: UTF8.self) }
                        if let error { cont.resume(throwing: error) } else { cont.resume() }
                    }
                case .failed(let e), .waiting(let e): resumed = true; cont.resume(throwing: e)
                default: break
                }
            }
            client.start(queue: queue)
        }
        #expect(box.peerFingerprint == id.fingerprint)
        #expect(box.reply == "hello")
    }

    @Test func retriesSlowDownAndStartOverWhenReset() {
        var r = RemoteRetry()
        #expect((0..<7).map { _ in r.next() } == [2, 5, 10, 30, 60, 60, 60])
        r.reset()
        #expect(r.next() == 2)
    }

    @Test func listenerErrorsSayWhatToDo() {
        #expect(RemoteListenError.describe(.posix(.EADDRINUSE), port: 7878).contains("already in use"))
        #expect(RemoteServerStatus.failed(reason: "x", retryAt: nil).reason == "x")
        #expect(RemoteServerStatus.running(port: 1).isRunning)
    }

    @Test func phonesCanBeRenamed() {
        var d = RemoteDevices()
        let (device, _) = d.pair(name: "Pixel")
        d.rename(device.id, to: "  Pixel 10 ")
        #expect(d.devices.first?.name == "Pixel 10")
        d.rename(device.id, to: " ")
        #expect(d.devices.first?.name == "Pixel 10")
        #expect(RemoteAddresses.label("100.101.2.3") == "Tailscale")
        #expect(RemoteAddresses.label("192.168.1.5") == "Local network")
        #expect(RemoteAddresses.label("mac.tail1.ts.net") == "Tailscale name")
    }
}
