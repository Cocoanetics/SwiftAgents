public extension OutputItem {
    /// A description of the chain of thought used by a reasoning model.
    struct ReasoningOutput: Sendable {
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

        // OpenAI uses "summary"; LM Studio uses "content"; LM Studio
        // ALSO sends `summary: []` (empty) alongside the rich `content`,
        // so an empty summary should fall through to content rather than
        // declaring victory and leaving the rich reasoning unused.
        let decodedSummary = try? container.decode([OutputItem.SummaryItem].self, forKey: .summary)
        if let decodedSummary, !decodedSummary.isEmpty {
            summary = decodedSummary
        } else if let content = try? container.decode([ContentItem].self, forKey: .content) {
            // Convert reasoning_text content items to summary items
            summary = content.compactMap { item in
                if case let .reasoningText(reasoning) = item {
                    return OutputItem.SummaryItem(type: "summary_text", text: reasoning.text)
                }
                return nil
            }
        } else {
            summary = decodedSummary ?? []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encode(summary, forKey: .summary)
    }
}
