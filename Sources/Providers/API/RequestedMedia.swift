//
//  RequestedMedia.swift
//  SwiftAgents
//
//  Provider-neutral declaration of the output modalities a run wants, with
//  optional per-modality configuration. Provider adapters translate each case
//  to the provider's own mechanism: Gemini `generationConfig.responseModalities`
//  + `imageConfig`, the OpenAI Responses `image_generation` tool, or the
//  Realtime session's output modalities. Carried on `ModelSettings`
//  (agent-level default) and overridable per run via `RunConfig`.
//

import Foundation

/// An output modality the caller wants the model to produce, plus the
/// portable options for it. Modelled as an enum-with-associated-config so a
/// modality and its settings are inseparable — you can't attach audio options
/// to a non-audio request, or request image without (optionally) sizing it.
public enum RequestedMedia: Codable, Sendable, Equatable {
    /// Plain text output (the default for most models).
    case text

    /// Image output, with portable sizing options.
    case image(ImageOptions)

    /// Audio output, with portable voice/format options. Modelled now so the
    /// surface is audio-ready; no chat-completion provider consumes it yet.
    case audio(AudioOptions)
}

/// Declarative image-output options. Carries the portable knobs every provider
/// understands (`size`, `aspectRatio`) plus the richer options the OpenAI
/// Responses `image_generation` tool exposes. It is *data*: the Runner realizes
/// it per provider — into the `image_generation` tool for OpenAI, or
/// `imageConfig`/`responseModalities` for Gemini (which reads only
/// `size`/`aspectRatio` and ignores the rest).
public struct ImageOptions: Codable, Sendable, Equatable {
    /// Portable size hint. Vocabularies differ per provider — Gemini accepts
    /// `"1K"`/`"2K"`, OpenAI `"1024x1024"`/`"auto"` — so this stays a free
    /// string the adapter forwards to its nearest equivalent.
    public var size: String?

    /// Aspect ratio (Gemini `imageConfig.aspectRatio`). Ignored by providers
    /// that don't support it.
    public var aspectRatio: String?

    /// Image model the OpenAI tool should use (e.g. `gpt-image-2`).
    public var model: String?

    /// Whether to generate, force an edit, or auto-select (OpenAI).
    public var action: ImageGenerationTool.Action?

    /// Rendering quality: `low`, `medium`, `high`, `auto` (OpenAI).
    public var quality: String?

    /// Background: `opaque`, `transparent`, `auto` (OpenAI).
    public var background: String?

    /// Output format: `png`, `jpeg`, `webp` (OpenAI).
    public var outputFormat: String?

    /// Compression (0–100) for `jpeg`/`webp` (OpenAI).
    public var outputCompression: Int?

    /// Moderation: `auto` or `low` (OpenAI).
    public var moderation: String?

    /// Number of partial images (0–3) to stream (OpenAI).
    public var partialImages: Int?

    /// Mask marking the editable region of the first input image (OpenAI).
    public var inputImageMask: ImageGenerationTool.InputImageMask?

    public init(
        size: String? = nil,
        aspectRatio: String? = nil,
        model: String? = nil,
        action: ImageGenerationTool.Action? = nil,
        quality: String? = nil,
        background: String? = nil,
        outputFormat: String? = nil,
        outputCompression: Int? = nil,
        moderation: String? = nil,
        partialImages: Int? = nil,
        inputImageMask: ImageGenerationTool.InputImageMask? = nil
    ) {
        self.size = size
        self.aspectRatio = aspectRatio
        self.model = model
        self.action = action
        self.quality = quality
        self.background = background
        self.outputFormat = outputFormat
        self.outputCompression = outputCompression
        self.moderation = moderation
        self.partialImages = partialImages
        self.inputImageMask = inputImageMask
    }
}

public extension ImageOptions {
    /// The OpenAI Responses `image_generation` built-in tool realizing these
    /// options. Used by the Runner when the run targets OpenAI; other
    /// providers shape image output through the request instead.
    var imageGenerationTool: ImageGenerationTool {
        ImageGenerationTool(
            model: model,
            action: action,
            size: size,
            quality: quality,
            background: background,
            outputFormat: outputFormat,
            outputCompression: outputCompression,
            moderation: moderation,
            partialImages: partialImages,
            inputImageMask: inputImageMask
        )
    }
}

/// Portable audio-output options. Reserved for the audio modality; not yet
/// consumed by the chat-completion path.
public struct AudioOptions: Codable, Sendable, Equatable {
    /// Output voice identifier, where the provider supports one.
    public var voice: String?

    /// Output audio format, e.g. `"audio/pcm"`.
    public var format: String?

    public init(voice: String? = nil, format: String? = nil) {
        self.voice = voice
        self.format = format
    }
}

/// Bundle of provider-neutral request knobs threaded into
/// `createChatCompletion`. A single bag rather than a growing list of
/// positional parameters; future neutral knobs land here. Adapters that don't
/// support a requested modality ignore it.
public struct GenerationOptions: Sendable, Equatable {
    /// The output modalities the run wants, in preference order.
    public var requestedMedia: [RequestedMedia]

    public init(requestedMedia: [RequestedMedia] = []) {
        self.requestedMedia = requestedMedia
    }
}

public extension Array where Element == RequestedMedia {
    /// Whether image output was requested.
    var requestsImage: Bool {
        contains { if case .image = $0 { return true } else { return false } }
    }

    /// The options of the first requested image modality, if any.
    var firstImageOptions: ImageOptions? {
        for media in self {
            if case let .image(options) = media { return options }
        }
        return nil
    }
}
