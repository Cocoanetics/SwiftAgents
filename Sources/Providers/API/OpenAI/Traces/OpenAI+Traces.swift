//
//  OpenAI+Traces.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 30.04.25.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SwiftMCP

extension OpenAI {
    /// Sends trace data to the OpenAI traces API
    /// - Parameters:
    ///   - traceData: Array of trace data to send
    /// - Returns: Empty response if successful
    /// - Throws: Error if the request fails
    public func ingestTraces(_ traceData: [[String: JSONValue]]) async throws {
        struct TraceIngest: Codable {
            public let data: [[String: JSONValue]]
        }

        // Wrap the trace data in a TraceIngest struct
        let ingest = TraceIngest(data: traceData)

        // Create a custom encoder for traces with proper ISO date formatting
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let string = formatter.string(from: date)
            var container = encoder.singleValueContainer()
            try container.encode(string)
        }
        encoder.keyEncodingStrategy = .convertToSnakeCase

        // Encode the trace ingest data
        let jsonData = try encoder.encode(ingest)

        // Create and configure the URL request
        let path = "/v1/traces/ingest"
        var request = try createTraceUrlRequest(path: path, body: jsonData)

        // Add the special traces beta header
        request.setValue("traces=v1", forHTTPHeaderField: "OpenAI-Beta")

        // Set the content type
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Send the request
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let response = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard 200 ..< 300 ~= response.statusCode else {
            throw errorFromResponse(data: data, response: response)
        }
    }

    /// Helper method to create a URL request specifically for trace ingestion
    private func createTraceUrlRequest(path: String, body: Data) throws -> URLRequest {
        // Create the URL from the base endpoint and the specific path
        guard let urlComponents = URLComponents(url: endpointURL.appending(path: path), resolvingAgainstBaseURL: true)
        else {
            throw URLError(.badURL)
        }

        guard let url = urlComponents.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        // Authorize with the client's credential.
        credential?.authorize(&request)

        // Set the HTTP body directly from the provided encoded data
        request.httpBody = body

        return request
    }
}
