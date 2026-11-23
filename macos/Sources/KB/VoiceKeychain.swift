import Foundation
import KBCore
import Security

/// Real-time voice API keys, in the login Keychain of this Mac only. They never go to the phone.
struct VoiceKeychain: VoiceKeyStore {
    static let service = "dk.langkilde.kb.voice-api"

    /// Keys read once per launch, so a voice conversation never asks the Keychain again.
    @MainActor private static var cache: [String: String] = [:]

    func key(provider: String) -> String? {
        if let k = MainActor.assumeIsolated({ Self.cache[provider] }) { return k }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                    kSecAttrAccount as String: provider, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        MainActor.assumeIsolated { Self.cache[provider] = key }
        return key
    }

    func set(_ key: String?, provider: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                   kSecAttrAccount as String: provider]
        SecItemDelete(base as CFDictionary)
        MainActor.assumeIsolated { Self.cache[provider] = key?.isEmpty == false ? key : nil }
        guard let key, !key.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Whether a key is saved, from its attributes only: reading the key itself needs the item's access list, and
    /// macOS asks for the login password whenever a new build of this ad-hoc signed app does that.
    static func has(provider: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: provider, kSecReturnAttributes as String: true]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}
