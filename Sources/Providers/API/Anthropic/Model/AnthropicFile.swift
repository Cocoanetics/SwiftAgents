//
//  AnthropicFile.swift
//  SwiftAgents
//
//  Metadata for a file uploaded to the Anthropic Files API
//  (`anthropic-beta: files-api-2025-04-14`). Reference the `id` from a Messages
//  request via an image `source: { type: "file", file_id }` block.
//
//  See: https://platform.claude.com/docs/en/build-with-claude/files
//

import Foundation

/// Metadata for a file stored in Anthropic's Files API.
public struct AnthropicFile: Codable, Sendable, Equatable {
    /// Unique identifier, e.g. `file_011CNha8iCJcU1wXNR6q4V8w`. Pass this as a
    /// `file_id` in an image (or document) content block.
    public let id: String

    /// Object type, always `"file"`.
    public let type: String?

    /// Original filename.
    public let filename: String?

    /// MIME type, e.g. `image/png`.
    public let mimeType: String?

    /// Size in bytes.
    public let sizeBytes: Int?

    /// ISO-8601 creation timestamp.
    public let createdAt: String?

    /// Whether the file's content can be downloaded (true only for files
    /// produced by skills or the code execution tool — not user uploads).
    public let downloadable: Bool?

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case filename
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
        case createdAt = "created_at"
        case downloadable
    }

    public init(
        id: String,
        type: String? = nil,
        filename: String? = nil,
        mimeType: String? = nil,
        sizeBytes: Int? = nil,
        createdAt: String? = nil,
        downloadable: Bool? = nil
    ) {
        self.id = id
        self.type = type
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.createdAt = createdAt
        self.downloadable = downloadable
    }
}

/// Page of files returned by `GET /v1/files`.
public struct AnthropicFileList: Codable, Sendable {
    public let data: [AnthropicFile]
    public let hasMore: Bool?
    public let firstID: String?
    public let lastID: String?

    private enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case firstID = "first_id"
        case lastID = "last_id"
    }
}
