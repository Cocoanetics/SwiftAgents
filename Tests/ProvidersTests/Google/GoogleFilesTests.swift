import Foundation
@testable import Providers
import Testing

struct GoogleFilesTests {
    @Test("Google file lifecycle", .enabled(if: APIKey.hasGemini, "Requires GEMINI_API_KEY"))
    func uploadListRetrieveDeleteFile() async throws {
        let google = try GoogleAPI(apiKey: #require(APIKey.gemini as String?))
        let data = sampleImageData()
        let uploaded = try await google.uploadFile(data: data, filename: "files-test.png", mimeType: "image/png")
        guard let uri = uploaded.name else {
            #expect(Bool(false), "Uploaded file missing name")
            return
        }
        let retrieved = try await google.retrieveFile(uri: uri)
        #expect(retrieved.name == uri)
        let files = try await google.listFiles()
        #expect(files.contains { $0.name == uri })
        let deleted = try await google.deleteFile(uri: uri)
        #expect(deleted)
    }

    // MARK: - Helpers

    private func sampleImageData() -> Data {
        guard let url = Bundle.module.url(forResource: "vision-test", withExtension: "png"),
            let data = try? Data(contentsOf: url) else {
            fatalError("vision-test.png fixture is required")
        }
        return data
    }
}
