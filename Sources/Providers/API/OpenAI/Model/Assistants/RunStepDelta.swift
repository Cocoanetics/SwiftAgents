//
//  RunStepDelta.swift
//
//
//  Created by Oliver Drobnik on 04.05.24.
//

import Foundation

/**
 Represents an execution run on a thread.
 
 see also: [Runs API Reference](https://platform.openai.com/docs/api-reference/runs)
 */
public struct RunStepDelta: Codable {
	/// The identifier of the run step delta.
	let id: String

	/// The object type, which is always "thread.run.step.delta".
	let object: String

	/// The delta containing the fields that have changed on the run step.
	let delta: Details

	// MARK: - Structs

	/// Represents the details of the run step delta.
	public struct Details: Codable {
		/// The details of the run step.
		let stepDetails: StepDetails

		/// Represents the details of the run step.
		public struct StepDetails: Codable {
			/// The type of the run step delta.
			let type: String

			/// Details of the tool calls made during the run step.
			let toolCalls: [ToolCall]

			enum CodingKeys: String, CodingKey {
				case type
				case toolCalls
			}
		}
	}

	/// Represents a tool call.
	///
	/// - Note: `id`, `name` and `output` might be `nil`
	public struct ToolCall: Codable {
		/// The identifier of the tool call.
		let id: String?

		/// The type of tool call.
		let type: String

		/// Details of a file search tool call.
		let fileSearch: [String: String]?

		/// Details of a function tool call.
		let function: FunctionCall?

		/// Details of a code interpreter tool call.
		let codeInterpreter: CodeInterpreter?

		enum CodingKeys: String, CodingKey {
			case id
			case type
			case fileSearch
			case function
			case codeInterpreter
		}
	}

	/// Represents the details of a function tool call.
	public struct FunctionCall: Codable {
		/// The name of the function.
		let name: String?

		/// The arguments passed to the function.
		let arguments: String

		/// The output of the function.
		let output: String?
	}

	/// Represents the details of a code interpreter tool call.
	public struct CodeInterpreter: Codable {
		/// The input to the code interpreter.
		let input: String?

		/// The outputs from the code interpreter.
		let outputs: [Output]?

		enum CodingKeys: String, CodingKey {
			case input
			case outputs
		}

		/// Represents the output of a code interpreter tool call.
		public struct Output: Codable {
			/// The type of the output.
			let type: String

			/// The image output from the code interpreter tool call.
			let image: ImageFile?

			/// The log output from the code interpreter tool call.
			let logs: String?

			enum CodingKeys: String, CodingKey {
				case type
				case image
				case logs
			}
		}
	}
}
