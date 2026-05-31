import Foundation

struct AppConfiguration {
    let apiKey: String?
    let translateModel: String
    /// Whisper model name for source-language transcription. We always turn
    /// this on so the user can see the source text alongside the translation.
    let transcriptionModel: String

    static func load(bundle: Bundle = .main) -> AppConfiguration {
        let apiKey = sanitized(bundle.object(forInfoDictionaryKey: "OPENAI_API_KEY") as? String)
        let translateModel = sanitized(
            bundle.object(forInfoDictionaryKey: "OPENAI_REALTIME_TRANSLATE_MODEL") as? String
        ) ?? "gpt-realtime-translate"

        return AppConfiguration(
            apiKey: apiKey,
            translateModel: translateModel,
            transcriptionModel: "gpt-realtime-whisper"
        )
    }

    var startupIssue: String? {
        if apiKey == nil {
            return "Set OPENAI_API_KEY in Config/Local.xcconfig."
        }
        return nil
    }

    private static func sanitized(_ value: String?) -> String? {
        guard var trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.hasPrefix("$(") else {
            return nil
        }

        // xcconfig values are sometimes quoted to escape `//` inside URLs.
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            trimmed = String(trimmed.dropFirst().dropLast())
        }

        return trimmed.isEmpty ? nil : trimmed
    }
}
