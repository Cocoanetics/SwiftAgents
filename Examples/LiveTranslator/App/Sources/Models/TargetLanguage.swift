import Foundation

/// Languages the user can pick as the *output* of translation. The model
/// auto-detects the source language, so the only choice is what to listen
/// in. Kept to a short list matching the README; the model itself supports
/// many more output languages.
enum TargetLanguage: String, CaseIterable, Identifiable {
    case german = "de"
    case english = "en"

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
            case .german: return "German"
            case .english: return "English"
        }
    }

    /// Shown in the picker as a compact chip.
    var flag: String {
        switch self {
            case .german: return "🇩🇪"
            case .english: return "🇺🇸"
        }
    }
}
