extension OutputItem {
    /// A description of the chain of thought used by a reasoning model.
    public struct ReasoningOutput: Sendable {
        /// The unique identifier of the reasoning content.
        public let id: String

        /// The status of the item.
        public let status: ResponseStatus?

        /// Reasoning text contents.
        public let summary: [SummaryItem]
    }
}

extension OutputItem.ReasoningOutput: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, status, summary, content
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        status = try container.decodeIfPresent(ResponseStatus.self, forKey: .status)

        // OpenAI uses "summary", LM Studio uses "content"
        if let summary = try? container.decode([OutputItem.SummaryItem].self, forKey: .summary) {
            self.summary = summary
        } else if let content = try? container.decode([ContentItem].self, forKey: .content) {
            // Convert reasoning_text content items to summary items
            self.summary = content.compactMap { item in
                if case .reasoningText(let reasoning) = item {
                    return OutputItem.SummaryItem(type: "summary_text", text: reasoning.text)
                }
                return nil
            }
        } else {
            self.summary = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encode(summary, forKey: .summary)
    }
}
