import Foundation
import Testing
@testable import KBCore

struct SpeechChunkerTests {
    @Test func speaksTheFirstSentenceBeforeTheReplyEnds() {
        var c = SpeechChunker()
        #expect(c.add("You have three proposed facts wai").isEmpty)
        #expect(c.add("ting. The first is about the release ") == ["You have three proposed facts waiting."])
        #expect(c.add("train.") == [])
        #expect(c.finish() == ["The first is about the release train."])
    }

    @Test func keepsDecimalsAndAbbreviationsInOneSentence() {
        var c = SpeechChunker()
        let out = c.add("Version 3.5 is out, e.g. on the beta track. Next one ") + c.finish()
        #expect(out == ["Version 3.5 is out, e.g. on the beta track.", "Next one"])
    }

    @Test func joinsVeryShortSentencesWithTheNext() {
        var c = SpeechChunker()
        let out = c.add("OK. I stopped the nightly factory. ") + c.finish()
        #expect(out == ["OK. I stopped the nightly factory."])
    }

    @Test func turnsMarkdownIntoSpeech() {
        var c = SpeechChunker()
        let out = c.add("**Two** items:\n- Fix the [login bug](https://x.y/1)\n- Read https://example.com/a now\n```\ncode()\n```\nDone here.") + c.finish()
        #expect(out == ["Two items:", "Fix the login bug", "Read a link now", "Done here."])
    }

    @Test func counts() {
        var c = SpeechChunker()
        _ = c.add("First sentence here. Second sentence here. ")
        _ = c.finish()
        #expect(c.count == 2)
    }
}

struct VoiceEngineChoiceTests {
    @Test func keylessUnlessEverythingForTheAPIIsThere() {
        #expect(VoiceEngineChoice(preferred: .keyless, provider: "openai", hasKey: true).engine() == .keyless)
        #expect(VoiceEngineChoice(preferred: .api, provider: nil, hasKey: true).engine() == .keyless)
        #expect(VoiceEngineChoice(preferred: .api, provider: "openai", hasKey: false).engine() == .keyless)
        #expect(VoiceEngineChoice(preferred: .api, provider: "openai", hasKey: true).engine() == .api)
    }

    @Test func fallsBackAfterAFailureOrWhenForced() {
        let c = VoiceEngineChoice(preferred: .api, provider: "gemini", hasKey: true)
        #expect(c.engine(failed: true) == .keyless)
        #expect(c.engine(forceKeyless: true) == .keyless)
    }

    @Test func classifiesFailures() {
        #expect(VoiceFailure.classify(status: 401, message: "") == .badKey)
        #expect(VoiceFailure.classify(status: nil, message: "Incorrect API key provided") == .badKey)
        #expect(VoiceFailure.classify(status: 429, message: "") == .quota)
        #expect(VoiceFailure.classify(status: nil, message: "You exceeded your current quota") == .quota)
        #expect(VoiceFailure.classify(status: nil, message: "The network connection was lost.") == .network)
        #expect(VoiceEngineChoice.fallbackSpeech(.quota).contains("built-in voice"))
    }
}

struct VoiceKeyPrivacyTests {
    static let secret = "sk-test-SECRET-1234567890"

    func everyString(_ v: JSONValue) -> [String] {
        switch v {
        case .string(let s): return [s]
        case .array(let a): return a.flatMap(everyString)
        case .object(let o): return o.keys.map { $0 } + o.values.flatMap(everyString)
        default: return []
        }
    }

    @Test func thePhonesConfigNeverCarriesTheKey() throws {
        let store = MemoryKeyStore()
        store.set(Self.secret, provider: "openai")
        var prefs = VoicePreferences()
        prefs.engine = .api
        prefs.provider = "openai"
        let choice = VoiceEngineChoice(preferred: prefs.engine, provider: prefs.provider, hasKey: store.has(provider: "openai"))
        let config = prefs.remoteConfig(engine: choice.engine())
        #expect(config["engine"]?.string == "api")
        let strings = everyString(config)
        #expect(!strings.contains { $0.contains("SECRET") || $0.lowercased().contains("key") })
        let encoded = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        #expect(!encoded.contains(Self.secret))
    }

    @Test func savedPreferencesHoldNoKey() throws {
        var prefs = VoicePreferences()
        prefs.provider = "gemini"
        prefs.models["gemini"] = "m"
        let json = String(decoding: try JSONEncoder().encode(prefs), as: UTF8.self).lowercased()
        #expect(!json.contains("apikey") && !json.contains("\"key\""))
    }

    @Test func keylessConfigHasNoProvider() {
        var prefs = VoicePreferences()
        prefs.provider = "openai"
        let config = prefs.remoteConfig(engine: .keyless)
        #expect(config["provider"] == nil)
        #expect(config["engine"]?.string == "keyless")
    }
}
