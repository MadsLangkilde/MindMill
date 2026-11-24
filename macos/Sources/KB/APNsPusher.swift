import CryptoKit
import Foundation
import KBCore
import KBEngine
import SwiftUI
import UniformTypeIdentifiers

/// Pushes to iPhones through Apple's push service (APNs), with a token-based key (.p8) that stays on this Mac in the
/// Keychain. The phone only ever sends its device token (`push.register`).
@MainActor
final class APNsPusher {
    static let keySecret = "push/apns"
    static let keyIDKey = "apnsKeyID"
    static let teamIDKey = "apnsTeamID"

    private let secrets: SecretStore
    private var jwt: (token: String, made: Date)?
    private(set) var lastError: String?

    init(secrets: SecretStore = KeychainSecretStore.shared) { self.secrets = secrets }

    var keyID: String { UserDefaults.standard.string(forKey: Self.keyIDKey) ?? "" }
    var teamID: String { UserDefaults.standard.string(forKey: Self.teamIDKey) ?? "" }
    var isSetUp: Bool { !keyID.isEmpty && !teamID.isEmpty && secrets.hasSecret(Self.keySecret) }

    /// Saves the .p8 key's contents; false when it isn't a P-256 private key.
    func setKey(pem: String) -> Bool {
        guard (try? P256.Signing.PrivateKey(pemRepresentation: pem)) != nil else { return false }
        secrets.setSecret(pem, name: Self.keySecret)
        jwt = nil
        return true
    }

    func removeKey() {
        secrets.setSecret(nil, name: Self.keySecret)
        jwt = nil
    }

    func send(_ note: PushNote, to devices: [RemoteDevices.Device]) {
        guard isSetUp, let token = bearer() else { return }
        let body = (try? JSONEncoder().encode(note.payload)) ?? Data()
        for d in devices {
            guard let target = d.push, let url = URL(string: "https://\(target.host)/3/device/\(target.token)") else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue("bearer \(token)", forHTTPHeaderField: "authorization")
            req.setValue(target.topic, forHTTPHeaderField: "apns-topic")
            req.setValue("alert", forHTTPHeaderField: "apns-push-type")
            req.setValue("10", forHTTPHeaderField: "apns-priority")
            Task { [weak self] in
                do {
                    let (data, response) = try await URLSession.shared.data(for: req)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    await MainActor.run { self?.lastError = status == 200 ? nil : "APNs answered \(status): \(String(decoding: data, as: UTF8.self))" }
                } catch {
                    await MainActor.run { self?.lastError = error.localizedDescription }
                }
            }
        }
    }

    /// The provider token: an ES256 JWT, made again every 50 minutes (APNs accepts one for an hour).
    private func bearer(now: Date = Date()) -> String? {
        if let jwt, now.timeIntervalSince(jwt.made) < 50 * 60 { return jwt.token }
        guard let pem = secrets.secret(Self.keySecret), let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else {
            lastError = "The APNs key can't be read."
            return nil
        }
        func b64(_ d: Data) -> String {
            d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let header = b64(Data(#"{"alg":"ES256","kid":"\#(keyID)"}"#.utf8))
        let claims = b64(Data(#"{"iss":"\#(teamID)","iat":\#(Int(now.timeIntervalSince1970))}"#.utf8))
        let input = "\(header).\(claims)"
        guard let sig = try? key.signature(for: Data(input.utf8)) else { return nil }
        let token = "\(input).\(b64(sig.rawRepresentation))"
        jwt = (token, now)
        return token
    }
}

/// Settings → Remote → Push to iPhones: the APNs key (.p8), its key ID and the team ID.
struct PushSettingsView: View {
    let pusher: APNsPusher
    @AppStorage(APNsPusher.keyIDKey) private var keyID = ""
    @AppStorage(APNsPusher.teamIDKey) private var teamID = ""
    @State private var importing = false
    @State private var message: String?
    @State private var tick = 0

    var body: some View {
        let _ = tick
        Text("So an iPhone hears when a review is ready, a factory asks or a session needs you, even when Mindmill on it is closed. The key stays on this Mac.")
            .font(.callout).foregroundStyle(.secondary)
        LabeledContent("Key (.p8)") {
            HStack {
                Text(pusher.isSetUp ? "Saved" : (KeychainSecretStore.shared.hasSecret(APNsPusher.keySecret) ? "Saved" : "None"))
                Button("Choose…") { importing = true }
                if KeychainSecretStore.shared.hasSecret(APNsPusher.keySecret) { Button("Remove") { pusher.removeKey(); tick += 1 } }
            }
        }
        TextField("Key ID", text: $keyID)
        TextField("Team ID", text: $teamID)
        if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
        if let e = pusher.lastError { Text(e).font(.callout).foregroundStyle(.red) }
        Text("Make the key at developer.apple.com → Keys, with Apple Push Notifications service (APNs) ticked.")
            .font(.caption).foregroundStyle(.secondary)
            .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "p8") ?? .data, .data]) { result in
                guard case .success(let url) = result else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let pem = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                message = pusher.setKey(pem: pem) ? "Key saved in the Keychain." : "That isn't an APNs key (.p8)."
                if keyID.isEmpty, let id = url.deletingPathExtension().lastPathComponent.split(separator: "_").last { keyID = String(id) }
                tick += 1
            }
    }
}
