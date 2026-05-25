//
//  String+ModelName.swift
//  SwiftAgents
//

import Foundation

extension String {
    /// Returns the model name with any `provider/` prefix removed.
    ///
    /// SwiftAgents accepts model identifiers in two shapes:
    /// - `"openai/gpt-4o"`, `"anthropic/claude-opus-4-7"` (explicit provider)
    /// - `"gpt-4o"`, `"claude-opus-4-7"` (provider inferred from the name)
    ///
    /// The provider registry uses the prefix to pick the right API; the API
    /// itself wants the bare model name. This helper does the second step.
    var modelNameWithoutProviderPrefix: String {
        guard let slashIdx = firstIndex(of: "/") else { return self }
        return String(self[index(after: slashIdx)...])
    }

    /// Returns the provider name implied by this model identifier, using the
    /// same rules as `Providers.shared.api(for:)`. Used to label trace
    /// workflows so you can tell on the dashboard which provider served the
    /// run.
    ///
    /// Examples:
    /// - `"anthropic/claude-haiku-4-5"` → `"anthropic"`
    /// - `"lmstudio/google/gemma-4-26b-a4b"` → `"lmstudio"`
    /// - `"gpt-4o"` → `"openai"`
    /// - `"claude-opus-4-7"` → `"anthropic"` (inferred from the model name)
    /// - `"gemini-1.5-pro"` → `"google"`
    var inferredProviderName: String {
        let rawProvider: String
        if let slashIdx = firstIndex(of: "/") {
            rawProvider = String(self[..<slashIdx]).lowercased()
        } else {
            rawProvider = "openai"
        }
        let lowered = lowercased()
        if rawProvider == "openai", lowered.contains("gemini") { return "google" }
        if rawProvider == "openai", lowered.contains("claude") { return "anthropic" }
        if rawProvider == "gemini" { return "google" }
        if rawProvider == "claude" { return "anthropic" }
        return rawProvider
    }
}
