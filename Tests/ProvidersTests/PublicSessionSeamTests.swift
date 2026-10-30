//
//  PublicSessionSeamTests.swift
//  ProvidersTests
//
//  Stubs HTTP through the public `URLSessionConfiguration` seam on `API`.
//  Deliberately a plain `import Providers` (no `@testable`): this is what a
//  package depending on SwiftAgents can do.
//

import Foundation
import Providers
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Answers `/images/generations` with JSON and `/responses` with an SSE body,
/// recording the request paths it sees.
private final class SeamStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seenPaths: [String] = []

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        seenPaths = []
    }

    static var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return seenPaths
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SeamStub.self]
        return configuration
    }

    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.seenPaths.append(url.path)
        Self.lock.unlock()

        let isStream = url.path.hasSuffix("/responses")
        let body: String
        if isStream {
            let completed = #"{"type":"response.completed","response":{"id":"resp_1","object":"response","#
                + #""created_at":1700000000,"status":"completed","model":"gpt-test","output":[],"#
                + #""parallel_tool_calls":true,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[]}}"#
            body = "data: \(completed)\n\ndata: [DONE]\n\n"
        } else {
            body = #"{"data":[{"b64_json":"AAEC"}],"size":"1024x1024"}"#
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": isStream ? "text/event-stream" : "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Public session configuration seam", .serialized)
struct PublicSessionSeamTests {
    private func assertImagesAndStream(_ api: OpenAI) async throws {
        SeamStub.reset()

        let result = try await api.generateImages(ImageRequest(prompt: "a cat"))
        #expect(result.images.first?.data == Data([0, 1, 2]))

        let stream = try await api.createResponseStream(input: .text("hi"), model: "gpt-test")
        var events = 0
        for try await _ in stream { events += 1 }
        #expect(events > 0)

        #expect(SeamStub.paths == ["/v1/images/generations", "/v1/responses"])
    }

    @Test("init(configuration:) stubs the Images API and a streamed Responses call")
    func initConfiguration() async throws {
        let api = OpenAI(credential: Credential.bearer("sk-test"), configuration: SeamStub.configuration())
        try await assertImagesAndStream(api)
    }

    @Test("use(sessionConfiguration:) re-points an existing client")
    func useSessionConfiguration() async throws {
        let api = OpenAI(credential: Credential.bearer("sk-test"))
        api.use(sessionConfiguration: SeamStub.configuration())
        try await assertImagesAndStream(api)
    }

    @Test("an explicit streamConfiguration is used for streaming")
    func explicitStreamConfiguration() async throws {
        let api = OpenAI(
            credential: Credential.bearer("sk-test"),
            configuration: SeamStub.configuration(),
            streamConfiguration: SeamStub.configuration()
        )
        try await assertImagesAndStream(api)
    }
}
