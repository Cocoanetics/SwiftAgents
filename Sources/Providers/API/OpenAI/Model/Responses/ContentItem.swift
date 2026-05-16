//
//  ContentItem.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 24.04.25.
//

import Foundation

/// Represents a content item in a message output.
public enum ContentItem: Codable, Sendable
{
    /// A text output from the model.
    case outputText(OutputText)
    
    /// A refusal from the model.
    case refusal(Refusal)

    /// Reasoning text from a thinking model.
    case reasoningText(ReasoningText)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case annotations
        case logprobs
        case refusal
		case encryptedContent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "output_text":
            let text = try container.decode(String.self, forKey: .text)
            let annotations = try container.decode([OutputItem.MessageOutput.Annotation].self, forKey: .annotations)
			let logprobs = try container.decodeIfPresent([OutputText.Logprob].self, forKey: .logprobs)
            self = .outputText(OutputText(text: text, annotations: annotations, logprobs: logprobs))
        case "refusal":
            let refusal = try container.decode(String.self, forKey: .refusal)
            self = .refusal(Refusal(refusal: refusal))
        case "reasoning_text":
            let text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
			let encryptedContent = try container.decodeIfPresent(String.self, forKey: .encryptedContent)
            self = .reasoningText(ReasoningText(text: text, encryptedContent: encryptedContent))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown content type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .outputText(let output):
            try container.encode("output_text", forKey: .type)
            try container.encode(output.text, forKey: .text)
            try container.encode(output.annotations, forKey: .annotations)
        case .refusal(let refusal):
            try container.encode("refusal", forKey: .type)
            try container.encode(refusal.refusal, forKey: .refusal)
        case .reasoningText(let reasoning):
            try container.encode("reasoning_text", forKey: .type)
            try container.encode(reasoning.text, forKey: .text)
			try container.encodeIfPresent(reasoning.encryptedContent, forKey: .encryptedContent)
        }
    }

    /// Reasoning text content from a thinking model.
    public struct ReasoningText: Codable, Sendable {
        public let text: String
		public let encryptedContent: String?

		public init(text: String, encryptedContent: String? = nil) {
			self.text = text
			self.encryptedContent = encryptedContent
		}
    }
} 
