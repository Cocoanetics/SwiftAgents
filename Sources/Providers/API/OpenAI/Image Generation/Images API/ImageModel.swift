//
//  ImageModel.swift
//
//  Open model identifier for the OpenAI Images API.
//

import Foundation

/// An Images API model name.
///
/// The type is an open string with named constants for the current GPT Image
/// models, so an unknown (new) model name passes through unchanged and needs no
/// library change.
public struct ImageModel: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral,
    CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    /// The default: recommended where editing precision matters.
    public static let sunburst = ImageModel("gpt-image-2.5-sunburst")
    /// Fast, high-quality everyday generation.
    public static let flare = ImageModel("gpt-image-2.5-flare")
    /// The previous-generation GPT Image model (no `xhigh`/`max` quality, no transparency).
    public static let gptImage2 = ImageModel("gpt-image-2")

    /// The model used when a request names none.
    public static let `default` = ImageModel.sunburst

    /// The models with named constants, with the guide's one-line guidance.
    public static let known: [(model: ImageModel, guidance: String)] = [
        (.sunburst, "default; recommended where editing precision matters"),
        (.flare, "fast, high-quality everyday generation"),
        (.gptImage2, "previous generation; no xhigh/max quality, no transparent background")
    ]

    /// Whether this is one of the GPT Image 2.5 models (`xhigh`/`max` quality, transparency).
    public var isGPTImage25: Bool { rawValue.hasPrefix("gpt-image-2.5") }

    /// Whether this is `gpt-image-2` (or a dated snapshot of it).
    public var isGPTImage2: Bool { rawValue == "gpt-image-2" || rawValue.hasPrefix("gpt-image-2-") }
}

/// An Images API `quality` value: an open string with the known values.
public struct ImageQuality: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral,
    CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static let low = ImageQuality("low")
    public static let medium = ImageQuality("medium")
    public static let high = ImageQuality("high")
    /// 2.5 models only.
    public static let xhigh = ImageQuality("xhigh")
    /// 2.5 models only.
    public static let max = ImageQuality("max")
    public static let auto = ImageQuality("auto")

    /// Every documented value.
    public static let known: [ImageQuality] = [.low, .medium, .high, .xhigh, .max, .auto]

    /// Values that exist only on the GPT Image 2.5 models.
    public var isExtended: Bool { self == .xhigh || self == .max }
}

/// The `background` of a generated image.
public enum ImageBackground: String, Sendable, Codable, CaseIterable {
    case auto, opaque, transparent
}

/// The `output_format` of a generated image.
public enum ImageOutputFormat: String, Sendable, Codable, CaseIterable {
    case png, jpeg, webp

    /// The usual file extension.
    public var fileExtension: String { rawValue == "jpeg" ? "jpg" : rawValue }

    /// The MIME type.
    public var mimeType: String { "image/\(rawValue)" }
}

/// The `moderation` level.
public enum ImageModeration: String, Sendable, Codable, CaseIterable {
    case auto, low
}
