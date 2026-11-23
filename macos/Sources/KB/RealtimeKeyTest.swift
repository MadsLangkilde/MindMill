import Foundation
import KBCore

/// Checks a voice API key with the cheapest call each provider has.
enum RealtimeKeyTest {
    static func request(provider: String, key: String) -> URLRequest? {
        var r: URLRequest
        switch provider {
        case "openai":
            r = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case "gemini":
            r = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!)
            r.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        case "xai":
            r = URLRequest(url: URL(string: "https://api.x.ai/v1/models")!)
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case "deepgram":
            r = URLRequest(url: URL(string: "https://api.deepgram.com/v1/projects")!)
            r.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        case "elevenlabs":
            r = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/models")!)
            r.setValue(key, forHTTPHeaderField: "xi-api-key")
        case "assemblyai":
            r = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/transcript?limit=1")!)
            r.setValue(key, forHTTPHeaderField: "Authorization")
        default:
            return nil
        }
        r.timeoutInterval = 15
        return r
    }

    static func test(provider: String, key: String) async -> String {
        guard let r = request(provider: provider, key: key) else { return "This provider's key can't be tested yet." }
        do {
            let (data, response) = try await URLSession.shared.data(for: r)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return "The key works (checked \(Date().formatted(date: .omitted, time: .shortened)))." }
            let message = String(decoding: data.prefix(300), as: UTF8.self)
            switch VoiceFailure.classify(status: status, message: message) {
            case .badKey: return "The provider refused this key (\(status)). Check it and save it again."
            case .quota: return "The key works, but its quota or credit has run out (\(status))."
            default: return "The provider answered \(status). Try again later."
            }
        } catch {
            return "Couldn't reach the provider: \(error.localizedDescription)"
        }
    }
}
