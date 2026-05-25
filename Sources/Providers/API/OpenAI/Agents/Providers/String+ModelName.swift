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
}
