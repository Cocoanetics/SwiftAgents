//
//  OpenAI+Files.swift
//
//
//  Created by Oliver Drobnik on 01.05.24.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public extension OpenAI {
    func uploadFile(url: URL, filename: String? = nil, purpose: File.Purpose = .assistants) async throws -> File {
        var request = try createUrlRequest(httpMethod: "POST", path: "/v1/files")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Data(url: url, filename: filename, purpose: purpose.rawValue, boundary: boundary)

        let (data, response) = try await session.data(for: request)

        return try process(data: data, response: response)
    }

    func uploadFile(
        data: Data,
        filename: String,
        mimeType: String,
        purpose: File.Purpose = .assistants
    ) async throws -> File {
        var request = try createUrlRequest(httpMethod: "POST", path: "/v1/files")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Data(
            data: data,
            filename: filename,
            mimeType: mimeType,
            purpose: purpose.rawValue,
            boundary: boundary
        )

        let (data, response) = try await session.data(for: request)

        return try process(data: data, response: response)
    }

    func listFiles(purpose: File.Purpose? = nil) async throws -> [File] {
        var queryItems: [URLQueryItem] = []

        if let purpose {
            let queryItem = URLQueryItem(name: "purpose", value: purpose.rawValue)
            queryItems.append(queryItem)
        }

        let request = try createUrlRequest(path: "/v1/files", queryItems: queryItems)

        let (data, response) = try await session.data(for: request)

        let list: ListResponse<File> = try process(data: data, response: response)

        return list.data
    }

    func retrieveFile(id: String) async throws -> File {
        let request = try createUrlRequest(path: "/v1/files/" + id)

        let (data, response) = try await session.data(for: request)

        return try process(data: data, response: response)
    }

    func retrieveFileContent(id: String) async throws -> Data {
        let request = try createUrlRequest(path: "/v1/files/" + id + "/content")

        let (data, response) = try await session.data(for: request)

        return try process(data: data, response: response)
    }

    @discardableResult func deleteFile(id: String) async throws -> Bool {
        let request = try createUrlRequest(httpMethod: "DELETE", path: "/v1/files/" + id)

        let (data, response) = try await session.data(for: request)

        let deletionStatus: DeletionStatus = try process(data: data, response: response)

        return deletionStatus.deleted
    }
}
