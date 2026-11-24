import Foundation

/// Checked against each provider's docs on 2026-11-22.
public enum RealtimeProviders {
    public static let all: [RealtimeProvider] = [
        RealtimeProvider(id: "openai", name: "OpenAI Realtime", models: ["gpt-realtime-2.1", "gpt-realtime-2.1-mini", "gpt-realtime-2"],
                         defaultModel: "gpt-realtime-2.1",
                         voices: ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"],
                         defaultVoice: "marin", keyPage: "https://platform.openai.com/api-keys", available: true,
                         note: "About $0.10 a minute of conversation; mini is about a third of that."),
        RealtimeProvider(id: "gemini", name: "Google Gemini Live", models: ["gemini-3.8-live", "gemini-3.1-flash-live-preview"],
                         defaultModel: "gemini-3.8-live",
                         voices: ["Kore", "Puck", "Charon", "Fenrir", "Aoede", "Leda", "Orus", "Zephyr", "Callirrhoe", "Autonoe",
                                  "Enceladus", "Iapetus", "Umbriel", "Algieba", "Despina", "Erinome", "Algenib", "Rasalgethi",
                                  "Laomedeia", "Achernar", "Alnilam", "Schedar", "Gacrux", "Pulcherrima", "Achird",
                                  "Zubenelgenubi", "Vindemiatrix", "Sadachbia", "Sadaltager", "Sulafat"],
                         defaultVoice: "Kore", keyPage: "https://aistudio.google.com/apikey", available: true,
                         note: "About $0.02 a minute; there's a free tier."),
        RealtimeProvider(id: "xai", name: "xAI Grok Voice", models: ["grok-voice-latest", "grok-voice-3.0"], defaultModel: "grok-voice-latest",
                         voices: ["eve", "ara", "rex"], defaultVoice: "eve",
                         keyPage: "https://console.x.ai", available: true, note: "$0.08 a minute."),
        RealtimeProvider(id: "nova-sonic", name: "Amazon Nova Sonic", models: ["amazon.nova-2-5-sonic"], defaultModel: "amazon.nova-2-5-sonic",
                         voices: ["tiffany", "matthew", "amy"], defaultVoice: "tiffany",
                         keyPage: "https://console.aws.amazon.com/bedrock", available: false,
                         note: "Coming later: needs AWS IAM credentials and Bedrock's HTTP/2 stream, not a plain key."),
        RealtimeProvider(id: "deepgram", name: "Deepgram Voice Agent", models: ["standard"], defaultModel: "standard",
                         voices: [], defaultVoice: "", keyPage: "https://console.deepgram.com", available: false,
                         note: "Coming later."),
        RealtimeProvider(id: "assemblyai", name: "AssemblyAI Voice Agent", models: ["voice-agent"], defaultModel: "voice-agent",
                         voices: [], defaultVoice: "", keyPage: "https://www.assemblyai.com/app/api-keys", available: false,
                         note: "AssemblyAI is retiring this API."),
        RealtimeProvider(id: "elevenlabs", name: "ElevenLabs Agents", models: ["eleven_realtime_v1_mini", "eleven_realtime_v1_max"],
                         defaultModel: "eleven_realtime_v1_mini", voices: [], defaultVoice: "",
                         keyPage: "https://elevenlabs.io/app/settings/api-keys", available: false,
                         note: "Coming later: its server-side connection isn't documented yet."),
    ]
}
