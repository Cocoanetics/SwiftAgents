//
//  OutputItem+ImageGenerationOutput.swift
//  SwiftAgents
//
//  The `image_generation_call` output item emitted by the Responses API
//  `image_generation` built-in tool. The generated image arrives inline as
//  base64 on `result`; the OpenAI decoder's `.base64` data strategy turns it
//  straight into `Data`.
//

import Foundation

public extension OutputItem {
    /// The result of an `image_generation` built-in tool call.
    struct ImageGenerationCall: Codable, Sendable {
        /// The unique ID of the image generation call. Pass this back as an
        /// `image_generation_call` input item to refer to the image on a later
        /// turn without resending the bytes.
        public let id: String

        /// The status of the call (`in_progress`, `generating`, `completed`,
        /// `failed`). Kept as a raw string for forward compatibility with
        /// statuses the image tool may add.
        public let status: String?

        /// The generated image bytes. Decoded from the base64 `result` field;
        /// nil on partial or in-progress items that carry no image yet.
        public let result: Data?

        /// The model-revised prompt actually used to render the image.
        public let revisedPrompt: String?

        /// The resolved output size, e.g. `1024x1024`.
        public let size: String?

        /// The resolved quality setting.
        public let quality: String?

        /// The resolved background setting.
        public let background: String?

        /// The resolved output format, e.g. `png`.
        public let outputFormat: String?

        public init(
            id: String,
            status: String? = nil,
            result: Data? = nil,
            revisedPrompt: String? = nil,
            size: String? = nil,
            quality: String? = nil,
            background: String? = nil,
            outputFormat: String? = nil
        ) {
            self.id = id
            self.status = status
            self.result = result
            self.revisedPrompt = revisedPrompt
            self.size = size
            self.quality = quality
            self.background = background
            self.outputFormat = outputFormat
        }

        /// The MIME type implied by `outputFormat` (defaults to `image/png`).
        public var mimeType: String {
            switch outputFormat?.lowercased() {
                case "jpeg", "jpg": "image/jpeg"
                case "webp": "image/webp"
                default: "image/png"
            }
        }
    }
}
