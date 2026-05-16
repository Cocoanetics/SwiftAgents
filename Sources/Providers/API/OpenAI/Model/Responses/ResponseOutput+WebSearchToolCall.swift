extension ResponseOutput {
    /// The results of a web search tool call.
    public struct WebSearchToolCall: Codable, Sendable {
        /// The unique ID of the web search tool call.
        public let id: String

        /// The status of the web search tool call.
        public let status: Response.ToolCallStatus

        /// The type of the web search tool call. Always web_search_call.
        public let type: Response.WebSearchCallType

        // Add other properties based on API documentation when available
    }
}
