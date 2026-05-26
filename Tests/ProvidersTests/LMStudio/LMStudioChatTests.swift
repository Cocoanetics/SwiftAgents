//
//  LMStudioChatTests.swift
//  ProvidersTests
//
//  Offline tests for the LM Studio provider's policy + registry wiring.
//  All wire-level behaviour comes straight from `OpenAI` since
//  `LMStudio` is an OpenAI subclass pointed at the LM Studio server's
//  OpenAI-compat endpoints (`/v1/responses` and `/v1/chat/completions`).
//  Live interaction is covered by the suites under
//  `LMStudioIntegrationTests`, `LMStudioStructuredOutputTests`,
//  `LMStudioToolCallTests`, `LMStudioImageInputTests`, and
//  `LMStudioStreamingTests`.
//

import Foundation
@testable import Providers
import Testing

struct LMStudioChatTests {
    @Test("LM Studio inherits from OpenAI so all wire methods come for free")
    func lmStudioIsOpenAISubclass() {
        let lmstudio = LMStudio()
        #expect(lmstudio is OpenAI, "LMStudio must extend OpenAI to share createResponse / createChatCompletion")
    }

    @Test("LM Studio declares lmStudioOpenAICompat state policy")
    func policyIsLMStudioOpenAICompat() {
        let lmstudio = LMStudio()
        // Stateful path supported (LM Studio implements OpenAI Responses
        // API including `previous_response_id` chaining), but response
        // ids belong to the local server — not resolvable by OpenAI's
        // trace dashboard, so spans must export as GenerationSpanData.
        #expect(lmstudio.statePolicy.supportsServerSideHistory == true)
        #expect(lmstudio.statePolicy.responseIdsAreOpenAIRoutable == false)
    }

    @Test("OpenAI declares openAIResponses state policy")
    func policyIsOpenAIResponses() {
        let openAI = OpenAI(apiKey: "test")
        #expect(openAI.statePolicy.supportsServerSideHistory == true)
        #expect(openAI.statePolicy.responseIdsAreOpenAIRoutable == true)
    }

    @Test("Other providers default to stateless policy")
    func defaultPolicyIsStateless() {
        let anthropic = Anthropic(apiKey: "test")
        #expect(anthropic.statePolicy.supportsServerSideHistory == false)
        #expect(anthropic.statePolicy.responseIdsAreOpenAIRoutable == false)
    }

    @Test("Providers registry returns an LMStudio instance for the lmstudio name")
    func providersReturnsLMStudio() async throws {
        let providers = Providers()
        let api = try await providers.api(for: "lmstudio/google/gemma-4-26b-a4b")
        #expect(api is LMStudio)
    }
}
