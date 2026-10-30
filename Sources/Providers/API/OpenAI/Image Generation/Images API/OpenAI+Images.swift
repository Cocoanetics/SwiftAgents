//
//  OpenAI+Images.swift
//
//  Generate and edit images through the Images API with exact control over
//  model, size, quality, background and format.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public extension OpenAI {
    /// Generates images via `/v1/images/generations`.
    ///
    /// The request is validated first; a violation throws and nothing is sent.
    func generateImages(_ request: ImageRequest) async throws -> ImageResult {
        let notes = try request.validate()
        var urlRequest = try createUrlRequest(httpMethod: "POST", path: "/\(versionPath)/images/generations")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try request.jsonData()
        return try await performImageRequest(urlRequest, for: request, notes: notes)
    }

    /// Edits images via `/v1/images/edits` (multipart), from one or more reference
    /// images and an optional mask for the first.
    func editImages(_ edit: ImageEditRequest) async throws -> ImageResult {
        let notes = try edit.validate()
        var urlRequest = try createUrlRequest(httpMethod: "POST", path: "/\(versionPath)/images/edits")
        let form = edit.multipartBody()
        urlRequest.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = form.encoded()
        return try await performImageRequest(urlRequest, for: edit.request, notes: notes)
    }

    private func performImageRequest(
        _ urlRequest: URLRequest,
        for request: ImageRequest,
        notes: [String]
    ) async throws -> ImageResult {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw ImageGenerationError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ImageGenerationError.invalidResponse("not an HTTP response")
        }
        let requestID = http.value(forHTTPHeaderField: "x-request-id")

        guard http.statusCode == 200 else {
            let error = imageAPIError(data: data, statusCode: http.statusCode, requestID: requestID)
            throw ImageGenerationError.api(error)
        }
        do {
            let decoded = try decoder.decode(ImagesResponse.self, from: data)
            return try decoded.result(for: request, notes: notes, requestID: requestID)
        } catch let error as ImageGenerationError {
            throw error
        } catch {
            throw ImageGenerationError.invalidResponse("could not decode the response: \(error.localizedDescription)")
        }
    }

    private func imageAPIError(data: Data, statusCode: Int, requestID: String?) -> ImageAPIError {
        if let body = try? decoder.decode(ErrorResponse.self, from: data) {
            return ImageAPIError(
                statusCode: statusCode,
                message: body.error.message,
                type: body.error.type,
                code: body.error.code,
                param: body.error.param,
                requestID: requestID
            )
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return ImageAPIError(statusCode: statusCode, message: text, requestID: requestID)
    }
}
