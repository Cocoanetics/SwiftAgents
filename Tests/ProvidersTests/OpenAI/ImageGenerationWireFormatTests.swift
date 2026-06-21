//
//  ImageGenerationWireFormatTests.swift
//  SwiftAgents
//
//  Deterministic (no-API-key) coverage of the Responses API image generation
//  wire format: the `image_generation` tool request shape, the
//  `image_generation_call` output item, the by-ID input reference, and the
//  partial-image streaming event. These lock the JSON contract so the live
//  integration tests in OpenAIImageGenerationAgentTests can assume it.
//

import Foundation
@testable import Providers
import Testing

@Suite
struct ImageGenerationWireFormatTests {
    private let openAI = OpenAI(credential: Credential.bearer("test-key"))

    private func encodeToObject(_ value: some Encodable) throws -> [String: Any] {
        let data = try openAI.encoder.encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any], "expected a JSON object")
    }

    // MARK: - Tool request shape

    @Test("image_generation tool encodes every knob in snake_case")
    func encodesFullToolKnobs() throws {
        let tool = Tool.imageGeneration(ImageGenerationTool(
            model: "gpt-image-2",
            action: .generate,
            size: "1024x1024",
            quality: "low",
            background: "opaque",
            outputFormat: "jpeg",
            outputCompression: 50,
            moderation: "low",
            partialImages: 2,
            inputImageMask: .init(fileId: "file_mask_123"),
            inputFidelity: "high"
        ))

        let object = try encodeToObject(tool)

        #expect(object["type"] as? String == "image_generation")
        #expect(object["model"] as? String == "gpt-image-2")
        #expect(object["action"] as? String == "generate")
        #expect(object["size"] as? String == "1024x1024")
        #expect(object["quality"] as? String == "low")
        #expect(object["background"] as? String == "opaque")
        #expect(object["output_format"] as? String == "jpeg")
        #expect(object["output_compression"] as? Int == 50)
        #expect(object["moderation"] as? String == "low")
        #expect(object["partial_images"] as? Int == 2)
        #expect(object["input_fidelity"] as? String == "high")

        let mask = try #require(object["input_image_mask"] as? [String: Any], "mask should be an object")
        #expect(mask["file_id"] as? String == "file_mask_123")
    }

    @Test("the auto action and image_url mask variant encode correctly")
    func encodesAutoActionAndUrlMask() throws {
        let tool = Tool.imageGeneration(ImageGenerationTool(
            action: .auto,
            inputImageMask: .init(imageURL: "data:image/png;base64,AAAA")
        ))
        let object = try encodeToObject(tool)

        #expect(object["action"] as? String == "auto")
        let mask = try #require(object["input_image_mask"] as? [String: Any], "mask should be an object")
        #expect(mask["image_url"] as? String == "data:image/png;base64,AAAA")
        // The fileId variant is absent, so only image_url is on the wire.
        #expect(mask["file_id"] == nil)
    }

    @Test("a bare image_generation tool encodes to just its type")
    func encodesBareTool() throws {
        let object = try encodeToObject(Tool.imageGeneration(ImageGenerationTool()))
        #expect(object["type"] as? String == "image_generation")
        // No knobs set → only the discriminator is on the wire.
        #expect(object.keys.sorted() == ["type"])
    }

    // MARK: - Refer-by-ID input element

    @Test("referring to an image by id encodes a bare {type, id} input item")
    func encodesImageIdReference() throws {
        let element = Response.Input.Element.imageGenerationCall(
            OutputItem.ImageGenerationCall(id: "ig_abc123")
        )
        let object = try encodeToObject(element)

        #expect(object["type"] as? String == "image_generation_call")
        #expect(object["id"] as? String == "ig_abc123")
        // The bytes are resolved server-side; only the discriminator and id ship.
        #expect(object.keys.sorted() == ["id", "type"])
    }

    @Test("an output image call round-trips through toInputElement as an id reference")
    func outputItemBecomesIdReference() throws {
        let call = OutputItem.ImageGenerationCall(
            id: "ig_round_trip",
            status: "completed",
            result: Data([0x89, 0x50, 0x4E, 0x47]),
            revisedPrompt: "A cat"
        )
        let element = try #require(
            OutputItem.imageGenerationCall(call).toInputElement(),
            "image generation calls should replay as input"
        )
        let object = try encodeToObject(element)
        #expect(object["type"] as? String == "image_generation_call")
        #expect(object["id"] as? String == "ig_round_trip")
        #expect(object.keys.sorted() == ["id", "type"])
    }

    // MARK: - Output item decoding

    @Test("image_generation_call output item decodes base64 result into Data")
    func decodesOutputItem() throws {
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let json = try JSONSerialization.data(withJSONObject: [
            "type": "image_generation_call",
            "id": "ig_123",
            "status": "completed",
            "result": pngBytes.base64EncodedString(),
            "revised_prompt": "A gray tabby cat hugging an otter",
            "size": "1024x1024",
            "output_format": "png"
        ])

        let item = try openAI.decoder.decode(OutputItem.self, from: json)
        guard case let .imageGenerationCall(call) = item else {
            Issue.record("expected an image_generation_call, got \(item)")
            return
        }

        #expect(call.id == "ig_123")
        #expect(call.status == "completed")
        #expect(call.result == pngBytes)
        #expect(call.revisedPrompt == "A gray tabby cat hugging an otter")
        #expect(call.size == "1024x1024")
        #expect(call.mimeType == "image/png")
    }

    @Test("a jpeg image_generation_call reports the jpeg mime type")
    func jpegMimeType() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "type": "image_generation_call",
            "id": "ig_jpeg",
            "output_format": "jpeg"
        ])
        let item = try openAI.decoder.decode(OutputItem.self, from: json)
        guard case let .imageGenerationCall(call) = item else {
            Issue.record("expected an image_generation_call")
            return
        }
        #expect(call.mimeType == "image/jpeg")
        #expect(call.result == nil)
    }

    // MARK: - Streaming events

    @Test("partial_image stream event decodes its index and base64 bytes")
    func decodesPartialImageEvent() throws {
        let partialBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let json = try JSONSerialization.data(withJSONObject: [
            "type": "response.image_generation_call.partial_image",
            "item_id": "ig_stream",
            "output_index": 0,
            "partial_image_index": 1,
            "partial_image_b64": partialBytes.base64EncodedString(),
            "sequence_number": 7
        ])

        let event = try #require(
            try ResponsesStreamEvent(from: json, decoder: openAI.decoder),
            "partial_image is a recognized event"
        )
        guard case let .imageGenerationCallPartialImage(info) = event.object else {
            Issue.record("expected an image_generation partial image event")
            return
        }
        #expect(info.itemId == "ig_stream")
        #expect(info.outputIndex == 0)
        #expect(info.partialImageIndex == 1)
        #expect(info.partialImageB64 == partialBytes)
    }

    @Test("image generation lifecycle events decode", arguments: [
        "response.image_generation_call.in_progress",
        "response.image_generation_call.generating",
        "response.image_generation_call.completed"
    ])
    func decodesLifecycleEvents(eventType: String) throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "type": eventType,
            "item_id": "ig_life",
            "output_index": 2,
            "sequence_number": 3
        ])
        let event = try #require(try ResponsesStreamEvent(from: json, decoder: openAI.decoder))

        switch event.object {
            case let .imageGenerationCallInProgress(info),
                 let .imageGenerationCallGenerating(info),
                 let .imageGenerationCallCompleted(info):
                #expect(info.itemId == "ig_life")
                #expect(info.outputIndex == 2)
            default:
                Issue.record("expected an image generation lifecycle event for \(eventType)")
        }
    }
}
