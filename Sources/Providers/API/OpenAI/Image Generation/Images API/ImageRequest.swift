//
//  ImageRequest.swift
//
//  A text-to-image request for `/v1/images/generations`; also the shared
//  fields of an edit.
//

import Foundation

/// The request fields shared by generate and edit.
///
/// A `nil` field is not sent and the API default applies.
public struct ImageRequest: Sendable, Codable, Equatable {
    public var prompt: String
    public var model: ImageModel
    public var size: ImageSize?
    public var quality: ImageQuality?
    public var background: ImageBackground?
    public var outputFormat: ImageOutputFormat?
    /// 0–100; `jpeg` and `webp` only.
    public var outputCompression: Int?
    public var moderation: ImageModeration?
    /// The number of images (1–10).
    public var n: Int
    public var user: String?

    public init(
        prompt: String,
        model: ImageModel = .default,
        size: ImageSize? = nil,
        quality: ImageQuality? = nil,
        background: ImageBackground? = nil,
        outputFormat: ImageOutputFormat? = nil,
        outputCompression: Int? = nil,
        moderation: ImageModeration? = nil,
        n: Int = 1,
        user: String? = nil
    ) {
        self.prompt = prompt
        self.model = model
        self.size = size
        self.quality = quality
        self.background = background
        self.outputFormat = outputFormat
        self.outputCompression = outputCompression
        self.moderation = moderation
        self.n = n
        self.user = user
    }

    /// The longest prompt the GPT Image models accept.
    public static let maxPromptLength = 32000

    /// Checks the request before anything is sent.
    ///
    /// - Returns: Notes for the caller (for example, an experimental size).
    /// - Throws: ``ImageGenerationError/invalidParameter(_:)`` naming the rule that is violated.
    @discardableResult
    public func validate() throws -> [String] {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImageGenerationError.invalidParameter("prompt must not be empty")
        }
        guard prompt.count <= Self.maxPromptLength else {
            throw ImageGenerationError.invalidParameter("prompt exceeds \(Self.maxPromptLength) characters")
        }
        guard (1...10).contains(n) else {
            throw ImageGenerationError.invalidParameter("n must be between 1 and 10 (n=\(n))")
        }

        var notes: [String] = []
        if let size {
            notes += try size.validate()
        }

        if let quality, quality.isExtended, model.isGPTImage2 {
            throw ImageGenerationError.invalidParameter(
                "quality '\(quality)' is only available on the GPT Image 2.5 models " +
                    "(\(ImageModel.sunburst), \(ImageModel.flare)), not \(model)"
            )
        }

        if background == .transparent {
            if model.isGPTImage2 {
                throw ImageGenerationError.invalidParameter(
                    "transparent backgrounds are not supported by \(model); use a GPT Image 2.5 model " +
                        "such as \(ImageModel.sunburst)"
                )
            }
            if outputFormat == .jpeg {
                throw ImageGenerationError.invalidParameter(
                    "a transparent background needs output_format png or webp, not jpeg"
                )
            }
        }

        if let outputCompression {
            guard (0...100).contains(outputCompression) else {
                throw ImageGenerationError.invalidParameter("output_compression must be between 0 and 100")
            }
            guard outputFormat == .jpeg || outputFormat == .webp else {
                throw ImageGenerationError.invalidParameter("output_compression applies to jpeg and webp output only")
            }
        }
        return notes
    }

    /// The JSON body for `/v1/images/generations` (snake_case, sorted keys).
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// The text fields of the multipart edit body, in a stable order.
    func formFields() -> [(name: String, value: String)] {
        var fields: [(String, String)] = [("model", model.rawValue), ("prompt", prompt), ("n", String(n))]
        if let size { fields.append(("size", size.rawValue)) }
        if let quality { fields.append(("quality", quality.rawValue)) }
        if let background { fields.append(("background", background.rawValue)) }
        if let outputFormat { fields.append(("output_format", outputFormat.rawValue)) }
        if let outputCompression { fields.append(("output_compression", String(outputCompression))) }
        if let moderation { fields.append(("moderation", moderation.rawValue)) }
        if let user { fields.append(("user", user)) }
        return fields
    }
}

/// A reference image (or mask) for an edit.
public struct ImageInput: Sendable, Equatable {
    public var data: Data
    public var filename: String
    public var mimeType: String

    public init(data: Data, filename: String, mimeType: String? = nil) {
        self.data = data
        self.filename = filename
        self.mimeType = mimeType ?? Self.mimeType(forFilename: filename)
    }

    /// `image/png`, `image/jpeg` or `image/webp` from the extension; PNG when unknown.
    public static func mimeType(forFilename filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
            case "jpg", "jpeg": return "image/jpeg"
            case "webp": return "image/webp"
            default: return "image/png"
        }
    }
}

/// An edit request for `/v1/images/edits`.
public struct ImageEditRequest: Sendable {
    public var request: ImageRequest
    /// One or more reference images.
    public var images: [ImageInput]
    /// Applies to the first image; masking is prompt-guided.
    public var mask: ImageInput?

    public init(request: ImageRequest, images: [ImageInput], mask: ImageInput? = nil) {
        self.request = request
        self.images = images
        self.mask = mask
    }

    /// Validates the shared fields and the image list.
    @discardableResult
    public func validate() throws -> [String] {
        guard !images.isEmpty else {
            throw ImageGenerationError.invalidParameter("an edit needs at least one image")
        }
        guard images.count <= Self.maxImages else {
            throw ImageGenerationError.invalidParameter(
                "an edit takes at most \(Self.maxImages) images (got \(images.count))"
            )
        }
        return try request.validate()
    }

    /// The Images API accepts at most this many input images per edit.
    public static let maxImages = 16

    /// The multipart body. `input_fidelity` is deliberately never sent: `gpt-image-2`
    /// rejects it and the guide doesn't document it for the 2.5 models.
    func multipartBody() -> MultipartFormData {
        var form = MultipartFormData()
        for field in request.formFields() {
            form.addField(name: field.name, value: field.value)
        }
        for image in images {
            form.addFile(name: "image[]", filename: image.filename, mimeType: image.mimeType, data: image.data)
        }
        if let mask {
            form.addFile(name: "mask", filename: mask.filename, mimeType: mask.mimeType, data: mask.data)
        }
        return form
    }
}
