import Foundation
import JSONFoundation

public extension API {
    func createStructuredChatCompletion<T: Decodable & SchemaRepresentable>(
        model: String,
        messages: [ChatMessage]
    ) async throws -> T {
        let completion = try await createChatCompletion(
            model: model,
            messages: messages,
            responseFormat: .jsonSchema(T.jsonSchema)
        )

        guard let jsonString = completion.choices.first?.message.textContent,
            let data = jsonString.data(using: .utf8) else {
            throw APIError.invalidResponse
        }

        // Decode via the shared configured decoder (ISO-8601 dates etc.) —
        // the schema maps `Date` to string/date-time, which the default
        // `.deferredToDate` strategy would always reject.
        return try JSONCoding.makeDecoder().decode(T.self, from: data)
    }

    func withRetry<T>(maxRetries: Int = 3, operation: @escaping () async throws -> T) async throws -> T {
        var lastError: Error?

        for attempt in 0 ..< maxRetries {
            do {
                return try await operation()
            } catch {
                lastError = error
                print("Attempt \(attempt + 1) failed: \(error)")

                if attempt == maxRetries - 1 {
                    throw error
                }

                // Wait before retrying (exponential backoff)
                try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 1_000_000_000))
            }
        }

        throw lastError ?? APIError.invalidResponse
    }
}
