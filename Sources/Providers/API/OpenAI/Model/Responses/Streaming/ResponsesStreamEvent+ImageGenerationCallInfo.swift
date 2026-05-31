//
//  ResponsesStreamEvent+ImageGenerationCallInfo.swift
//  SwiftAgents
//
//  Streaming payloads for the `image_generation` built-in tool. When the tool
//  is configured with `partial_images` > 0, the API streams progressively
//  refined previews before the final image lands on the output item.
//

import Foundation

public extension ResponsesStreamEvent {
    /// Lifecycle info for an image generation call (in progress / generating /
    /// completed).
    struct ImageGenerationCallInfo: Codable, Sendable {
        /// The ID of the image generation output item.
        public let itemId: String

        /// The index of the output item in the response.
        public let outputIndex: Int
    }

    /// A partial (progressively refined) image streamed before the final one.
    struct ImageGenerationPartialImageInfo: Codable, Sendable {
        /// The ID of the image generation output item.
        public let itemId: String

        /// The index of the output item in the response.
        public let outputIndex: Int

        /// The 0-based index of this partial image in the stream.
        public let partialImageIndex: Int

        /// The partial image bytes. Decoded from the base64 `partial_image_b64`
        /// field by the OpenAI decoder's `.base64` data strategy.
        public let partialImageB64: Data
    }
}
