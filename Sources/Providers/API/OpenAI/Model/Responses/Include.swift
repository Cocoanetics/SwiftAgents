//
//  Include.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 24.04.25.
//

import Foundation

/// Specifies additional output data to include in the model response.
public enum Include: String, Codable, Sendable {
    /// Include the search results of the file search tool call.
    case fileSearchResults = "file_search_call.results"

	/// Include web search tool results.
	case webSearchResults = "web_search_call.results"

	/// Include web search source metadata.
	case webSearchSources = "web_search_call.action.sources"

    /// Include image urls from the input message.
    case messageInputImage = "message.input_image.image_url"

    /// Include image urls from the computer call output.
    case computerCallOutput = "computer_call_output.output.image_url"

	/// Include code interpreter outputs.
	case codeInterpreterOutputs = "code_interpreter_call.outputs"

	/// Include encrypted reasoning content for stateless follow-up requests.
	case reasoningEncryptedContent = "reasoning.encrypted_content"

	/// Include token logprobs for assistant output text.
	case messageOutputTextLogprobs = "message.output_text.logprobs"
}
