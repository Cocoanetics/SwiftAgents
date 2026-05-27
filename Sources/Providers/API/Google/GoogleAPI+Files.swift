import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public extension GoogleAPI {
    func uploadFile(url: URL, filename: String? = nil, mimeType: String) async throws -> GoogleFile {
        let data = try Data(contentsOf: url)
        let resolvedName = filename ?? url.lastPathComponent
        return try await uploadFile(data: data, filename: resolvedName, mimeType: mimeType)
    }

    func uploadFile(data: Data, filename: String, mimeType: String) async throws -> GoogleFile {
        guard let apiKey else {
            throw APIError.authenticationError("Missing GEMINI_API_KEY")
        }
        let startURL = endpointURL.appendingPathComponent("upload/\(versionPath)/files")
        var startRequest = URLRequest(url: startURL)
        startRequest.httpMethod = "POST"
        startRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        startRequest.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        startRequest.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        startRequest.setValue("\(data.count)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        startRequest.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        startRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let metadataBody: [String: Any] = ["file": ["display_name": filename]]
        startRequest.httpBody = try JSONSerialization.data(withJSONObject: metadataBody, options: [])
        let (startData, startResponse) = try await session.data(for: startRequest)
        guard let startHTTP = startResponse as? HTTPURLResponse,
            (200 ... 299).contains(startHTTP.statusCode) else {
            throw googleError(from: startData, response: startResponse)
        }
        guard let uploadURLString = startHTTP.value(forHTTPHeaderField: "X-Goog-Upload-URL")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let uploadURL = URL(string: uploadURLString) else {
            throw APIError.otherError("upload", "Missing upload URL from Google response")
        }
        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "POST"
        uploadRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        uploadRequest.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        uploadRequest.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        uploadRequest.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        uploadRequest.httpBody = data
        let (responseData, uploadResponse) = try await session.data(for: uploadRequest)
        guard let uploadHTTP = uploadResponse as? HTTPURLResponse,
            (200 ... 299).contains(uploadHTTP.statusCode) else {
            throw googleError(from: responseData, response: uploadResponse)
        }
        let uploaded = try decoder.decode(GoogleFileUploadResponse.self, from: responseData)
        return uploaded.file
    }

    func listFiles() async throws -> [GoogleFile] {
        let request = try makeFilesRequest(path: "\(versionPath)/files")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
            (200 ... 299).contains(http.statusCode) else {
            throw googleError(from: data, response: response)
        }
        let list = try decoder.decode(GoogleFileListResponse.self, from: data)
        return list.files ?? []
    }

    /// Retrieves metadata (`GoogleFile`) for a file previously uploaded to the Files API.
    ///
    /// Accepts either a bare identifier (`abc123`), a `files/abc123` resource name,
    /// or a full URI (`https://generativelanguage.googleapis.com/v1beta/files/abc123`)
    /// — the trailing path component is used in all cases.
    func retrieveFile(uri: String) async throws -> GoogleFile {
        let request = try makeFilesRequest(path: "\(versionPath)/files/\(normalizedFileIdentifier(uri))")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
            (200 ... 299).contains(http.statusCode) else {
            throw googleError(from: data, response: response)
        }
        return try decoder.decode(GoogleFile.self, from: data)
    }

    /// Retrieves the binary content of a file previously uploaded to the Files API.
    ///
    /// Accepts either a bare identifier (`abc123`), a `files/abc123` resource name,
    /// or a full URI (`https://generativelanguage.googleapis.com/v1beta/files/abc123`)
    /// — the trailing path component is used in all cases.
    func retrieveFileContent(uri: String) async throws -> Data {
        let request = try makeFilesRequest(
            path: "\(versionPath)/files/\(normalizedFileIdentifier(uri))",
            queryItems: [URLQueryItem(name: "alt", value: "media")]
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
            (200 ... 299).contains(http.statusCode) else {
            throw googleError(from: data, response: response)
        }
        return data
    }

    /// Deletes a file previously uploaded to the Files API.
    ///
    /// Accepts either a bare identifier (`abc123`), a `files/abc123` resource name,
    /// or a full URI (`https://generativelanguage.googleapis.com/v1beta/files/abc123`)
    /// — the trailing path component is used in all cases.
    @discardableResult
    func deleteFile(uri: String) async throws -> Bool {
        var request = try makeFilesRequest(path: "\(versionPath)/files/\(normalizedFileIdentifier(uri))")
        request.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
            (200 ... 299).contains(http.statusCode) else {
            throw googleError(from: data, response: response)
        }
        return true
    }

    private func makeFilesRequest(path: String, queryItems: [URLQueryItem] = []) throws -> URLRequest {
        guard let apiKey else {
            throw APIError.authenticationError("Missing GEMINI_API_KEY")
        }
        let baseURL = endpointURL.appendingPathComponent(path)
        let finalURL: URL
        if queryItems.isEmpty {
            finalURL = baseURL
        } else {
            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
                throw APIError.otherError("files", "Cannot build URL from path: \(path)")
            }
            components.queryItems = queryItems
            guard let composed = components.url else {
                throw APIError.otherError("files", "Cannot compose URL with query items")
            }
            finalURL = composed
        }
        var request = URLRequest(url: finalURL)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        return request
    }

    private func normalizedFileIdentifier(_ uri: String) -> String {
        if let last = uri.split(separator: "/").last {
            return String(last)
        }
        return uri
    }
}
