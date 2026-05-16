//
//  ChatCompletionRequest.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 08.05.23.
//

import Foundation
import SwiftMCP

/// Represents a chat completion request to the OpenAI API.
public struct ChatCompletionRequest: Codable, Sendable {
	/// The ID of the model to use for generating the response.
	public let model: String

	/// A list of messages describing the conversation so far.
	public let messages: [ChatMessage]

	/// The local functions GPT can call.
	public var tools: [ToolDescription]?

	/// Tool selection configuration
	public let toolChoice: ToolChoice?

	/// The number of chat completion choices to generate for each input message. (Optional, defaults to 1)
	public let n: Int?

	/// If set, partial message deltas will be sent, like in ChatGPT. (Optional, defaults to false)
	public let stream: Bool?

	/// Options for streaming response. Only set this when you set stream: true. (Optional)
	public var streamOptions: StreamOptions?

	/// What sampling temperature to use, between 0 and 2. Higher values like 0.8 will make the output more random, while lower values like 0.2 will make it more focused and deterministic. (Optional, defaults to 1)
	public let temperature: Double?

	/// Up to 4 sequences where the API will stop generating further tokens. (Optional)
	public let stop: [String]?

	/// Whether or not to store the output of this chat completion request for use in our model distillation or evals products.
	public let store: Bool?

	/// The maximum number of tokens to generate in the chat completion. (Optional)
	public let maxCompletionTokens: Int?

	/// Optional metadata to store in the request
	public var metadata: [String: String]?

	public let parallelToolCalls: Bool?

	/// Number between -2.0 and 2.0. Positive values penalize new tokens based on whether they appear in the text so far. (Optional, defaults to 0)
	public let presencePenalty: Double?

	/// The format that the model must output. (Optional, defaults to .text)
	public var responseFormat: ResponseFormat?

	/// Number between -2.0 and 2.0. Positive values penalize new tokens based on their existing frequency in the text so far. (Optional, defaults to 0)
	public let frequencyPenalty: Double?

	/// Modify the likelihood of specified tokens appearing in the completion. (Optional)
	public let logitBias: [String: Int]?

	/// A unique identifier representing your end-user, which can help OpenAI to monitor and detect abuse. (Optional)
	public let user: String?

	// MARK: - Enums

	/// Enum representing the response format.
	public enum ResponseFormat: Codable, Sendable {
		case text
		case json
		case jsonSchema(JSONSchemaFormat)

		enum CodingKeys: String, CodingKey {
			case type
			case jsonSchema = "json_schema"
		}

		public func encode(to encoder: Encoder) throws {
			var container = encoder.container(keyedBy: CodingKeys.self)
			switch self {
			case .text:
				try container.encode("text", forKey: .type)
			case .json:
				try container.encode("json_object", forKey: .type)
			case .jsonSchema(let schemaFormat):
				try container.encode("json_schema", forKey: .type)
				try container.encode(schemaFormat, forKey: .jsonSchema)
			}
		}

		public init(from decoder: Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			let type = try container.decode(String.self, forKey: .type)
			switch type {
			case "text":
				self = .text
			case "json_object":
				self = .json
			case "json_schema":
				let jsonSchemaFormat = try container.decode(JSONSchemaFormat.self, forKey: .jsonSchema)
				self = .jsonSchema(jsonSchemaFormat)
			default:
				throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Invalid response format type")
			}
		}
	}

	/// Enum representing the streaming options.
	public enum StreamOptions: Codable, Sendable {
		case includeUsage(Bool)

		enum CodingKeys: String, CodingKey {
			case includeUsage = "include_usage"
		}

		public func encode(to encoder: Encoder) throws {
			var container = encoder.container(keyedBy: CodingKeys.self)
			switch self {
			case .includeUsage(let value):
				try container.encode(value, forKey: .includeUsage)
			}
		}

		public init(from decoder: Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			if let includeUsage = try container.decodeIfPresent(Bool.self, forKey: .includeUsage) {
				self = .includeUsage(includeUsage)
			} else {
				throw DecodingError.dataCorruptedError(forKey: .includeUsage, in: container, debugDescription: "Invalid stream options")
			}
		}
	}
}

extension ChatCompletionRequest {
	enum CodingKeys: String, CodingKey {
		case model
		case messages
		case tools
		case toolChoice
		case n
		case stream
		case streamOptions
		case temperature
		case stop
		case store
		case maxCompletionTokens
		case metadata
		case parallelToolCalls
		case presencePenalty
		case responseFormat
		case frequencyPenalty
		case logitBias
		case user
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(model, forKey: .model)
		try container.encode(messages, forKey: .messages)
		try container.encodeIfPresent(tools, forKey: .tools)
		try container.encodeIfPresent(toolChoice, forKey: .toolChoice)
		try container.encodeIfPresent(n, forKey: .n)
		try container.encodeIfPresent(stream, forKey: .stream)
		try container.encodeIfPresent(streamOptions, forKey: .streamOptions)
		try container.encodeIfPresent(temperature, forKey: .temperature)
		try container.encodeIfPresent(stop, forKey: .stop)
		try container.encodeIfPresent(store, forKey: .store)
		try container.encodeIfPresent(maxCompletionTokens, forKey: .maxCompletionTokens)
		try container.encodeIfPresent(metadata, forKey: .metadata)
		try container.encodeIfPresent(parallelToolCalls, forKey: .parallelToolCalls)
		try container.encodeIfPresent(presencePenalty, forKey: .presencePenalty)
		try container.encodeIfPresent(responseFormat, forKey: .responseFormat)
		try container.encodeIfPresent(frequencyPenalty, forKey: .frequencyPenalty)
		try container.encodeIfPresent(logitBias, forKey: .logitBias)
		try container.encodeIfPresent(user, forKey: .user)
	}
}
