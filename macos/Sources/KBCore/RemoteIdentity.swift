import CryptoKit
import Foundation
import Network
import Security

/// The Mac's own certificate for remote access, made once with the system's openssl and kept in a folder (Application
/// Support for the app). Phones pin its fingerprint when they pair, so no certificate authority is involved.
///
/// The identity is read into memory only and never added to a keychain: an identity in the login keychain belongs to
/// the build that imported it, and every new build of an ad-hoc signed app would make macOS ask for the password.
public enum RemoteIdentity {
    public struct Loaded: @unchecked Sendable {
        public let identity: SecIdentity
        /// SHA-256 of the certificate's DER bytes, hex, lower case.
        public let fingerprint: String
    }

    public static func load(folder: URL) throws -> Loaded {
        let p12 = folder.appendingPathComponent("identity.p12")
        let pass = folder.appendingPathComponent("identity.pass")
        if !FileManager.default.fileExists(atPath: p12.path) { try create(folder: folder, p12: p12, pass: pass) }
        let password = try String(contentsOf: pass, encoding: .utf8)
        var items: CFArray?
        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
        if #available(macOS 15, *) { options[kSecImportToMemoryOnly as String] = true }
        let status = SecPKCS12Import(try Data(contentsOf: p12) as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let ref = first[kSecImportItemIdentity as String] else {
            throw NSError(domain: "KB", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not read the remote access certificate (\(status))."])
        }
        let identity = ref as! SecIdentity
        var cert: SecCertificate?
        SecIdentityCopyCertificate(identity, &cert)
        let der = cert.map { SecCertificateCopyData($0) as Data } ?? Data()
        return Loaded(identity: identity, fingerprint: fingerprint(der: der))
    }

    public static func fingerprint(der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    private static func create(folder: URL, p12: URL, pass: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let password = UUID().uuidString
        let key = folder.appendingPathComponent("key.pem"), cert = folder.appendingPathComponent("cert.pem")
        defer { try? FileManager.default.removeItem(at: key) }
        let host = Host.current().localizedName ?? "Mac"
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path, "-out", cert.path, "-days", "3650",
                 "-subj", "/CN=Mindmill on \(host)"])
        try run(["pkcs12", "-export", "-inkey", key.path, "-in", cert.path, "-out", p12.path, "-passout", "pass:\(password)"])
        try password.write(to: pass, atomically: true, encoding: .utf8)
        for f in [p12, pass] { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path) }
    }

    private static func run(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "KB", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "openssl failed: \(msg.prefix(300))"])
        }
    }

    /// TLS (1.2 or later) with this identity, carrying a WebSocket.
    public static func parameters(_ loaded: Loaded, maximumMessageSize: Int = 16 * 1024 * 1024) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        if let secID = sec_identity_create(loaded.identity) {
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secID)
        }
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let params = NWParameters(tls: tls)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = maximumMessageSize
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.allowLocalEndpointReuse = true
        return params
    }
}

/// What the remote server is doing, for Settings → Remote.
public enum RemoteServerStatus: Equatable, Sendable {
    case off
    case starting
    case running(port: Int)
    /// The listener waits for the network (no interface up); it starts by itself once there is one.
    case waiting(reason: String)
    /// It failed; it tries again by itself at `retryAt` (nil: only when the user asks).
    case failed(reason: String, retryAt: Date?)

    public var isRunning: Bool { if case .running = self { return true } else { return false } }

    public var reason: String? {
        switch self {
        case .waiting(let r), .failed(let r, _): return r
        default: return nil
        }
    }
}

/// How long to wait before starting the listener again after it failed: quickly at first, then less often.
public struct RemoteRetry: Equatable, Sendable {
    public static let delays: [TimeInterval] = [2, 5, 10, 30, 60]
    public private(set) var attempts = 0

    public init() {}

    public mutating func next() -> TimeInterval {
        let d = Self.delays[min(attempts, Self.delays.count - 1)]
        attempts += 1
        return d
    }

    public mutating func reset() { attempts = 0 }
}

/// Listener errors in the user's words.
public enum RemoteListenError {
    public static func describe(_ error: NWError, port: Int) -> String {
        switch error {
        case .posix(let code):
            switch code {
            case .EADDRINUSE:
                return "Port \(port) is already in use by another app. Quit that app or choose another port."
            case .EACCES, .EPERM:
                return "macOS didn't allow listening on port \(port). Choose a port above 1024."
            case .ENETDOWN, .ENETUNREACH, .EADDRNOTAVAIL:
                return "There is no network right now. Mindmill starts again when the Mac is back online."
            default:
                return "Could not listen on port \(port): \(String(cString: strerror(code.rawValue)))."
            }
        case .tls(let status):
            return "The secure connection could not be set up (\(status))."
        default:
            return "Could not listen on port \(port): \(error.localizedDescription)"
        }
    }
}
