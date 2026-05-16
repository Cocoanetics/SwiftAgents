public extension OutputItem {
    /// A function tool call.
    struct FunctionCallOutput: Codable, Sendable {
        /// The unique ID of the function tool call.
        public let id: String

        /// The name of the function to run.
        public let name: String

        /// A JSON string of the arguments to pass to the function.
        public let arguments: String

        /// The status of the item.
        public let status: ResponseStatus?
    }
}
