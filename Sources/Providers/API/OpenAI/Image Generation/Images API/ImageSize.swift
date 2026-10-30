//
//  ImageSize.swift
//
//  `auto` or `WxH`, validated against the documented GPT Image limits.
//

import Foundation

/// An Images API `size`: `auto` or `WxH`.
///
/// Recommended sizes are `1024x1024`, `1536x1024` and `1024x1536`. Custom
/// sizes are checked by ``validate()`` against the limits shared by all GPT
/// Image models.
public struct ImageSize: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral,
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

    public init(width: Int, height: Int) {
        rawValue = "\(width)x\(height)"
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static let auto = ImageSize("auto")
    public static let square = ImageSize("1024x1024")
    public static let landscape = ImageSize("1536x1024")
    public static let portrait = ImageSize("1024x1536")

    // MARK: - Limits

    /// Both sides must be a multiple of this.
    public static let multiple = 16
    /// The longest side, in pixels.
    public static let maxEdge = 3840
    /// The longest side may be at most this many times the shortest.
    public static let maxAspectRatio = 3
    public static let minPixels = 655_360
    public static let maxPixels = 8_294_400
    /// Sizes with more pixels than 2560×1440 are experimental.
    public static let experimentalPixels = 2560 * 1440

    public var isAuto: Bool { rawValue == "auto" }

    /// The width and height, or `nil` for `auto` and anything that isn't `WxH`.
    public var dimensions: (width: Int, height: Int)? {
        let parts = rawValue.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let width = Int(parts[0]), let height = Int(parts[1]),
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) })
        else { return nil }
        return (width, height)
    }

    /// Whether the size is above 2560×1440 — allowed, but experimental.
    public var isExperimental: Bool {
        guard let (width, height) = dimensions else { return false }
        return width * height > Self.experimentalPixels
    }

    /// Checks the size against the documented limits.
    ///
    /// - Returns: Notes for the caller (an experimental size is allowed, with a note).
    /// - Throws: ``ImageGenerationError/invalidParameter(_:)`` naming the violated rule.
    @discardableResult
    public func validate() throws -> [String] {
        if isAuto { return [] }
        guard let (width, height) = dimensions else {
            throw ImageGenerationError.invalidParameter(
                "size '\(rawValue)' must be 'auto' or WIDTHxHEIGHT, e.g. 1536x1024"
            )
        }
        guard width > 0, height > 0 else {
            throw ImageGenerationError.invalidParameter("size \(rawValue): both sides must be positive")
        }
        guard width % Self.multiple == 0, height % Self.multiple == 0 else {
            throw ImageGenerationError.invalidParameter(
                "size \(rawValue): both sides must be multiples of \(Self.multiple)"
            )
        }
        let longest = max(width, height)
        let shortest = min(width, height)
        guard longest <= Self.maxEdge else {
            throw ImageGenerationError.invalidParameter(
                "size \(rawValue): the longest side must be at most \(Self.maxEdge) pixels"
            )
        }
        guard longest <= Self.maxAspectRatio * shortest else {
            throw ImageGenerationError.invalidParameter(
                "size \(rawValue): the aspect ratio must be between 1:\(Self.maxAspectRatio) " +
                    "and \(Self.maxAspectRatio):1"
            )
        }
        let pixels = width * height
        guard pixels >= Self.minPixels, pixels <= Self.maxPixels else {
            throw ImageGenerationError.invalidParameter(
                "size \(rawValue): total pixels (\(pixels)) must be between \(Self.minPixels) and \(Self.maxPixels)"
            )
        }
        if pixels > Self.experimentalPixels {
            return ["size \(rawValue) is above 2560x1440; sizes that large are experimental and results may vary"]
        }
        return []
    }
}
