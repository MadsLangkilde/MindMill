import CryptoKit
import Foundation

/// Any JSON value, for the remote protocol's parameters and results.
public enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? { if case .string(let s) = self { return s } else { return nil } }
    public var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var int: Int? { if case .number(let n) = self { return Int(n) } else { return nil } }
    public var array: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var strings: [String] { array?.compactMap(\.string) ?? [] }

    /// Any `Encodable` as JSON, through its encoding.
    public static func from<T: Encodable>(_ value: T) -> JSONValue {
        guard let data = try? JSONEncoder().encode(value), let v = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .null }
        return v
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral v: String) { self = .string(v) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
    public init(integerLiteral v: Int) { self = .number(Double(v)) }
    public init(arrayLiteral v: JSONValue...) { self = .array(v) }
    public init(dictionaryLiteral v: (String, JSONValue)...) { self = .object(Dictionary(v, uniquingKeysWith: { a, _ in a })) }
    public init(nilLiteral: ()) { self = .null }
}

/// The messages between the Mac and a phone, as JSON text frames on one WebSocket. The phone sends requests and the
/// Mac answers each with the same `id`; the Mac also pushes events. Binary frames carry audio or screenshots, with
/// a short JSON header first (see docs/remote-api.md).
public enum RemoteMessage: Equatable, Sendable {
    case request(id: String, method: String, params: JSONValue)
    case response(id: String, result: JSONValue)
    case failure(id: String, code: String, message: String)
    case event(name: String, data: JSONValue)

    public static let version = 1

    public func encoded() -> String {
        var o: [String: JSONValue] = [:]
        switch self {
        case .request(let id, let method, let params): o = ["id": .string(id), "method": .string(method), "params": params]
        case .response(let id, let result): o = ["id": .string(id), "result": result]
        case .failure(let id, let code, let message): o = ["id": .string(id), "error": ["code": .string(code), "message": .string(message)]]
        case .event(let name, let data): o = ["event": .string(name), "data": data]
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(JSONValue.object(o))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    public static func decode(_ text: String) -> RemoteMessage? {
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return nil }
        if let name = v["event"]?.string { return .event(name: name, data: v["data"] ?? .null) }
        guard let id = v["id"]?.string else { return nil }
        if let method = v["method"]?.string { return .request(id: id, method: method, params: v["params"] ?? .object([:])) }
        if let e = v["error"] { return .failure(id: id, code: e["code"]?.string ?? "error", message: e["message"]?.string ?? "") }
        return .response(id: id, result: v["result"] ?? .null)
    }
}

/// Phones allowed in: each paired once with a short code shown on the Mac, then known by a token only it holds.
/// Only a hash of each token is kept.
public struct RemoteDevices: Codable, Equatable, Sendable {
    public struct Device: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var tokenHash: String
        public var paired: Date
        public var lastSeen: Date?
    }

    public var devices: [Device] = []

    public init() {}

    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Adds a device and returns the token to hand it, once.
    public mutating func pair(name: String, now: Date = Date()) -> (device: Device, token: String) {
        let token = Self.randomToken()
        let d = Device(id: UUID().uuidString.lowercased(), name: name.isEmpty ? "Phone" : name, tokenHash: Self.hash(token), paired: now)
        devices.append(d)
        return (d, token)
    }

    public func device(token: String) -> Device? {
        let h = Self.hash(token)
        return devices.first { $0.tokenHash == h }
    }

    public mutating func seen(_ id: String, at date: Date = Date()) {
        if let i = devices.firstIndex(where: { $0.id == id }) { devices[i].lastSeen = date }
    }

    public mutating func remove(_ id: String) { devices.removeAll { $0.id == id } }

    public mutating func rename(_ id: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[i].name = n
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
    }
}

/// The short code that lets one phone pair, shown on the Mac (and in its QR code) for a few minutes.
public struct PairingCode: Equatable, Sendable {
    public var code: String
    public var expires: Date

    public static func new(now: Date = Date(), minutes: Double = 10) -> PairingCode {
        PairingCode(code: String(format: "%06d", Int.random(in: 0...999_999)), expires: now.addingTimeInterval(minutes * 60))
    }

    public func accepts(_ attempt: String, now: Date = Date()) -> Bool {
        now < expires && attempt.trimmingCharacters(in: .whitespaces) == code
    }
}

/// What the phone needs to find and trust the Mac, as the QR code's text: `kb://pair?…`.
public struct PairingInvite: Equatable, Sendable {
    /// Addresses to try in order: the Mac's names and IPs on the local network and Tailscale.
    public var hosts: [String]
    public var port: Int
    /// The SHA-256 of the Mac's certificate, which the phone pins instead of trusting a certificate authority.
    public var fingerprint: String
    public var code: String
    public var name: String

    public init(hosts: [String], port: Int, fingerprint: String, code: String, name: String) {
        self.hosts = hosts
        self.port = port
        self.fingerprint = fingerprint
        self.code = code
        self.name = name
    }

    public var url: String {
        var c = URLComponents()
        c.scheme = "kb"
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "v", value: String(RemoteMessage.version)),
            URLQueryItem(name: "hosts", value: hosts.joined(separator: ",")),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "fp", value: fingerprint),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "name", value: name),
        ]
        return c.string ?? ""
    }

    public static func parse(_ url: String) -> PairingInvite? {
        guard let c = URLComponents(string: url), c.scheme == "kb", c.host == "pair" else { return nil }
        func q(_ n: String) -> String? { c.queryItems?.first { $0.name == n }?.value }
        guard let hosts = q("hosts")?.split(separator: ",").map(String.init), !hosts.isEmpty,
              let port = q("port").flatMap(Int.init), let fp = q("fp"), let code = q("code") else { return nil }
        return PairingInvite(hosts: hosts, port: port, fingerprint: fp, code: code, name: q("name") ?? "Mindmill")
    }
}

/// The Mac's addresses a phone can reach: Tailscale's (100.64.0.0/10, and its MagicDNS name) work from anywhere on
/// the tailnet, private LAN addresses at home or the office. Loopback and link-local are left out.
public enum RemoteAddresses {
    public static func isTailscale(_ ip: String) -> Bool {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        return p.count == 4 && p[0] == 100 && (64...127).contains(p[1])
    }

    public static func isPrivateLAN(_ ip: String) -> Bool {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168)
    }

    /// What an address is, for the list in Settings → Remote.
    public static func label(_ host: String) -> String {
        if isTailscale(host) { return "Tailscale" }
        if host.hasSuffix(".ts.net") { return "Tailscale name" }
        if host.hasSuffix(".local") { return "Local name" }
        if isPrivateLAN(host) { return "Local network" }
        return "Address"
    }

    /// LAN first (fastest when both are there), then Tailscale, then names.
    public static func ordered(ips: [String], names: [String]) -> [String] {
        let lan = ips.filter(isPrivateLAN)
        let ts = ips.filter(isTailscale)
        var seen: Set<String> = []
        return (lan + ts + names).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The IPv4 addresses of this Mac's network interfaces.
    public static func interfaceIPs() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: host))
            }
        }
        return out
    }
}

/// A binary frame: a 4-byte big-endian header length, a JSON header, then the payload (audio, a JPEG, a file chunk).
public struct RemoteFrame: Equatable, Sendable {
    public var header: JSONValue
    public var payload: Data

    public init(header: JSONValue, payload: Data) {
        self.header = header
        self.payload = payload
    }

    public var kind: String? { header["kind"]?.string }

    public func encoded() -> Data {
        let head = (try? JSONEncoder().encode(header)) ?? Data("{}".utf8)
        var length = UInt32(head.count).bigEndian
        return Data(bytes: &length, count: 4) + head + payload
    }

    public static func decode(_ data: Data) -> RemoteFrame? {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data.prefix(4))
        let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard length > 0, data.count >= 4 + length else { return nil }
        let start = data.startIndex + 4
        guard let header = try? JSONDecoder().decode(JSONValue.self, from: data[start..<(start + length)]) else { return nil }
        return RemoteFrame(header: header, payload: Data(data[(start + length)...]))
    }
}
