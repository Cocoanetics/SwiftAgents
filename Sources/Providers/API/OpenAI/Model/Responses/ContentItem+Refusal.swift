import Foundation

extension ContentItem {
    /// A refusal from the model.
    public struct Refusal: Codable, Sendable {
        /// The refusal explanation from the model.
        public let refusal: String
    }
} 
