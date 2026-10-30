//
//  ImagesAPITests.swift
//
//  Offline coverage of the Images API client: size validation, the
//  model/quality/background matrix, request encoding (generate, edit, batch),
//  response decoding, error mapping and header parsing.
//

import Foundation
@testable import Providers
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Size validation

@Suite("Image size validation")
struct ImageSizeTests {
    @Test("auto and the recommended sizes are valid", arguments: ["auto", "1024x1024", "1536x1024", "1024x1536"])
    func validSizes(size: String) throws {
        #expect(try ImageSize(size).validate().isEmpty)
    }

    @Test("a custom size inside every limit is valid in both orientations", arguments: [
        "2048x1152", "1152x2048", "1536x864"
    ])
    func customSizes(size: String) throws {
        #expect(try ImageSize(size).validate().isEmpty)
    }

    @Test("each rule is named in the error", arguments: [
        ("1000x1000", "multiples of 16"),
        ("1024x1000", "multiples of 16"),
        ("4096x1024", "longest side"),
        ("1024x4096", "longest side"),
        ("3840x1024", "aspect ratio"),
        ("1024x3840", "aspect ratio"),
        ("256x256", "total pixels"),
        ("3840x2400", "total pixels"),
        ("wide", "WIDTHxHEIGHT"),
        ("0x1024", "positive")
    ])
    func violations(size: String, rule: String) {
        do {
            try ImageSize(size).validate()
            Issue.record("\(size) should be rejected")
        } catch let ImageGenerationError.invalidParameter(message) {
            #expect(message.contains(rule), "\(message) should name '\(rule)'")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("exactly 3:1 is allowed")
    func threeToOne() throws {
        #expect(try ImageSize("2304x768").validate().isEmpty)
        #expect(try ImageSize("768x2304").validate().isEmpty)
    }

    @Test("above 2560x1440 is allowed with an experimental note, at or below it is not flagged")
    func experimentalThreshold() throws {
        #expect(try ImageSize("2560x1440").validate().isEmpty)
        #expect(try ImageSize("1440x2560").validate().isEmpty)
        for size in ["3840x2160", "2160x3840", "2576x1440"] {
            let notes = try ImageSize(size).validate()
            #expect(notes.count == 1 && notes[0].contains("experimental"), "\(size)")
        }
    }

    @Test("dimensions parse WxH only")
    func dimensions() {
        #expect(ImageSize("2048x1152").dimensions?.width == 2048)
        #expect(ImageSize("2048X1152").dimensions == nil)
        #expect(ImageSize("+1024x+1024").dimensions == nil)
        #expect(ImageSize("1024x1024x2").dimensions == nil)
        #expect(ImageSize.auto.dimensions == nil)
    }
}

// MARK: - Model / quality / background matrix

@Suite("Image request validation")
struct ImageRequestValidationTests {
    private func message(_ request: ImageRequest) -> String? {
        do {
            try request.validate()
            return nil
        } catch let ImageGenerationError.invalidParameter(message) {
            return message
        } catch {
            return "unexpected \(error)"
        }
    }

    @Test("xhigh and max exist only on the 2.5 models", arguments: ["xhigh", "max"])
    func extendedQuality(quality: String) throws {
        for model in [ImageModel.sunburst, .flare] {
            try ImageRequest(prompt: "p", model: model, quality: ImageQuality(quality)).validate()
        }
        let text = try #require(message(ImageRequest(prompt: "p", model: .gptImage2, quality: ImageQuality(quality))))
        #expect(text.contains("2.5") && text.contains("gpt-image-2.5-sunburst"))
    }

    @Test("the common qualities work on every model", arguments: ["low", "medium", "high", "auto"])
    func commonQuality(quality: String) throws {
        for model in [ImageModel.sunburst, .flare, .gptImage2] {
            try ImageRequest(prompt: "p", model: model, quality: ImageQuality(quality)).validate()
        }
    }

    @Test("an unknown model passes through unchanged")
    func unknownModel() throws {
        let request = ImageRequest(prompt: "p", model: "gpt-image-9", quality: .max)
        try request.validate()
        let text = String(data: try request.jsonData(), encoding: .utf8) ?? ""
        #expect(text.contains("\"gpt-image-9\""))
    }

    @Test("transparent needs a 2.5 model and not jpeg")
    func transparency() throws {
        try ImageRequest(prompt: "p", model: .flare, background: .transparent, outputFormat: .png).validate()
        try ImageRequest(prompt: "p", model: .sunburst, background: .transparent, outputFormat: .webp).validate()
        try ImageRequest(prompt: "p", background: .transparent).validate()

        let jpeg = try #require(message(ImageRequest(prompt: "p", background: .transparent, outputFormat: .jpeg)))
        #expect(jpeg.contains("jpeg"))
        let legacy = try #require(message(ImageRequest(prompt: "p", model: .gptImage2, background: .transparent)))
        #expect(legacy.contains("gpt-image-2.5-sunburst"))
    }

    @Test("output_compression applies to jpeg and webp only, within 0-100")
    func compression() throws {
        try ImageRequest(prompt: "p", outputFormat: .jpeg, outputCompression: 80).validate()
        try ImageRequest(prompt: "p", outputFormat: .webp, outputCompression: 0).validate()
        #expect(message(ImageRequest(prompt: "p", outputFormat: .png, outputCompression: 80)) != nil)
        #expect(message(ImageRequest(prompt: "p", outputCompression: 80)) != nil)
        #expect(message(ImageRequest(prompt: "p", outputFormat: .jpeg, outputCompression: 101)) != nil)
    }

    @Test("prompt and n are checked")
    func promptAndCount() {
        #expect(message(ImageRequest(prompt: "  ")) != nil)
        #expect(message(ImageRequest(prompt: "p", n: 0)) != nil)
        #expect(message(ImageRequest(prompt: "p", n: 11)) != nil)
    }

    @Test("a size violation or experimental size surfaces through the request")
    func sizeThroughRequest() throws {
        #expect(message(ImageRequest(prompt: "p", size: "1000x1000")) != nil)
        #expect(try ImageRequest(prompt: "p", size: "3840x2160").validate().count == 1)
    }
}

// MARK: - Encoding

@Suite("Image request encoding")
struct ImageEncodingTests {
    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("generate encodes snake_case and omits unset fields")
    func generateBody() throws {
        let request = ImageRequest(
            prompt: "a fox", model: .flare, size: "2048x1152", quality: .low, background: .opaque,
            outputFormat: .jpeg, outputCompression: 70, moderation: .low, n: 2
        )
        let json = try object(request.jsonData())
        #expect(json["model"] as? String == "gpt-image-2.5-flare")
        #expect(json["size"] as? String == "2048x1152")
        #expect(json["quality"] as? String == "low")
        #expect(json["background"] as? String == "opaque")
        #expect(json["output_format"] as? String == "jpeg")
        #expect(json["output_compression"] as? Int == 70)
        #expect(json["moderation"] as? String == "low")
        #expect(json["n"] as? Int == 2)

        let minimal = try object(ImageRequest(prompt: "a fox").jsonData())
        #expect(minimal.keys.sorted() == ["model", "n", "prompt"])
        #expect(minimal["model"] as? String == "gpt-image-2.5-sunburst")
    }

    @Test("edit is multipart with image[] parts, an optional mask and never input_fidelity")
    func editBody() throws {
        let edit = ImageEditRequest(
            request: ImageRequest(prompt: "add a hat", model: .sunburst, size: "1024x1024", quality: .low),
            images: [
                ImageInput(data: Data([1, 2, 3]), filename: "a.png"),
                ImageInput(data: Data([4, 5]), filename: "b.jpg")
            ],
            mask: ImageInput(data: Data([9]), filename: "mask.png")
        )
        let form = edit.multipartBody()
        let body = String(data: form.encoded(), encoding: .utf8) ?? ""

        #expect(form.contentType == "multipart/form-data; boundary=\(form.boundary)")
        #expect(body.hasPrefix("--\(form.boundary)\r\n"))
        #expect(body.hasSuffix("--\(form.boundary)--\r\n"))
        #expect(body.contains("name=\"model\"\r\n\r\ngpt-image-2.5-sunburst\r\n"))
        #expect(body.contains("name=\"prompt\"\r\n\r\nadd a hat\r\n"))
        #expect(body.contains("name=\"size\"\r\n\r\n1024x1024\r\n"))
        #expect(body.contains("name=\"quality\"\r\n\r\nlow\r\n"))
        #expect(body.components(separatedBy: "name=\"image[]\"").count == 3)
        #expect(body.contains("filename=\"a.png\"\r\nContent-Type: image/png"))
        #expect(body.contains("filename=\"b.jpg\"\r\nContent-Type: image/jpeg"))
        #expect(body.contains("name=\"mask\"; filename=\"mask.png\""))
        #expect(!body.contains("input_fidelity"))
    }

    @Test("an edit needs an image")
    func editNeedsImage() {
        #expect(throws: ImageGenerationError.self) {
            try ImageEditRequest(request: ImageRequest(prompt: "p"), images: []).validate()
        }
    }

    @Test("an edit takes at most 16 images")
    func editImageLimit() throws {
        let image = ImageInput(data: Data([1]), filename: "a.png")
        let request = ImageRequest(prompt: "p")
        try ImageEditRequest(request: request, images: Array(repeating: image, count: 16)).validate()
        #expect(throws: ImageGenerationError.self) {
            try ImageEditRequest(request: request, images: Array(repeating: image, count: 17)).validate()
        }
    }

    @Test("batch lines override the defaults, blank lines and comments are skipped")
    func batchParsing() throws {
        let jsonl = """
        # first
        {"prompt": "one", "size": "1536x1024", "out": "one.png"}

        {"prompt": "two", "model": "gpt-image-2", "quality": "high", "output_format": "webp", "n": 2}
        {"out": "default-prompt.png"}
        """
        let defaults = ImageRequest(prompt: "fallback", model: .flare, size: "1024x1024", quality: .low)
        let jobs = try ImageBatchJob.parse(jsonl: jsonl, defaults: defaults)

        #expect(jobs.count == 3)
        #expect(jobs[0].request.prompt == "one")
        #expect(jobs[0].request.model == .flare)
        #expect(jobs[0].request.size == "1536x1024")
        #expect(jobs[0].request.quality == .low)
        #expect(jobs[0].out == "one.png")
        #expect(jobs[1].request.model == .gptImage2)
        #expect(jobs[1].request.quality == .high)
        #expect(jobs[1].request.outputFormat == .webp)
        #expect(jobs[1].request.n == 2)
        #expect(jobs[1].out == nil)
        #expect(jobs[2].request.prompt == "fallback")
    }

    @Test("a batch line without any prompt, or that is not JSON, names its line")
    func batchErrors() {
        for (jsonl, line) in [("{\"size\": \"auto\"}", "line 1"), ("{\"prompt\": \"a\"}\nnot json", "line 2")] {
            do {
                _ = try ImageBatchJob.parse(jsonl: jsonl, defaults: ImageRequest(prompt: ""))
                Issue.record("expected an error")
            } catch let ImageGenerationError.invalidParameter(message) {
                #expect(message.contains(line))
            } catch {
                Issue.record("unexpected error \(error)")
            }
        }
    }
}

// MARK: - Decoding

@Suite("Image response decoding")
struct ImageDecodingTests {
    private let openAI = OpenAI(credential: Credential.bearer("test-key"))

    @Test("b64_json, usage and the resolved settings decode")
    func decodesResponse() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let json = """
        {"created": 1700000000,
         "data": [{"b64_json": "\(png.base64EncodedString())", "revised_prompt": "a red fox"}],
         "size": "1536x864", "quality": "low", "background": "opaque", "output_format": "png",
         "usage": {"input_tokens": 12, "output_tokens": 1056, "total_tokens": 1068,
                   "input_tokens_details": {"text_tokens": 12, "image_tokens": 0}}}
        """
        let response = try openAI.decoder.decode(ImagesResponse.self, from: Data(json.utf8))
        let result = try response.result(
            for: ImageRequest(prompt: "fox", size: "auto"), notes: ["n"], requestID: "req_1"
        )

        #expect(result.images.count == 1)
        #expect(result.images[0].data == png)
        #expect(result.images[0].revisedPrompt == "a red fox")
        #expect(result.size == "1536x864")
        #expect(result.quality == "low")
        #expect(result.background == "opaque")
        #expect(result.outputFormat == "png")
        #expect(result.usage?.inputTokens == 12)
        #expect(result.usage?.outputTokens == 1056)
        #expect(result.usage?.totalTokens == 1068)
        #expect(result.usage?.inputTokensDetails?.textTokens == 12)
        #expect(result.usage?.inputTokensDetails?.imageTokens == 0)
        #expect(result.notes == ["n"])
        #expect(result.requestID == "req_1")
    }

    @Test("settings the API doesn't echo fall back to the request")
    func fallsBackToRequest() throws {
        let json = "{\"data\": [{\"b64_json\": \"AAEC\"}]}"
        let response = try openAI.decoder.decode(ImagesResponse.self, from: Data(json.utf8))
        let result = try response.result(
            for: ImageRequest(prompt: "p", size: "1024x1024", quality: .high, outputFormat: .webp),
            notes: [], requestID: nil
        )
        #expect(result.size == "1024x1024")
        #expect(result.quality == "high")
        #expect(result.outputFormat == "webp")
        #expect(result.usage == nil)
    }

    @Test("an item without b64_json is an invalid response")
    func missingImage() throws {
        let response = try openAI.decoder.decode(ImagesResponse.self, from: Data("{\"data\": [{}]}".utf8))
        #expect(throws: ImageGenerationError.self) {
            try response.result(for: ImageRequest(prompt: "p"), notes: [], requestID: nil)
        }
    }
}

// MARK: - Image headers

@Suite("Image header parsing")
struct ImageInfoTests {
    private func beBytes(_ value: Int) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private func png(width: Int, height: Int, colorType: UInt8, trns: Bool = false) -> Data {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes += beBytes(13) + Array("IHDR".utf8) + beBytes(width) + beBytes(height) + [8, colorType, 0, 0, 0]
        bytes += [0, 0, 0, 0]
        if trns { bytes += beBytes(1) + Array("tRNS".utf8) + [0, 0, 0, 0, 0] }
        bytes += beBytes(0) + Array("IDAT".utf8) + [0, 0, 0, 0]
        return Data(bytes)
    }

    @Test("PNG size and alpha")
    func pngInfo() throws {
        let rgba = try #require(ImageInfo(data: png(width: 2048, height: 1152, colorType: 6)))
        #expect(rgba == ImageInfo(data: png(width: 2048, height: 1152, colorType: 6)))
        #expect(rgba.width == 2048 && rgba.height == 1152 && rgba.hasAlpha)
        #expect(try #require(ImageInfo(data: png(width: 4, height: 2, colorType: 2))).hasAlpha == false)
        #expect(try #require(ImageInfo(data: png(width: 4, height: 2, colorType: 3, trns: true))).hasAlpha)
    }

    @Test("JPEG size")
    func jpegInfo() throws {
        let bytes: [UInt8] = [
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0, 0, 0xFF, 0xC0, 0x00, 0x11, 8, 0x04, 0x00, 0x06, 0x00
        ]
        let info = try #require(ImageInfo(data: Data(bytes)))
        #expect(info.width == 1536 && info.height == 1024 && !info.hasAlpha)
    }

    @Test("WebP size and alpha (VP8X)")
    func webpInfo() throws {
        var bytes = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8) + Array("VP8X".utf8) + [10, 0, 0, 0]
        bytes += [0x10, 0, 0, 0, 0xFF, 0x03, 0, 0xFF, 0x01, 0]
        let info = try #require(ImageInfo(data: Data(bytes)))
        #expect(info.width == 1024 && info.height == 512 && info.hasAlpha)
    }

    @Test("anything else is nil")
    func unknown() {
        #expect(ImageInfo(data: Data([1, 2, 3])) == nil)
    }
}

// MARK: - Client (stubbed transport)

/// Records the request and answers with a scripted response.
private final class ImagesStub: URLProtocol {
    struct Reply {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var reply = Reply(status: 200, headers: [:], body: Data())
    nonisolated(unsafe) private static var seen: [Seen] = []

    struct Seen {
        var url: URL
        var contentType: String?
        var auth: String?
        var body: Data
    }

    static func script(_ reply: Reply) {
        lock.lock()
        defer { lock.unlock() }
        self.reply = reply
        seen = []
    }

    static var requests: [Seen] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        Self.lock.lock()
        Self.seen.append(Seen(
            url: request.url!,
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            auth: request.value(forHTTPHeaderField: "Authorization"),
            body: body
        ))
        let reply = Self.reply
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Images API client", .serialized)
struct ImagesClientTests {
    private func makeClient() -> OpenAI {
        let api = OpenAI(credential: Credential.bearer("sk-test"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImagesStub.self]
        api.session = URLSession(configuration: configuration)
        return api
    }

    private let okBody = Data(
        "{\"data\": [{\"b64_json\": \"AAEC\"}], \"size\": \"1536x864\", \"quality\": \"low\"}".utf8
    )

    @Test("generate posts JSON to /v1/images/generations with the bearer key and reports the request id")
    func generate() async throws {
        ImagesStub.script(.init(status: 200, headers: ["x-request-id": "req_ok"], body: okBody))
        let result = try await makeClient().generateImages(
            ImageRequest(prompt: "a fox", model: .flare, size: "1536x864", quality: .low)
        )

        let sent = try #require(ImagesStub.requests.first)
        #expect(sent.url.path == "/v1/images/generations")
        #expect(sent.contentType == "application/json")
        #expect(sent.auth == "Bearer sk-test")
        let json = try #require(try JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        #expect(json["model"] as? String == "gpt-image-2.5-flare")
        #expect(json["size"] as? String == "1536x864")
        #expect(result.images.first?.data == Data([0, 1, 2]))
        #expect(result.requestID == "req_ok")
        #expect(result.size == "1536x864")
    }

    @Test("edit posts multipart to /v1/images/edits")
    func edit() async throws {
        ImagesStub.script(.init(status: 200, headers: [:], body: okBody))
        _ = try await makeClient().editImages(ImageEditRequest(
            request: ImageRequest(prompt: "hat"), images: [ImageInput(data: Data([7]), filename: "a.png")]
        ))
        let sent = try #require(ImagesStub.requests.first)
        #expect(sent.url.path == "/v1/images/edits")
        #expect(sent.contentType?.hasPrefix("multipart/form-data; boundary=") == true)
        let text = String(data: sent.body, encoding: .utf8) ?? ""
        #expect(text.contains("name=\"image[]\"; filename=\"a.png\""))
    }

    @Test("an invalid request is rejected before anything is sent")
    func invalidSendsNothing() async {
        ImagesStub.script(.init(status: 200, headers: [:], body: okBody))
        await #expect(throws: ImageGenerationError.self) {
            _ = try await makeClient().generateImages(ImageRequest(prompt: "p", size: "1000x1000"))
        }
        #expect(ImagesStub.requests.isEmpty)
    }

    @Test("an API error maps to a typed error carrying x-request-id")
    func apiError() async throws {
        let body = Data(
            ("{\"error\": {\"message\": \"bad size\", \"type\": \"invalid_request_error\", " +
                "\"param\": \"size\", \"code\": \"invalid_size\"}}").utf8
        )
        ImagesStub.script(.init(status: 400, headers: ["x-request-id": "req_bad"], body: body))
        do {
            _ = try await makeClient().generateImages(ImageRequest(prompt: "p"))
            Issue.record("expected an error")
        } catch let ImageGenerationError.api(error) {
            #expect(error.statusCode == 400)
            #expect(error.message == "bad size")
            #expect(error.type == "invalid_request_error")
            #expect(error.code == "invalid_size")
            #expect(error.param == "size")
            #expect(error.requestID == "req_bad")
            #expect(error.description.contains("req_bad"))
        }
    }

    @Test("a batch runs every job, reports each result in order and bounds concurrency")
    func batch() async {
        let jobs = (0..<6).map { ImageBatchJob(request: ImageRequest(prompt: "p\($0)"), out: "\($0).png") }
        let tracker = ConcurrencyTracker()
        let results = await makeClient().generateImageBatch(jobs, concurrency: 2) { index, job in
            await tracker.enter()
            try await Task.sleep(nanoseconds: 20_000_000)
            await tracker.leave()
            if index == 3 { throw ImageGenerationError.serverError }
            return ImageResult(images: [], size: job.out, quality: nil, background: nil, outputFormat: nil,
                               usage: nil, notes: [], requestID: nil)
        }
        #expect(results.map(\.index) == [0, 1, 2, 3, 4, 5])
        #expect(await tracker.peak <= 2)
        for result in results {
            switch result.outcome {
                case let .success(value): #expect(result.index != 3 && value.size == "\(result.index).png")
                case .failure: #expect(result.index == 3)
            }
        }
    }
}

private actor ConcurrencyTracker {
    private var running = 0
    private(set) var peak = 0
    func enter() {
        running += 1
        peak = max(peak, running)
    }

    func leave() { running -= 1 }
}
