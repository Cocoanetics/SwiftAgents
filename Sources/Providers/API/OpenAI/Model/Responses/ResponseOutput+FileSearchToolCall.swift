extension ResponseOutput {
    /// The results of a file search tool call.
    public struct FileSearchToolCall: Codable, Sendable {
        /// The unique ID of the file search tool call.
        public let id: String
        
        /// The queries used to search for files.
        public let queries: [String]
        
        /// The status of the file search tool call.
        public let status: Response.ToolCallStatus
        
        /// The type of the file search tool call. Always file_search_call.
        public let type: Response.FileSearchCallType
        
        /// The results of the file search tool call.
        public let results: [FileSearchResult]?
    }
    
    /// A result from a file search.
    public struct FileSearchResult: Codable, Sendable {
        // Add properties based on API documentation when available
    }
} 
