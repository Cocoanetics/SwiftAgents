extension ResponseOutput {
    /// A tool call to a computer use tool.
    public struct ComputerToolCall: Codable, Sendable {
        /// The action to perform.
        public let action: ComputerAction
        
        /// An identifier used when responding to the tool call with output.
        public let callId: String
        
        /// The unique ID of the computer call.
        public let id: String
        
        /// The pending safety checks for the computer call.
        public let pendingSafetyChecks: [String]
        
        /// The status of the item.
        public let status: ResponseStatus
        
        /// The type of the computer call. Always computer_call.
        public let type: Response.ComputerCallType
    }
    
    /// An action for a computer tool call.
    public struct ComputerAction: Codable, Sendable {
        // Add properties based on API documentation when available
    }
} 
