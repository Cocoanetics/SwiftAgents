//
//  ImageInfo.swift
//
//  Reads the pixel size and alpha channel from PNG, JPEG and WebP headers,
//  without any platform image framework.
//

import Foundation

/// Facts read from an encoded image's header.
public struct ImageInfo: Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// Whether the image has an alpha channel.
    public var hasAlpha: Bool

    /// Parses a PNG, JPEG or WebP; `nil` for anything else (or a truncated header).
    public init?(data: Data) {
        let bytes = [UInt8](data)
        if let info = Self.png(bytes) ?? Self.jpeg(bytes) ?? Self.webp(bytes) {
            self = info
        } else {
            return nil
        }
    }

    private init(width: Int, height: Int, hasAlpha: Bool) {
        self.width = width
        self.height = height
        self.hasAlpha = hasAlpha
    }

    private static func be32(_ bytes: [UInt8], _ offset: Int) -> Int {
        (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
            | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
    }

    private static func be16(_ bytes: [UInt8], _ offset: Int) -> Int {
        (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
    }

    private static func le16(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
    }

    private static func le24(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8) | (Int(bytes[offset + 2]) << 16)
    }

    private static func tag(_ bytes: [UInt8], _ offset: Int) -> String {
        String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) ?? ""
    }

    private static func png(_ bytes: [UInt8]) -> ImageInfo? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count >= 33, Array(bytes[0..<8]) == signature, tag(bytes, 12) == "IHDR" else { return nil }
        let width = be32(bytes, 16)
        let height = be32(bytes, 20)
        let colorType = bytes[25]
        var hasAlpha = colorType == 4 || colorType == 6
        // A palette or grayscale image can carry transparency in a tRNS chunk.
        var offset = 8
        while !hasAlpha, offset + 8 <= bytes.count {
            let length = be32(bytes, offset)
            let type = tag(bytes, offset + 4)
            if type == "tRNS" { hasAlpha = true }
            if type == "IDAT" || type == "IEND" { break }
            offset += 12 + length
        }
        return ImageInfo(width: width, height: height, hasAlpha: hasAlpha)
    }

    private static func jpeg(_ bytes: [UInt8]) -> ImageInfo? {
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var offset = 2
        while offset + 4 <= bytes.count {
            guard bytes[offset] == 0xFF else { return nil }
            let marker = bytes[offset + 1]
            if marker == 0xFF { offset += 1; continue }
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { offset += 2; continue }
            let length = be16(bytes, offset + 2)
            let isFrame = (0xC0...0xCF).contains(marker) && ![0xC4, 0xC8, 0xCC].contains(marker)
            if isFrame {
                guard offset + 9 <= bytes.count else { return nil }
                return ImageInfo(width: be16(bytes, offset + 7), height: be16(bytes, offset + 5), hasAlpha: false)
            }
            offset += 2 + length
        }
        return nil
    }

    private static func webp(_ bytes: [UInt8]) -> ImageInfo? {
        guard bytes.count >= 30, tag(bytes, 0) == "RIFF", tag(bytes, 8) == "WEBP" else { return nil }
        switch tag(bytes, 12) {
            case "VP8X":
                let hasAlpha = bytes[20] & 0x10 != 0
                return ImageInfo(width: le24(bytes, 24) + 1, height: le24(bytes, 27) + 1, hasAlpha: hasAlpha)
            case "VP8L":
                guard bytes[20] == 0x2F else { return nil }
                let bits = Int(bytes[21]) | (Int(bytes[22]) << 8) | (Int(bytes[23]) << 16) | (Int(bytes[24]) << 24)
                return ImageInfo(
                    width: (bits & 0x3FFF) + 1,
                    height: ((bits >> 14) & 0x3FFF) + 1,
                    hasAlpha: (bits >> 28) & 1 == 1
                )
            case "VP8 ":
                guard bytes[23] == 0x9D, bytes[24] == 0x01, bytes[25] == 0x2A else { return nil }
                return ImageInfo(
                    width: le16(bytes, 26) & 0x3FFF,
                    height: le16(bytes, 28) & 0x3FFF,
                    hasAlpha: false
                )
            default:
                return nil
        }
    }
}
