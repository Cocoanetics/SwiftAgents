//
//  ImageGenerationTool.swift
//  SwiftAgents
//
//  The Responses API `image_generation` built-in tool. Unlike the standalone
//  Image API (`/v1/images/generations`), this tool lets the mainline model
//  decide when to generate or edit an image as part of a conversation, and
//  returns the bytes inline on an `image_generation_call` output item.
//
//  SeeAlso: https://platform.openai.com/docs/guides/image-generation
//

import Foundation

/// Configuration for the Responses API `image_generation` built-in tool.
///
/// Every field is optional — an empty `ImageGenerationTool()` is the bare
/// `{ "type": "image_generation" }` the model needs to generate or edit an
/// image at its own discretion. The open-ended `String` knobs (`size`,
/// `quality`, `background`, `outputFormat`, `moderation`) mirror the wire
/// values verbatim so newly supported settings (e.g. `gpt-image-2`'s arbitrary
/// resolutions) need no library change.
public struct ImageGenerationTool: Codable, Sendable, Equatable {
    /// Whether the model should generate a new image, edit one already in the
    /// conversation, or decide for itself.
    public enum Action: String, Codable, Sendable {
        /// Let the model choose between generating and editing (default).
        case auto
        /// Always create a new image.
        case generate
        /// Force editing an image in context (errors if none is present).
        case edit
    }

    /// A reference image mask that marks the area to edit. The mask is applied
    /// to the first input image and must share its size and format, with an
    /// alpha channel marking the editable region.
    public struct InputImageMask: Codable, Sendable, Equatable {
        /// The identifier of an image uploaded to the Files API to use as the mask.
        public let fileId: String?
        /// A fully qualified URL (or `data:` URL) of the mask image.
        public let imageURL: String?

        public init(fileId: String? = nil, imageURL: String? = nil) {
            self.fileId = fileId
            self.imageURL = imageURL
        }

        private enum CodingKeys: String, CodingKey {
            // Keys under the `tools` path are encoded verbatim (the OpenAI
            // codec disables snake_case conversion there), so spell them out.
            case fileId = "file_id"
            case imageURL = "image_url"
        }
    }

    /// The image model the tool should use (e.g. `gpt-image-2`). When nil the
    /// API selects its default GPT Image model.
    public let model: String?

    /// Whether to generate, edit, or auto-select.
    public let action: Action?

    /// Output dimensions, e.g. `1024x1024`, `1536x1024`, `auto`.
    public let size: String?

    /// Rendering quality: `low`, `medium`, `high`, or `auto`.
    public let quality: String?

    /// Background handling: `opaque`, `transparent`, or `auto`.
    public let background: String?

    /// Output file format: `png`, `jpeg`, or `webp`.
    public let outputFormat: String?

    /// Compression level (0–100) for `jpeg`/`webp` output.
    public let outputCompression: Int?

    /// Moderation strictness: `auto` or `low`.
    public let moderation: String?

    /// Number of partial images (0–3) to stream before the final image.
    public let partialImages: Int?

    /// Mask marking the region to edit on the first input image.
    public let inputImageMask: InputImageMask?

    /// How strongly the model preserves details from input images during edits
    /// and reference-image workflows, e.g. `high` / `low`. Omit for `gpt-image-2`,
    /// which always processes image inputs at high fidelity.
    public let inputFidelity: String?

    public init(
        model: String? = nil,
        action: Action? = nil,
        size: String? = nil,
        quality: String? = nil,
        background: String? = nil,
        outputFormat: String? = nil,
        outputCompression: Int? = nil,
        moderation: String? = nil,
        partialImages: Int? = nil,
        inputImageMask: InputImageMask? = nil,
        inputFidelity: String? = nil
    ) {
        self.model = model
        self.action = action
        self.size = size
        self.quality = quality
        self.background = background
        self.outputFormat = outputFormat
        self.outputCompression = outputCompression
        self.moderation = moderation
        self.partialImages = partialImages
        self.inputImageMask = inputImageMask
        self.inputFidelity = inputFidelity
    }
}
