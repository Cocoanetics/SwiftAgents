//
//  ChatGPTCodexLiveTests.swift
//  ProvidersTests
//
//  Live smoke test against the real ChatGPT Codex backend, gated on the
//  `CODEX_HOME_DIR` environment variable (never set in CI). Reads a
//  codex-style auth.json from that directory, runs one minimal streamed
//  tool-call turn, and captures every request/response body through a
//  pass-through `URLProtocol` proxy so wire regressions can be diagnosed
//  against the codex-rs reference client.
//
//  Security: bearer tokens and account ids are NEVER printed or written.
//  The proxy strips `Authorization` and `ChatGPT-Account-ID` from
//  everything it records; only URLs, redacted headers, and JSON bodies
//  are logged. Set `CODEX_CAPTURE_DIR` to also dump the captures to
//  files for inspection.
//

import Foundation
@testable import Agents
@testable import Providers
import SwiftMCP
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Pass-through capture proxy

/// Forwards every request to the real network (auth headers intact) while
/// recording a redacted copy of the exchange.
private final class CodexLiveProxy: URLProtocol {
    struct Exchange {
        let url: String
        let redactedHeaders: [String: String]
        let requestBody: Data
        let statusCode: Int
        let responseBody: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var exchanges: [Exchange] = []

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        exchanges = []
    }

    static var recorded: [Exchange] {
        lock.lock()
        defer { lock.unlock() }
        return exchanges
    }

    private static func record(_ exchange: Exchange) {
        lock.lock()
        defer { lock.unlock() }
        exchanges.append(exchange)

        // Optional file dump for offline diffing against codex-rs.
        if let dir = ProcessInfo.processInfo.environment["CODEX_CAPTURE_DIR"] {
            let index = exchanges.count
            let base = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try? exchange.requestBody.write(to: base.appendingPathComponent("post\(index)-request.json"))
            try? exchange.responseBody.write(to: base.appendingPathComponent("post\(index)-response.sse"))
            let meta = "\(exchange.url)\nHTTP \(exchange.statusCode)\n\(exchange.redactedHeaders)\n"
            try? Data(meta.utf8).write(to: base.appendingPathComponent("post\(index)-meta.txt"))
        }
    }

    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.bodyData(from: request)
        var forwarded = request
        forwarded.httpBodyStream = nil
        forwarded.httpBody = body

        // Fully synchronous pass-through on the protocol's work thread —
        // no Task, no captures of non-Sendable state across regions. The
        // whole SSE body is buffered before being handed to the client.
        final class ResultBox: @unchecked Sendable {
            var data = Data()
            var response: HTTPURLResponse?
            var error: Error?
        }
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)

        // Plain configuration — no custom protocol classes, so no
        // recursion back into this proxy. Generous timeouts: codex
        // reasoning turns can take a while.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration)

        let task = session.dataTask(with: forwarded) { data, response, error in
            box.data = data ?? Data()
            box.response = response as? HTTPURLResponse
            box.error = error
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let error = box.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        var redacted: [String: String] = [:]
        for (key, value) in forwarded.allHTTPHeaderFields ?? [:] {
            let sensitive = ["authorization", "chatgpt-account-id"].contains(key.lowercased())
            redacted[key] = sensitive ? "<redacted>" : value
        }
        Self.record(Exchange(
            url: forwarded.url?.absoluteString ?? "",
            redactedHeaders: redacted,
            requestBody: body,
            statusCode: box.response?.statusCode ?? -1,
            responseBody: box.data
        ))

        if let response = box.response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: box.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 16384
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// MARK: - codex auth.json loading

/// Minimal reader for codex's `auth.json`. Token material never leaves
/// this struct except into the request authorizer.
private struct CodexHomeCredential {
    let accessToken: String
    let accountID: String?

    init?(homeDirectory: String) {
        let url = URL(fileURLWithPath: homeDirectory).appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String
        else {
            return nil
        }

        self.accessToken = accessToken

        // Prefer the `chatgpt_account_id` claim in the access token's JWT
        // payload; fall back to the top-level account_id.
        if let claims = Self.jwtPayload(accessToken),
           let auth = claims["https://api.openai.com/auth"] as? [String: Any],
           let accountID = auth["chatgpt_account_id"] as? String {
            self.accountID = accountID
        } else {
            accountID = tokens["account_id"] as? String
        }
    }

    private static func jwtPayload(_ token: String) -> [String: Any]? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - Test tool

@MCPServer
private final class CodexLiveTools {
    @MCPTool(description: "Returns the number of projects. Always call this first.")
    func get_project_count() -> String {
        "There are 7 projects."
    }
}

// MARK: - Live test

private let codexHomeDir = ProcessInfo.processInfo.environment["CODEX_HOME_DIR"]

/// Model slug for the live turn. Account catalogs differ — override with
/// `CODEX_LIVE_MODEL` if the default isn't enabled for the subscription.
private let codexLiveModel = ProcessInfo.processInfo.environment["CODEX_LIVE_MODEL"] ?? "gpt-5.6-luna"

@Suite(.serialized)
struct ChatGPTCodexLiveTests {
    @Test(
        "one live subscription turn with a tool call completes",
        .enabled(if: codexHomeDir != nil, "Requires CODEX_HOME_DIR pointing at a codex identity directory")
    )
    func liveToolCallTurn() async throws {
        let home = try #require(codexHomeDir)
        let credential = try #require(
            CodexHomeCredential(homeDirectory: home),
            "auth.json missing or unreadable in CODEX_HOME_DIR"
        )

        CodexLiveProxy.reset()
        let api = ChatGPTCodex(authorization: ChatGPTCodexAuthorization(
            accessToken: credential.accessToken,
            accountID: credential.accountID
        ))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexLiveProxy.self]
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 300
        let proxied = URLSession(configuration: configuration)
        api.session = proxied
        api.streamSession = proxied

        let agent = BasicAgent(
            name: "CodexLiveAgent",
            model: codexLiveModel,
            instructions: "Always call get_project_count first. Then answer in one short sentence.",
            toolProvider: [CodexLiveTools()]
        )

        let result = Runner.runStreamed(
            agent: agent,
            input: "How many projects are there? Call the tool, then say done.",
            maxTurns: 3,
            config: RunConfig(api: api)
        )

        var finalMessage = ""
        do {
            for try await event in result.events {
                if case let .runItemEvent(name: .messageOutputCreated, item: .message(text)) = event {
                    finalMessage = text
                }
            }
        } catch {
            Self.dumpExchanges()
            Issue.record("Live turn failed: \(error)")
            return
        }

        Self.dumpExchanges()
        #expect(!finalMessage.isEmpty, "expected a final assistant message")
        #expect(CodexLiveProxy.recorded.count >= 2, "expected the tool-call round trip (2 POSTs)")
        print("[codex-live] final message: \(finalMessage)")
    }

    /// Prints the redacted exchanges (bodies truncated) for diagnosis.
    private static func dumpExchanges() {
        for (index, exchange) in CodexLiveProxy.recorded.enumerated() {
            let requestBody = String(data: exchange.requestBody, encoding: .utf8) ?? "<binary>"
            let responseBody = String(data: exchange.responseBody, encoding: .utf8) ?? "<binary>"
            print("[codex-live] === POST \(index + 1) → \(exchange.url) [HTTP \(exchange.statusCode)]")
            print("[codex-live] request body: \(requestBody.prefix(6000))")
            print("[codex-live] response body: \(responseBody.prefix(6000))")
        }
    }
}
