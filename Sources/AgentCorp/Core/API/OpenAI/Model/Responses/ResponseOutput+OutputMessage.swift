extension ResponseOutput {
    /// An output message from the model.
    public struct OutputMessage: Codable, Sendable {
        /// The content of the output message.
        public let content: [ContentItem]
        
        /// The unique ID of the output message.
        public let id: String
        
        /// The role of the output message. Always assistant.
        public let role: Role
        
        /// The status of the message input.
        public let status: ResponseStatus

		/// Whether this assistant message is commentary or the final answer.
		public let phase: Response.Phase?
        
        /// The type of the output message. Always message.
        public let type: Response.MessageItemType
    }
}
