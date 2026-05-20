import Foundation

struct AppConfiguration: Sendable {
    let apiKey: String?
    let realtimeTokenEndpoint: URL?
    let realtimeWebSocketURL: URL
    let model: String
    let voice: String
    let transcriptionModel: String
    let instructions: String
    let useServerVAD: Bool
    let openclawEndpoint: String?
    let openclawToken: String?
    /// ISO 639-1 language codes from the user's device settings (e.g. ["en", "de"]).
    let preferredLanguageCodes: [String]

    static let uiTestStub = AppConfiguration(
        apiKey: "ui-test-key",
        realtimeTokenEndpoint: nil,
        realtimeWebSocketURL: URL(string: "wss://example.invalid/v1/realtime")!,
        model: "gpt-realtime",
        voice: "marin",
        transcriptionModel: "gpt-4o-mini-transcribe",
        instructions: "UI test mode.",
        useServerVAD: true,
        openclawEndpoint: nil,
        openclawToken: nil,
        preferredLanguageCodes: ["en"]
    )

    var openclawConfigured: Bool {
        openclawEndpoint != nil && openclawToken != nil
    }

    static func load(bundle: Bundle = .main) -> AppConfiguration {
        let apiKey = sanitized(bundle.object(forInfoDictionaryKey: "OPENAI_API_KEY") as? String)
        let tokenEndpoint = sanitized(bundle.object(forInfoDictionaryKey: "OPENAI_REALTIME_TOKEN_ENDPOINT") as? String)
        let websocketString = sanitized(bundle.object(forInfoDictionaryKey: "OPENAI_REALTIME_WEBSOCKET_URL") as? String)
        let defaultWebSocketURL = URL(string: "wss://api.openai.com/v1/realtime")!
        let model = sanitized(bundle.object(forInfoDictionaryKey: "OPENAI_REALTIME_MODEL") as? String) ?? "gpt-realtime"
        let voice = sanitized(bundle.object(forInfoDictionaryKey: "OPENAI_REALTIME_VOICE") as? String) ?? "marin"
        let transcriptionModel = sanitized(bundle.object(forInfoDictionaryKey: "OPENAI_REALTIME_TRANSCRIPTION_MODEL") as? String) ?? "gpt-4o-mini-transcribe"
        let baseInstructions = sanitized(bundle.object(forInfoDictionaryKey: "OPENAI_REALTIME_INSTRUCTIONS") as? String) ?? "You are an executive assistant helping Oliver while he is out and about to be productive. Be concise and to the point. Use the tools at your disposal to interact with information on the iPhone. For everything else you can message Clawdys, Oliver's personal assistant. She has many more skills and tools available than you have."
        let languages = Locale.preferredLanguages
            .prefix(3)
            .compactMap { Locale.current.localizedString(forIdentifier: $0) }
        let languageHint = languages.isEmpty ? "" : " The user's preferred languages are: \(languages.joined(separator: ", ")). Respond in whichever of these languages the user speaks to you in."
        let instructions = baseInstructions + languageHint
        let preferredLanguageCodes = Locale.preferredLanguages
            .prefix(3)
            .map { Locale(identifier: $0).language.languageCode?.identifier ?? String($0.prefix(2)) }
        let useServerVAD = boolValue(bundle.object(forInfoDictionaryKey: "OPENAI_REALTIME_USE_SERVER_VAD")) ?? true
        let openclawEndpoint = sanitized(bundle.object(forInfoDictionaryKey: "OPENCLAW_ENDPOINT") as? String)
            .map { prependScheme("https", to: $0).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        let openclawToken = sanitized(bundle.object(forInfoDictionaryKey: "OPENCLAW_TOKEN") as? String)

        return AppConfiguration(
            apiKey: apiKey,
            realtimeTokenEndpoint: tokenEndpoint.flatMap(URL.init(string:)),
            realtimeWebSocketURL: Self.validatedWebSocketURL(from: websocketString) ?? defaultWebSocketURL,
            model: model,
            voice: voice,
            transcriptionModel: transcriptionModel,
            instructions: instructions,
            useServerVAD: useServerVAD,
            openclawEndpoint: openclawEndpoint,
            openclawToken: openclawToken,
            preferredLanguageCodes: Array(preferredLanguageCodes)
        )
    }

    var startupIssue: String? {
        if apiKey == nil && realtimeTokenEndpoint == nil {
            return "Set either OPENAI_API_KEY or OPENAI_REALTIME_TOKEN_ENDPOINT in Config/Local.xcconfig."
        }

        return nil
    }

    var authModeDescription: String {
        if realtimeTokenEndpoint != nil {
            return "Backend-issued ephemeral token"
        }

        if apiKey != nil {
            return "Embedded API key (prototype only)"
        }

        return "Missing credentials"
    }

    private static func sanitized(_ value: String?) -> String? {
        guard var trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.hasPrefix("$(") else {
            return nil
        }

        // xcconfig values are often quoted to escape `//` (e.g. in URLs), and the
        // quotes pass through Info.plist substitution unchanged.
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            trimmed = String(trimmed.dropFirst().dropLast())
        }

        return trimmed.isEmpty ? nil : trimmed
    }

    private static func prependScheme(_ scheme: String, to value: String) -> String {
        let lower = value.lowercased()
        if lower.hasPrefix("\(scheme)://") || lower.hasPrefix("\(scheme)s://") {
            return value
        }
        // Also tolerate http/https/ws/wss already present — don't double-prepend.
        for existing in ["http://", "https://", "ws://", "wss://"] where lower.hasPrefix(existing) {
            return value
        }
        return "\(scheme)://\(value)"
    }

    private static func validatedWebSocketURL(from value: String?) -> URL? {
        guard let sanitizedValue = sanitized(value) else { return nil }
        let withScheme = prependScheme("wss", to: sanitizedValue)
        guard let url = URL(string: withScheme),
              let scheme = url.scheme?.lowercased(),
              scheme == "wss" || scheme == "ws",
              url.host != nil else {
            return nil
        }

        return url
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let string as String:
            return NSString(string: string).boolValue
        default:
            return nil
        }
    }
}
