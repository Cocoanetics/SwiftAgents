import Foundation

public struct WebSearchTool: Codable, Sendable {
    /// The type of the web search tool.
    public let type: String
    /// High level guidance for the amount of context window space to use for the search.
    public let searchContextSize: String?
    /// Approximate location parameters for the search.
    public let userLocation: UserLocation?
    public init(type: String, searchContextSize: String?, userLocation: UserLocation?) {
        self.type = type
        self.searchContextSize = searchContextSize
        self.userLocation = userLocation
    }
}
