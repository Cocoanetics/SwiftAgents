import Foundation
import Testing
@testable import AgentCorp

struct GoogleGenerateContentResponseTests {
	@Test("Parses complete GoogleGenerateContentResponse with all usage metadata fields")
	func parsesCompleteResponseWithUsageMetadata() throws {
		let url = try TestResources.url(forResource: "google_generate_content_response", withExtension: "json")
		let data = try Data(contentsOf: url)
		let response = try JSONDecoder().decode(GoogleGenerateContentResponse.self, from: data)
		
		// Verify top-level fields
		#expect(response.modelVersion == "gemini-3-pro-image-preview")
		#expect(response.responseId == "no06aenuMrL6vdIPh7CpqQ8")
		
		// Verify usage metadata exists
		let usageMetadata = try #require(response.usageMetadata, "usageMetadata should be present")
		
		// Verify basic usage counts
		#expect(usageMetadata.promptTokenCount == 375)
		#expect(usageMetadata.candidatesTokenCount == 2162)
		#expect(usageMetadata.totalTokenCount == 2733)
		#expect(usageMetadata.thoughtsTokenCount == 196)
		
		// Verify prompt tokens details
		let promptDetails = try #require(usageMetadata.promptTokensDetails, "promptTokensDetails should be present")
		#expect(promptDetails.count == 2)
		
		let textDetail = promptDetails.first { $0.modality == "TEXT" }
		#expect(textDetail?.tokenCount == 117)
		
		let imageDetail = promptDetails.first { $0.modality == "IMAGE" }
		#expect(imageDetail?.tokenCount == 258)
		
		// Verify candidates tokens details
		let candidatesDetails = try #require(usageMetadata.candidatesTokensDetails, "candidatesTokensDetails should be present")
		#expect(candidatesDetails.count == 1)
		
		let candidateImageDetail = candidatesDetails.first { $0.modality == "IMAGE" }
		#expect(candidateImageDetail?.tokenCount == 2000)
		
		// Verify candidates structure
		#expect(response.candidates.count > 0)
		let candidate = try #require(response.candidates.first, "Should have at least one candidate")
		#expect(candidate.finishReason == "STOP")
		#expect(candidate.index == 0)
		
		// Verify parts structure including thoughtSignature
		let content = try #require(candidate.content, "Candidate should have content")
		#expect(content.parts.count > 0)
		
		// Find part with thoughtSignature
		let partWithSignature = content.parts.first { $0.thoughtSignature != nil }
		#expect(partWithSignature != nil, "Should have at least one part with thoughtSignature")
		#expect(partWithSignature?.thoughtSignature != nil)
	}
}

