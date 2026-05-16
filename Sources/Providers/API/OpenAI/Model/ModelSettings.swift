import Foundation
import SwiftMCP

/// Configuration settings for model behavior and output.
public struct ModelSettings: Codable, Sendable {
    /// Controls randomness in the output. Higher values make output more random.
    public var temperature: Double?

    /// Controls diversity via nucleus sampling. Higher values allow more diverse outputs.
    public var topP: Double?

    /// Penalizes new tokens based on their frequency in the text so far.
    public var frequencyPenalty: Double?

    /// Penalizes new tokens based on whether they appear in the text so far.
    public var presencePenalty: Double?

    /// Controls which (if any) tool is called by the model.
    public var toolChoice: ToolChoice?

    /// Whether to allow parallel tool calls.
    public var parallelToolCalls: Bool?

    /// Controls how the model handles truncation.
	public var truncation: Response.TruncationStrategy?

    /// Maximum number of tokens to generate.
    public var maxCompletionTokens: Int?

    /// Configuration for reasoning models.
    public var reasoning: Reasoning?

    /// Additional metadata for the request.
    public var metadata: [String: String]?

    /// Whether to store the response.
    public var store: Bool?

    /// Whether to include usage information in the response.
    public var includeUsage: Bool?

    /// Additional query parameters.
    public var extraQuery: [String: String]?

    /// Additional body parameters.
    public var extraBody: [String: JSONValue]?

    /// Additional headers.
    public var extraHeaders: [String: String]?

    /// Base URL for the API endpoint.
    public var baseURL: String?

    public init(
        temperature: Double? = nil,
        topP: Double? = nil,
        frequencyPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        toolChoice: ToolChoice? = nil,
        parallelToolCalls: Bool? = nil,
        truncation: Response.TruncationStrategy? = nil,
        maxCompletionTokens: Int? = nil,
        reasoning: Reasoning? = nil,
        metadata: [String: String]? = nil,
        store: Bool? = nil,
        includeUsage: Bool? = nil,
        extraQuery: [String: String]? = nil,
        extraBody: [String: JSONValue]? = nil,
        extraHeaders: [String: String]? = nil,
        baseURL: String? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
        self.truncation = truncation
        self.maxCompletionTokens = maxCompletionTokens
        self.reasoning = reasoning
        self.metadata = metadata
        self.store = store
        self.includeUsage = includeUsage
        self.extraQuery = extraQuery
        self.extraBody = extraBody
        self.extraHeaders = extraHeaders
        self.baseURL = baseURL
    }
}
