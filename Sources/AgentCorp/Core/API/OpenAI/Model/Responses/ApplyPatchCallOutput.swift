import Foundation

/// Represents an apply_patch tool call from the model.
public struct ApplyPatchCallOutput: Codable, Sendable {
	/// The unique ID of the output item.
	public let id: String

	/// The call ID used for sending back results.
	public let callId: String?

	/// The operation requested by the model.
	public let operation: Operation

	/// The status of the call.
	public let status: Response.ToolCallStatus?

	/// The call ID to use for the output (prefers callId, falls back to id).
	public var resolvedCallId: String { callId ?? id }

	// MARK: - Operation

	public struct Operation: Codable, Sendable {
		/// The type of patch operation.
		public let type: OperationType

		/// The file path for the operation.
		public let path: String

		/// The V4A diff to apply (nil for delete_file).
		public let diff: String?
	}

	/// The type of apply_patch operation.
	public enum OperationType: String, Codable, Sendable {
		case createFile = "create_file"
		case updateFile = "update_file"
		case deleteFile = "delete_file"
	}
}

/// The output to send back after applying a patch operation.
public struct ApplyPatchCallOutputResult: Codable, Sendable {
	/// The ID of the apply_patch call this output is for.
	public let callId: String

	/// The output message describing what happened.
	public let output: String

	/// The status: "completed" or "failed".
	public let status: Response.ApplyPatchResultStatus

	/// Always "apply_patch_call_output".
	public let type: Response.ApplyPatchCallOutputType

	public init(callId: String, output: String, status: Response.ApplyPatchResultStatus = .completed) {
		self.callId = callId
		self.output = output
		self.status = status
		self.type = .applyPatchCallOutput
	}

	private enum CodingKeys: String, CodingKey {
		case callId = "call_id"
		case output
		case status
		case type
	}
}
