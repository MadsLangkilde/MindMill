import Testing
@testable import KB
import KBCore

@Test func appTargetLinks() {
    #expect(AppSettingsKeys.pluginRoot == "pluginRoot")
}

@Test func keychainItemsKeepTheirEarlierService() {
    #expect(KeychainSecretStore.item("voice-api/openai") == ("dk.langkilde.kb.voice-api", "openai"))
    #expect(KeychainSecretStore.item("plain") == ("dk.langkilde.kb", "plain"))
}
