import Foundation

/// Request payload for Gemini's native `models.generateContent` endpoint.
/// Documentation: https://ai.google.dev/api/rest/v1/models/generateContent
public struct GoogleGenerateContentRequest: Codable, Sendable {
	public typealias Content = GoogleGenerateContent.Content
	public typealias Part = GoogleGenerateContent.Part

	public struct Tool: Codable, Sendable {
		public let functionDeclarations: [FunctionDeclaration]?

		public init(functionDeclarations: [FunctionDeclaration]? = nil) {
			self.functionDeclarations = functionDeclarations
		}
	}

	public struct FunctionDeclaration: Codable, Sendable {
		public let name: String
		public let description: String?
		public let parameters: Parameters?

		public init(name: String, description: String? = nil, parameters: Parameters? = nil) {
			self.name = name
			self.description = description
			self.parameters = parameters
		}
	}

	public let contents: [Content]
	public let systemInstruction: Content?
	public let tools: [Tool]?

	public struct GenerationConfig: Codable, Sendable {
		public let thinkingConfig: ThinkingConfig?
		public let imageConfig: ImageConfig?
		public let responseModalities: [String]?
		public let temperature: Double?

		public init(thinkingConfig: ThinkingConfig? = nil, imageConfig: ImageConfig? = nil, responseModalities: [String]? = nil, temperature: Double? = nil) {
			self.thinkingConfig = thinkingConfig
			self.imageConfig = imageConfig
			self.responseModalities = responseModalities
			self.temperature = temperature
		}
	}

	public struct ThinkingConfig: Codable, Sendable {
		public typealias ThinkingLevel = GoogleThinkingConfig.ThinkingLevel

		public let includeThoughts: Bool?
		public let thinkingLevel: ThinkingLevel?
		public let thinkingBudget: Int?

		public init(includeThoughts: Bool? = nil, thinkingLevel: ThinkingLevel? = nil, thinkingBudget: Int? = nil) {
			self.includeThoughts = includeThoughts
			self.thinkingLevel = thinkingLevel
			self.thinkingBudget = thinkingBudget
		}

		public init(from config: GoogleThinkingConfig) {
			self.includeThoughts = config.includeThoughts
			self.thinkingLevel = config.thinkingLevel
			self.thinkingBudget = config.thinkingBudget
		}
	}

	public struct ImageConfig: Codable, Sendable {
		public let aspectRatio: String?
		public let imageSize: String?

		public init(aspectRatio: String? = nil, imageSize: String? = nil) {
			self.aspectRatio = aspectRatio
			self.imageSize = imageSize
		}
	}

	public let generationConfig: GenerationConfig?

	public init(contents: [Content],
		 systemInstruction: Content?,
		 tools: [Tool]?,
		 generationConfig: GenerationConfig? = nil) {
		self.contents = contents
		self.systemInstruction = systemInstruction
		self.tools = tools
		self.generationConfig = generationConfig
	}
}
