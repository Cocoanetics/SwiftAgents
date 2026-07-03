import Foundation
import JSONFoundation

public extension OutputItem {
    /// A function tool call.
    struct FunctionCall: Codable, Sendable {
        /// The unique ID of the function tool call.
        public let id: String

        /// The unique ID for the function call, to be used when sending back results.
        public let callId: String

        /// The name of the function to run.
        public let name: String

        /// A JSON string of the arguments to pass to the function.
        public let arguments: String

        /// The status of the item.
        public let status: ResponseStatus?

        private enum CodingKeys: String, CodingKey {
            case id
            case callId
            case name
            case arguments
            case status
        }

        public init(
            id: String,
            callId: String,
            name: String,
            arguments: String,
            status: ResponseStatus?
        ) {
            self.id = id
            self.callId = callId
            self.name = name
            self.arguments = arguments
            self.status = status
        }

        public func argumentsDictionary() throws -> [String: JSONValue] {
            try arguments.functionArgumentsDictionary()
        }
    }
}
