import Foundation

public extension ContentItem {
    /// A refusal from the model.
    struct Refusal: Codable, Sendable {
        /// The refusal explanation from the model.
        public let refusal: String
    }
}
