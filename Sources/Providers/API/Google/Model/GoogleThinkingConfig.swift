import Foundation

/// Configuration options for Gemini thinking behavior.
public struct GoogleThinkingConfig: Codable, Sendable {
    public enum ThinkingLevel: String, Codable, Sendable {
        case low
        case high
    }

    /// Whether to include summarized thoughts in the response.
    public let includeThoughts: Bool?

    /// Controls the model's reasoning depth.
    public let thinkingLevel: ThinkingLevel?

    /// Controls thinking token budget for 2.5 models.
    public let thinkingBudget: Int?

    public init(includeThoughts: Bool? = nil, thinkingLevel: ThinkingLevel? = nil, thinkingBudget: Int? = nil) {
        self.includeThoughts = includeThoughts
        self.thinkingLevel = thinkingLevel
        self.thinkingBudget = thinkingBudget
    }
}
