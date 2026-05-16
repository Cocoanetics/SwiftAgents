import Foundation

public struct FileSearchTool: Codable, Sendable {
    /// The vector store IDs to search in.
    public let vectorStoreIds: [String]
    public init(vectorStoreIds: [String]) {
        self.vectorStoreIds = vectorStoreIds
    }
}
