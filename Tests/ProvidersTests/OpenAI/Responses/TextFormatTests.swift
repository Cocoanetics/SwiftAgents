//
//  TextFormatTests.swift
//  ProvidersTests
//
//  Offline coverage for the hand-written `TextFormat` Codable — the
//  Responses `text.format` wire object structured output rides on:
//  `.text` → {"type":"text"}, `.json` → {"type":"json_object"}, and
//  `.jsonSchema` → {"type":"json_schema","name":…,"schema":…}. Without
//  this, a typo in one of the wire strings (or a schema-key regression in
//  the coder's schema-path key strategy) would only surface in the live
//  structured-output suites.
//

import Foundation
@testable import Providers
import SwiftMCP
import Testing

@Schema
private struct SpeciesGuess: Codable {
    let species: String
    let confidence: Double
}

struct TextFormatTests {
    private let openAI = OpenAI(credential: Credential.bearer("test"))

    @Test("text and json_object encode to their exact wire shapes")
    func plainWireShapes() throws {
        let text = try JSONSerialization.jsonObject(
            with: openAI.encoder.encode(TextFormat.text)
        ) as? [String: Any]
        #expect(text?.count == 1)
        #expect(text?["type"] as? String == "text")

        let json = try JSONSerialization.jsonObject(
            with: openAI.encoder.encode(TextFormat.json)
        ) as? [String: Any]
        #expect(json?.count == 1)
        #expect(json?["type"] as? String == "json_object")
    }

    @Test("json_schema carries the name and the @Schema-emitted schema")
    func jsonSchemaWireShape() throws {
        let format = TextFormat.jsonSchema(SpeciesGuess.jsonSchema)
        let data = try openAI.encoder.encode(format)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["type"] as? String == "json_schema")
        #expect(object["name"] as? String == "SpeciesGuess")

        // The schema subtree must dodge the snake_case key strategy —
        // `additionalProperties` (the strict structured-output shape) and
        // the property names have to survive verbatim.
        let schema = try #require(object["schema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
        #expect(schema["additionalProperties"] as? Bool == false)
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(properties.keys.sorted() == ["confidence", "species"])
        let required = try #require(schema["required"] as? [String])
        #expect(required.sorted() == ["confidence", "species"])
    }

    @Test("json_schema round-trips through the OpenAI coder")
    func jsonSchemaRoundTrip() throws {
        let original = try openAI.encoder.encode(TextFormat.jsonSchema(SpeciesGuess.jsonSchema))
        let decoded = try openAI.decoder.decode(TextFormat.self, from: original)

        guard case let .jsonSchema(format) = decoded else {
            Issue.record("expected .jsonSchema, got \(decoded)")
            return
        }
        #expect(format.name == "SpeciesGuess")

        // `TextFormat`/`JSONSchema` aren't Equatable — compare the
        // re-encoded wire objects instead.
        let reencoded = try openAI.encoder.encode(decoded)
        let first = try #require(JSONSerialization.jsonObject(with: original) as? NSDictionary)
        let second = try #require(JSONSerialization.jsonObject(with: reencoded) as? NSDictionary)
        #expect(first == second)
    }

    @Test("an unknown format type throws instead of mis-decoding")
    func unknownTypeThrows() {
        let bogus = Data(#"{"type":"bogus"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try openAI.decoder.decode(TextFormat.self, from: bogus)
        }
    }
}
