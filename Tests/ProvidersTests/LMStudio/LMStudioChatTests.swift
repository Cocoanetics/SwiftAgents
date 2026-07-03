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
import Tracing
@testable import Providers
@testable import Agents
import SwiftMCP
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
        let openAI = OpenAI(credential: Credential.bearer("test"))
        #expect(openAI.statePolicy.supportsServerSideHistory == true)
        #expect(openAI.statePolicy.responseIdsAreOpenAIRoutable == true)
    }

    @Test("Other providers default to stateless policy")
    func defaultPolicyIsStateless() {
        let anthropic = Anthropic(credential: Credential.apiKey("test"))
        #expect(anthropic.statePolicy.supportsServerSideHistory == false)
        #expect(anthropic.statePolicy.responseIdsAreOpenAIRoutable == false)
    }

    @Test("Providers registry returns an LMStudio instance for the lmstudio name")
    func providersReturnsLMStudio() async throws {
        let providers = ProviderRegistry()
        let api = try await providers.api(for: "lmstudio/google/gemma-4-26b-a4b")
        #expect(api is LMStudio)
    }

    @Test("shouldUseStatefulPath routes structured output by state policy")
    func statefulPathRouting() {
        let schemaOutput = TextFormat.jsonSchema(JSONSchemaFormat(name: "test", schema: .string()))

        // LM Studio: stateful for plain text, but `/v1/responses` silently
        // ignores schemas — structured output must fall back to chat
        // completions (the live proof is LMStudioResponsesRoutingLiveTests).
        let lmStudioPolicy = LMStudio().statePolicy
        #expect(Runner.shouldUseStatefulPath(policy: lmStudioPolicy, outputType: .text))
        #expect(!Runner.shouldUseStatefulPath(policy: lmStudioPolicy, outputType: .json))
        #expect(!Runner.shouldUseStatefulPath(policy: lmStudioPolicy, outputType: schemaOutput))

        // OpenAI honors json_schema on the Responses endpoint — stateful
        // for every output type.
        let openAIPolicy = OpenAI(credential: Credential.bearer("test")).statePolicy
        #expect(Runner.shouldUseStatefulPath(policy: openAIPolicy, outputType: .text))
        #expect(Runner.shouldUseStatefulPath(policy: openAIPolicy, outputType: .json))
        #expect(Runner.shouldUseStatefulPath(policy: openAIPolicy, outputType: schemaOutput))

        // Stateless providers never take the stateful path.
        let anthropicPolicy = Anthropic(credential: Credential.apiKey("test")).statePolicy
        #expect(!Runner.shouldUseStatefulPath(policy: anthropicPolicy, outputType: .text))
        #expect(!Runner.shouldUseStatefulPath(policy: anthropicPolicy, outputType: schemaOutput))
    }
}
