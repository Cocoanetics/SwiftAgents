//
//  MultipartFormData.swift
//
//  A small `multipart/form-data` encoder. Foundation only.
//

import Foundation

/// Builds a `multipart/form-data` body from text fields and file parts.
public struct MultipartFormData: Sendable {
    private enum Part: Sendable {
        case field(name: String, value: String)
        case file(name: String, filename: String, mimeType: String, data: Data)
    }

    private var parts: [Part] = []

    /// The boundary separating the parts.
    public let boundary: String

    public init(boundary: String = "Boundary-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    /// The `Content-Type` header value for the encoded body.
    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func addField(name: String, value: String) {
        parts.append(.field(name: name, value: value))
    }

    public mutating func addFile(name: String, filename: String, mimeType: String, data: Data) {
        parts.append(.file(name: name, filename: filename, mimeType: mimeType, data: data))
    }

    /// The encoded body.
    public func encoded() -> Data {
        var body = Data()
        for part in parts {
            body.append("--\(boundary)\r\n")
            switch part {
                case let .field(name, value):
                    body.append("Content-Disposition: form-data; name=\"\(Self.escape(name))\"\r\n\r\n")
                    body.append("\(value)\r\n")
                case let .file(name, filename, mimeType, data):
                    body.append(
                        "Content-Disposition: form-data; name=\"\(Self.escape(name))\"; " +
                            "filename=\"\(Self.escape(filename))\"\r\n"
                    )
                    body.append("Content-Type: \(mimeType)\r\n\r\n")
                    body.append(data)
                    body.append("\r\n")
            }
        }
        body.append("--\(boundary)--\r\n")
        return body
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }
}
