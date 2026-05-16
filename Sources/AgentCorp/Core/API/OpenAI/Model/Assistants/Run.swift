//
//  Run.swift
//
//
//  Created by Oliver Drobnik on 03.05.24.
//

import Foundation

/// Represents an execution run on a thread.
public struct Run: Codable 
{
	/// The identifier, which can be referenced in API endpoints.
	public let id: String
	
	/// The object type, which is always thread.run.
	public let object: String
	
	/// The Unix timestamp (in seconds) for when the run was created.
	public let createdAt: Date
	
	/// The ID of the thread that was executed on as a part of this run.
	public let threadId: String
	
	/// The ID of the assistant used for execution of this run.
	public let assistantId: String
	
	/// The status of the run.
	public let status: Status
	
	/// Details on the action required to continue the run.
	public let requiredAction: RequiredAction?
	
	/// The last error associated with this run.
	public let lastError: LastError?
	
	/// The Unix timestamp (in seconds) for when the run will expire.
	public let expiresAt: Date?
	
	/// The Unix timestamp (in seconds) for when the run was started.
	public let startedAt: Date?
	
	/// The Unix timestamp (in seconds) for when the run was cancelled.
	public let cancelledAt: Date?
	
	/// The Unix timestamp (in seconds) for when the run failed.
	public let failedAt: Date?
	
	/// The Unix timestamp (in seconds) for when the run was completed.
	public let completedAt: Date?
	
	/// Details on why the run is incomplete.
	public let incompleteDetails: IncompleteDetails?
	
	/// The model that the assistant used for this run.
	public let model: String
	
	/// The instructions that the assistant used for this run.
	public let instructions: String?
	
	/// The list of tools that the assistant used for this run.
	public let tools: [ToolDescription]
	
	/// Set of 16 key-value pairs that can be attached to an object.
	public let metadata: [String: String]
	
	/// Usage statistics related to the run.
	public let usage: Usage?
	
	/// The sampling temperature used for this run.
	public let temperature: Double
	
	/// The nucleus sampling value used for this run.
	public let topP: Double
	
	/// If set, partial message deltas will be sent, like in ChatGPT.
	public let stream: Bool?
	
	/// The maximum number of prompt tokens specified to have been used over the course of the run.
	public let maxPromptTokens: Int?
	
	/// The maximum number of completion tokens specified to have been used over the course of the run.
	public let maxCompletionTokens: Int?
	
	/// Controls for how a thread will be truncated prior to the run.
	public let truncationStrategy: TruncationStrategy
	
	/// Controls which (if any) tool is called by the model.
	public let toolChoice: ToolChoice
	
	/// Specifies the format that the model must output.
	public let responseFormat: ResponseFormat
	
	
	// MARK: - Structs
	
	public enum Status: String, Codable
	{
		case queued
		case inProgress = "in_progress"
		case requiresAction = "requires_action"
		case cancelling
		case cancelled
		case failed
		case completed
		case expired
	}
	
	/// Details on the action required to continue the run.
	public struct RequiredAction: Codable {
		public let type: String
		public let submitToolOutputs: SubmitToolOutputs?
	}
	
	/// Represents the details on the tool outputs needed for this run to continue.
	public struct SubmitToolOutputs: Codable {
		public let toolCalls: [ToolCall]
	}
}


/// Represents the parameters for creating a new run.
public struct RunCreation: Codable {
	/// The ID of the assistant to use to execute this run.
	public let assistantId: String
	
	/// Optional: The ID of the Model to be used to execute this run. If provided, it will override the model associated with the assistant.
	public let model: String?
	
	/// Optional: Overrides the instructions of the assistant. Useful for modifying the behavior on a per-run basis.
	public let instructions: String?
	
	/// Optional: Appends additional instructions at the end of the instructions for the run. Useful for modifying the behavior on a per-run basis without overriding other instructions.
	public let additionalInstructions: String?
	
	/// Optional: Adds additional messages to the thread before creating the run.
	public let additionalMessages: [MessageCreation]?
	
	/// Optional: Override the tools the assistant can use for this run. Useful for modifying the behavior on a per-run basis.
	public let tools: [ToolDescription]?
	
	/// Set of 16 key-value pairs that can be attached to an object.
	public let metadata: [String: String]?
	
	/// Optional: The sampling temperature used for this run. Defaults to 1.
	public let temperature: Double?
	
	/// Optional: The nucleus sampling value used for this run. Defaults to 1.
	public let topP: Double?
	
	/// If set, partial message deltas will be sent, like in ChatGPT.
	public let stream: Bool?
	
	/// Optional: The maximum number of prompt tokens that may be used over the course of the run.
	public let maxPromptTokens: Int?
	
	/// Optional: The maximum number of completion tokens that may be used over the course of the run.
	public let maxCompletionTokens: Int?
	
	/// Optional: Controls for how a thread will be truncated prior to the run.
	public let truncationStrategy: TruncationStrategy?
	
	/// Optional: Controls which (if any) tool is called by the model.
	public let toolChoice: ToolChoice?
	
	/// Optional: Specifies the format that the model must output.
	public let responseFormat: ResponseFormat?
}

/// Represents the choice of tool to be called by the model.
public enum ToolChoice: Codable, Sendable
{
	/// The model will not call any tools and instead generates a message.
	case none
	
	/// The model can pick between generating a message or calling one or more tools.
	case auto
	
	/// The model must call one or more tools before responding to the user.
	case required
	
	/// Specifies a tool the model should use.
	case tool(ToolChoiceDescription)
	
	// MARK: - Codable

	public init(from decoder: Decoder) throws {
		if let container = try? decoder.singleValueContainer() {
			// Attempt to decode as a string
			if let stringValue = try? container.decode(String.self) {
				switch stringValue {
				case "none":
					self = .none
				case "auto":
					self = .auto
				case "required":
					self = .required
				default:
					throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid tool choice string: \(stringValue)")
				}
				return
			}
		}
		
		// If decoding as a string fails, attempt to decode as a dictionary
		let toolDescription = try ToolChoiceDescription(from: decoder)
		self = .tool(toolDescription)
	}


	public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		
		switch self {
			case .none:
				try container.encode("none")
			case .auto:
				try container.encode("auto")
			case .required:
				try container.encode("required")
				
			case .tool(let toolDescription):
				try toolDescription.encode(to: encoder)
		}
	}
}
