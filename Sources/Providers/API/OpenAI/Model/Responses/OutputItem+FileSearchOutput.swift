import Foundation
import SwiftMCP

extension OutputItem {
    /// A file search tool call result.
    public struct FileSearchOutput: Codable, Sendable {
        /// The unique ID of the file search tool call.
        public let id: String

        /// The queries used to search for files.
        public let queries: [String]

        /// The status of the file search tool call.
        public let status: Response.ToolCallStatus?

        /// The results of the file search tool call.
        public let results: [FileSearchResult]?
    }

	public struct FileSearchResult: Codable, Sendable {
		public let attributes: [String: JSONValue]?
		public let fileId: String?
		public let filename: String?
		public let score: Double?
		public let text: String?
	}
}
