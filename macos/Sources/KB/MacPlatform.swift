import Foundation
import KBCore
import KBEngine
import Security

// The macOS side of KBEngine's adapter protocols (core/Sources/KBEngine/Adapters.swift). The companion transport
// is in MacCompanionTransport.swift.

enum MacPlatform {
    /// The engine's platform on this Mac. `AppModel` adds itself as the presenter and the brain's name.
    @MainActor static func make() -> EnginePlatform {
        EnginePlatform(name: "macOS", machineWord: "Mac", secrets: KeychainSecretStore.shared, transport: MacCompanionTransport(),
                       pluginRoot: { AppModel.currentPluginLocation.path })
    }
}

extension AppModel: Presenter {}

/// Secrets in the login Keychain of this Mac only, as generic passwords: `<group>/<account>` is kept under the
/// service `dk.langkilde.kb.<group>`, so voice keys (`voice-api/<provider>`) stay where earlier builds saved them.
final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    static let shared = KeychainSecretStore()

    /// Values read once per launch, so a voice conversation never asks the Keychain again.
    private var cache: [String: String] = [:]
    private let lock = NSLock()

    static func item(_ name: String) -> (service: String, account: String) {
        guard let slash = name.firstIndex(of: "/") else { return ("dk.langkilde.kb", name) }
        return ("dk.langkilde.kb." + name[..<slash], String(name[name.index(after: slash)...]))
    }

    func secret(_ name: String) -> String? {
        if let v = lock.withLock({ cache[name] }) { return v }
        let (service, account) = Self.item(name)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        lock.withLock { cache[name] = value }
        return value
    }

    func setSecret(_ value: String?, name: String) {
        let (service, account) = Self.item(name)
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        lock.withLock { cache[name] = value?.isEmpty == false ? value : nil }
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        SecItemAdd(add as CFDictionary, nil)
    }

    /// From the item's attributes only: reading the value itself needs the item's access list, and macOS asks for
    /// the login password whenever a new build of this ad-hoc signed app does that.
    func hasSecret(_ name: String) -> Bool {
        let (service, account) = Self.item(name)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnAttributes as String: true]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}

/// Real-time voice API keys, in the login Keychain of this Mac only. They never go to the phone.
struct VoiceKeychain: VoiceKeyStore {
    private var keys: SecretVoiceKeys { SecretVoiceKeys(KeychainSecretStore.shared) }

    func key(provider: String) -> String? { keys.key(provider: provider) }

    func set(_ key: String?, provider: String) { keys.set(key, provider: provider) }

    static func has(provider: String) -> Bool { KeychainSecretStore.shared.hasSecret(SecretVoiceKeys.name(provider)) }
}
