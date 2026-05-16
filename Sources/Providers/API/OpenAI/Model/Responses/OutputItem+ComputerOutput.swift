public extension OutputItem {
    /// A computer tool call.
    struct ComputerOutput: Codable, Sendable {
        /// The unique ID of the computer call.
        public let id: String

        /// The action to perform.
        public let action: ComputerAction

        /// The status of the item.
        public let status: ResponseStatus?

        /// The pending safety checks for the computer call.
        public let pendingSafetyChecks: [String]?
    }
}
