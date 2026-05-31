//
//  CompactResponseTests.swift
//  SwiftAgents
//
//  Offline coverage for `/v1/responses/compact` decoding and the
//  compacted-window → next-input forward path. Fixtures are the exact response
//  bodies from the OpenAI API reference for the endpoint, so the decoder is
//  pinned to the documented shape.
//

import Foundation
@testable import Providers
import SwiftMCP
import Testing

struct CompactResponseTests {
    private let openAI = OpenAI(apiKey: "test")

    // The realistic example from the docs: a user message kept verbatim plus a
    // `compaction` summary item carrying the encrypted window.
    private let dogCafeFixture = """
    {
      "id": "resp_001",
      "object": "response.compaction",
      "created_at": 1764967971,
      "output": [
        {
          "id": "msg_000",
          "type": "message",
          "status": "completed",
          "content": [
            {
              "type": "input_text",
              "text": "Create a simple landing page for a dog petting cafe."
            }
          ],
          "role": "user"
        },
        {
          "id": "cmp_001",
          "type": "compaction",
          "encrypted_content": "gAAAAABpM0Yj-...="
        }
      ],
      "usage": {
        "input_tokens": 139,
        "input_tokens_details": { "cached_tokens": 0 },
        "output_tokens": 438,
        "output_tokens_details": { "reasoning_tokens": 64 },
        "total_tokens": 577
      }
    }
    """

    @Test("Decodes the documented compaction response")
    func decodesCompactionResponse() throws {
        let compacted = try openAI.decoder.decode(CompactedResponse.self, from: Data(dogCafeFixture.utf8))

        #expect(compacted.id == "resp_001")
        #expect(compacted.object == "response.compaction")
        #expect(compacted.createdAt == Date(timeIntervalSince1970: 1_764_967_971))
        #expect(compacted.output.count == 2)
        #expect(compacted.output.first?["type"]?.stringValue == "message")
        #expect(compacted.output.last?["type"]?.stringValue == "compaction")
        #expect(compacted.containsCompactionSummary)

        // The compaction summary's encrypted content is captured verbatim.
        #expect(compacted.output.last?["encrypted_content"]?.stringValue == "gAAAAABpM0Yj-...=")

        // Usage parses through the shared ResponsesUsage type (non-optional details).
        #expect(compacted.usage?.totalTokens == 577)
        #expect(compacted.usage?.inputTokens == 139)
        #expect(compacted.usage?.outputTokens == 438)
        #expect(compacted.usage?.outputTokensDetails.reasoningTokens == 64)
        #expect(compacted.usage?.inputTokensDetails.cachedTokens == 0)
    }

    @Test("The compacted window forwards verbatim as the next input")
    func compactedWindowForwardsVerbatim() throws {
        let compacted = try openAI.decoder.decode(CompactedResponse.self, from: Data(dogCafeFixture.utf8))

        // `input` re-emits every window item as-is — no pruning, no reshaping —
        // ready to seed a fresh chain (previousResponseId == nil).
        let encoded = try openAI.encoder.encode(compacted.input)
        let items = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])

        #expect(items.count == 2)

        let message = items[0]
        #expect(message["type"] as? String == "message")
        #expect(message["role"] as? String == "user")
        // Nested user content (`input_text`) — a shape the typed models reject —
        // survives because the item is carried as raw JSON.
        let content = try #require(message["content"] as? [[String: Any]])
        #expect(content.first?["type"] as? String == "input_text")

        let summary = items[1]
        #expect(summary["type"] as? String == "compaction")
        // The opaque blob survives the round-trip byte-for-byte.
        #expect(summary["encrypted_content"] as? String == "gAAAAABpM0Yj-...=")
    }

    @Test("Decodes the schema example without losing unmodeled fields")
    func decodesSchemaExampleLosslessly() throws {
        // The API-reference *schema* sample carries a `role` of "unknown", a
        // status, a phase, and `input_text` content — shapes the typed
        // `OutputItem`/`ResponseItem` models reject. Raw JSON capture keeps
        // them, so the window never fails to decode.
        let json = """
        {
          "id": "id",
          "created_at": 0,
          "object": "response.compaction",
          "output": [
            {
              "id": "id",
              "content": [ { "text": "text", "type": "input_text" } ],
              "role": "unknown",
              "status": "in_progress",
              "type": "message",
              "phase": "commentary"
            }
          ],
          "usage": {
            "input_tokens": 0,
            "input_tokens_details": { "cached_tokens": 0 },
            "output_tokens": 0,
            "output_tokens_details": { "reasoning_tokens": 0 },
            "total_tokens": 0
          }
        }
        """

        let compacted = try openAI.decoder.decode(CompactedResponse.self, from: Data(json.utf8))
        let item = try #require(compacted.output.first)
        #expect(item["type"]?.stringValue == "message")
        // The unmodeled "unknown" role and phase are preserved, not rejected.
        #expect(item["role"]?.stringValue == "unknown")
        #expect(item["phase"]?.stringValue == "commentary")
        #expect(!compacted.containsCompactionSummary)
    }

    @Test("object defaults when the field is absent")
    func objectDefaultsWhenAbsent() throws {
        let json = """
        { "id": "resp_x", "created_at": 0, "output": [] }
        """
        let compacted = try openAI.decoder.decode(CompactedResponse.self, from: Data(json.utf8))
        #expect(compacted.object == "response.compaction")
        #expect(compacted.output.isEmpty)
        #expect(compacted.usage == nil)
    }
}
