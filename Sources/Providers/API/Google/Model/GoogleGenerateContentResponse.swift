import Foundation
import SwiftMCP

/// Response payload from Gemini's `models.generateContent` endpoint.
/// Schema reference: https://ai.google.dev/api/rest/v1/GenerateContentResponse
public struct GoogleGenerateContentResponse: Codable {
	public typealias Content = GoogleGenerateContent.Content
	public typealias Part = GoogleGenerateContent.Part

	/// Represents one entry in `candidates[]`. See https://ai.google.dev/api/rest/v1/Candidat
	public struct Candidate: Codable {
		public let content: Content?
		public let finishReason: String?
		public let index: Int?
		public let avgLogprobs: Double?
		public let logprobsResult: LogprobsResult?
		public let safetyRatings: [SafetyRating]?
		public let citationMetadata: CitationMetadata?
		public let finishMessage: String?
	}

	public let candidates: [Candidate]
	public let modelVersion: String?
	public let createTime: String?
	public let responseId: String?
	public let promptFeedback: PromptFeedback?
	public let usageMetadata: UsageMetadata?

	public struct LogprobsResult: Codable {
		let topCandidates: [TopCandidates]?
		let chosenCandidates: [TopCandidateToken]?

		public struct TopCandidates: Codable {
			let candidates: [TopCandidateToken]?
		}

		public struct TopCandidateToken: Codable {
			let token: String?
			let tokenId: Int?
			let logProbability: Double?
		}
	}

	public struct SafetyRating: Codable {
		let category: String?
		let probability: String?
		let severity: String?
		let blocked: Bool?
	}

	public struct CitationMetadata: Codable {
		let citations: [Citation]?

		struct Citation: Codable {
			let startIndex: Int?
			let endIndex: Int?
			let uri: String?
			let title: String?
		}
	}

	public struct PromptFeedback: Codable {
		let blockReason: String?
		let safetyRatings: [SafetyRating]?
		let blockReasonMessage: String?
	}

	public struct UsageMetadata: Codable {
		public let promptTokenCount: Int?
		public let candidatesTokenCount: Int?
		public let totalTokenCount: Int?
		public let toolUsePromptTokenCount: Int?
		public let thoughtsTokenCount: Int?
		public let cachedContentTokenCount: Int?
		public let promptTokensDetails: [TokenDetails]?
		public let candidatesTokensDetails: [TokenDetails]?

		public init(
			promptTokenCount: Int? = nil,
			candidatesTokenCount: Int? = nil,
			totalTokenCount: Int? = nil,
			toolUsePromptTokenCount: Int? = nil,
			thoughtsTokenCount: Int? = nil,
			cachedContentTokenCount: Int? = nil,
			promptTokensDetails: [TokenDetails]? = nil,
			candidatesTokensDetails: [TokenDetails]? = nil
		) {
			self.promptTokenCount = promptTokenCount
			self.candidatesTokenCount = candidatesTokenCount
			self.totalTokenCount = totalTokenCount
			self.toolUsePromptTokenCount = toolUsePromptTokenCount
			self.thoughtsTokenCount = thoughtsTokenCount
			self.cachedContentTokenCount = cachedContentTokenCount
			self.promptTokensDetails = promptTokensDetails
			self.candidatesTokensDetails = candidatesTokensDetails
		}

		public struct TokenDetails: Codable {
			public let modality: String?
			public let tokenCount: Int?
		}
	}
}
