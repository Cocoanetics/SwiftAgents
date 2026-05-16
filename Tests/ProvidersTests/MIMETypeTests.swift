import Foundation
@testable import Providers
import Testing

struct MIMETypeTests {
    @Test("URL MIME type resolves common extensions")
    func urlMIMETypeResolvesCommonExtensions() {
        #expect(URL(fileURLWithPath: "upload.txt").mimeType() == "text/plain")
        #expect(URL(fileURLWithPath: "photo.JPG").mimeType() == "image/jpeg")
        #expect(URL(fileURLWithPath: "document.pdf").mimeType() == "application/pdf")
        #if !canImport(UniformTypeIdentifiers)
        #expect(URL(fileURLWithPath: "payload.jsonl").mimeType() == "application/jsonl")
        #endif
    }

    @Test("URL MIME type falls back for unknown extension")
    func urlMIMETypeFallsBackForUnknownExtension() {
        #expect(URL(fileURLWithPath: "payload.unknown-extension").mimeType() == "application/octet-stream")
    }
}
