import Foundation
import Testing
@testable import KBEngine

/// The Mac's secrets in a file only the user can read, moved over from the Keychain earlier builds used.
@Suite struct FileSecretStoreTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kb-secrets-\(UUID().uuidString)")
    var url: URL { dir.appendingPathComponent("secrets/secrets.json") }

    func permissions(_ u: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: u.path))?[.posixPermissions].flatMap { ($0 as? NSNumber)?.intValue }
    }

    @Test func secretsStayInAFileOnlyTheUserCanRead() {
        let store = FileSecretStore(url: url)
        #expect(store.secret("voice-api/gemini") == nil && !store.hasSecret("voice-api/gemini"))
        store.setSecret("k1", name: "voice-api/gemini")
        #expect(permissions(url) == 0o600 && permissions(url.deletingLastPathComponent()) == 0o700)
        let stamp = store.secretStamp("voice-api/gemini")
        store.setSecret("k2", name: "voice-api/gemini")
        #expect(store.secretStamp("voice-api/gemini") != stamp)
        #expect(permissions(url) == 0o600)
        let again = FileSecretStore(url: url)
        #expect(again.secret("voice-api/gemini") == "k2" && again.hasSecret("voice-api/gemini"))
        again.setSecret(nil, name: "voice-api/gemini")
        #expect(FileSecretStore(url: url).secret("voice-api/gemini") == nil)
    }

    @Test func aKeychainSecretMovesOverOnceAndRemovingItDoesntBringItBack() {
        let keychain = MemorySecretStore(["voice-api/gemini": "old", "apns/key": "pem"])
        let store = FileSecretStore(url: url, legacy: keychain)
        #expect(store.hasSecret("voice-api/gemini") && store.secretStamp("voice-api/gemini") != nil)
        #expect(store.secret("voice-api/gemini") == "old")
        #expect(FileSecretStore(url: url).secret("voice-api/gemini") == "old")

        store.setSecret(nil, name: "voice-api/gemini")
        #expect(!store.hasSecret("voice-api/gemini") && store.secret("voice-api/gemini") == nil)
        #expect(!FileSecretStore(url: url, legacy: keychain).hasSecret("voice-api/gemini"))

        store.setSecret("new", name: "apns/key")
        #expect(FileSecretStore(url: url, legacy: keychain).secret("apns/key") == "new")
    }
}
