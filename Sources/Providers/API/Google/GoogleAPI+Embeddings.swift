//
//  GoogleAPI+Embeddings.swift
//  SwiftAgents
//
//  Gemini `:embedContent` endpoint. Two model generations with different
//  role mechanics:
//    - `gemini-embedding-001` takes the task as an API parameter
//      (`taskType`, e.g. RETRIEVAL_QUERY vs RETRIEVAL_DOCUMENT).
//    - `gemini-embedding-2` dropped `taskType`; the task travels as a
//      prompt instruction instead (the EmbeddingGemma retrieval format,
//      applied by `EmbeddingTaskPrefix` on the role-aware path).
//  Both are Matryoshka-trained: `outputDimensionality` truncates the
//  default 3072-d vector (768/1536/3072 recommended).
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Task types accepted by `gemini-embedding-001`'s `taskType` parameter.
/// Not supported by `gemini-embedding-2`, which expects the task as a
/// prompt instruction instead.
public enum GoogleEmbeddingTaskType: String, Codable, Sendable {
    case semanticSimilarity = "SEMANTIC_SIMILARITY"
    case classification = "CLASSIFICATION"
    case clustering = "CLUSTERING"
    case retrievalDocument = "RETRIEVAL_DOCUMENT"
    case retrievalQuery = "RETRIEVAL_QUERY"
    case codeRetrievalQuery = "CODE_RETRIEVAL_QUERY"
    case questionAnswering = "QUESTION_ANSWERING"
    case factVerification = "FACT_VERIFICATION"
}

struct GoogleEmbedContentRequest: Codable, Sendable {
    struct Content: Codable, Sendable {
        struct Part: Codable, Sendable {
            let text: String
        }

        let parts: [Part]
    }

    let content: Content
    let taskType: GoogleEmbeddingTaskType?
    let outputDimensionality: Int?
}

struct GoogleEmbedContentResponse: Codable, Sendable {
    struct Embedding: Codable, Sendable {
        let values: [Double]
    }

    let embedding: Embedding
}

public extension GoogleAPI {
    /// Embeds `text` via `models/{model}:embedContent` and returns the raw
    /// vector. `taskType` only applies to `gemini-embedding-001`;
    /// `outputDimensionality` truncates the Matryoshka embedding (callers
    /// should re-normalize — `gemini-embedding-001` does not normalize
    /// truncated vectors server-side).
    func embedContent(
        _ text: String,
        model: String,
        taskType: GoogleEmbeddingTaskType? = nil,
        outputDimensionality: Int? = nil
    ) async throws -> Vector {
        let payload = GoogleEmbedContentRequest(
            content: .init(parts: [.init(text: text)]),
            taskType: taskType,
            outputDimensionality: outputDimensionality
        )
        let request = try createUrlRequest(
            httpMethod: "POST",
            path: "v1beta/models/\(model):embedContent",
            body: payload
        )
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw googleError(from: data, response: response)
        }
        return try decoder.decode(GoogleEmbedContentResponse.self, from: data).embedding.values
    }
}
