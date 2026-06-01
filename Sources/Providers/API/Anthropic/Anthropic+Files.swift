//
//  Anthropic+Files.swift
//  SwiftAgents
//
//  Anthropic Files API (beta `files-api-2025-04-14`): upload an image (or other
//  file) once and reference it by `file_id` across many Messages requests
//  instead of re-sending bytes. Mirrors the OpenAI/Google Files surfaces.
//
//  See: https://platform.claude.com/docs/en/build-with-claude/files
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public extension Anthropic {
    /// `anthropic-beta` value required by every Files API call and by any
    /// Messages request that references an uploaded file by `file_id`.
    static let filesAPIBeta = "files-api-2025-04-14"

    /// Uploads a file from disk and returns its metadata (including `id`).
    func uploadFile(url: URL, filename: String? = nil, mimeType: String) async throws -> AnthropicFile {
        let data = try Data(contentsOf: url)
        return try await uploadFile(data: data, filename: filename ?? url.lastPathComponent, mimeType: mimeType)
    }

    /// Uploads file bytes and returns its metadata (including `id`), which can
    /// be referenced from a Messages request as an image `file` source.
    func uploadFile(data: Data, filename: String, mimeType: String) async throws -> AnthropicFile {
        var request = try filesRequest(httpMethod: "POST", path: "/v1/files")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Data(data: data, filename: filename, mimeType: mimeType, boundary: boundary)

        let (responseData, response) = try await session.data(for: request)
        return try decodeFileResult(AnthropicFile.self, data: responseData, response: response)
    }

    /// Lists files uploaded to the workspace.
    func listFiles() async throws -> [AnthropicFile] {
        let request = try filesRequest(path: "/v1/files")
        let (data, response) = try await session.data(for: request)
        return try decodeFileResult(AnthropicFileList.self, data: data, response: response).data
    }

    /// Retrieves metadata for a single file.
    func retrieveFileMetadata(id: String) async throws -> AnthropicFile {
        let request = try filesRequest(path: "/v1/files/\(id)")
        let (data, response) = try await session.data(for: request)
        return try decodeFileResult(AnthropicFile.self, data: data, response: response)
    }

    /// Deletes a file. Returns `true` on success.
    @discardableResult
    func deleteFile(id: String) async throws -> Bool {
        let request = try filesRequest(httpMethod: "DELETE", path: "/v1/files/\(id)")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200 ..< 300).contains(http.statusCode) else { throw anthropicError(from: data, response: http) }
        return true
    }

    /// Downloads a file's bytes. Only files produced by skills or the code
    /// execution tool are downloadable — user uploads are not.
    func downloadFileContent(id: String) async throws -> Data {
        let request = try filesRequest(path: "/v1/files/\(id)/content")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200 ..< 300).contains(http.statusCode) else { throw anthropicError(from: data, response: http) }
        return data
    }

    // MARK: - Helpers

    /// Builds a Files API request: the standard `x-api-key` / `anthropic-version`
    /// headers plus the required `anthropic-beta: files-api-2025-04-14`.
    private func filesRequest(httpMethod: String = "GET", path: String) throws -> URLRequest {
        var request = try createUrlRequest(httpMethod: httpMethod, path: path)
        request.setValue(Anthropic.filesAPIBeta, forHTTPHeaderField: "anthropic-beta")
        return request
    }

    private func decodeFileResult<T: Decodable>(_ type: T.Type, data: Data, response: URLResponse) throws -> T {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200 ..< 300).contains(http.statusCode) else { throw anthropicError(from: data, response: http) }
        return try anthropicDecoder.decode(T.self, from: data)
    }
}

extension AnthropicMessagesRequest {
    /// True if any message references an uploaded file (an image block with
    /// `source.type == "file"`), which requires the Files API beta header on
    /// the Messages request.
    var referencesUploadedFiles: Bool {
        messages.contains { message in
            guard case let .blocks(blocks) = message.content else { return false }
            return blocks.contains { block in
                if case let .image(image) = block { return image.source.type == "file" }
                return false
            }
        }
    }
}
