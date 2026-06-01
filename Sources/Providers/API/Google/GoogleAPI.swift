//
//  GoogleAPI.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 25.01.25.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SwiftMCP

/// User-facing image configuration for Gemini image generation.
public struct GoogleImageConfig: Sendable {
    public let aspectRatio: String?
    public let imageSize: String?

    public init(aspectRatio: String? = nil, imageSize: String? = nil) {
        self.aspectRatio = aspectRatio
        self.imageSize = imageSize
    }
}

public class GoogleAPI: API, @unchecked Sendable {
    /// Default thinking configuration to apply to requests if none is provided.
    public var defaultThinkingConfig: GoogleThinkingConfig?

    // MARK: - Initialization

    override public init(apiKey: String? = nil, endpointURL: URL = .googleAI, versionPath: String = "v1beta") {
        super.init(
            apiKey: apiKey ?? ProcessInfo.processInfo.environment["GEMINI_API_KEY"],
            endpointURL: endpointURL,
            versionPath: versionPath
        )
        defaultThinkingConfig = GoogleThinkingConfig(includeThoughts: true)
    }

    override public func models() async throws -> [Model] {
        var components = URLComponents(
            url: endpointURL.appendingPathComponent("v1beta/models"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey)
        ]

        let request = URLRequest(url: components.url!)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw APIError.otherError("other", "Not implemented")
        }

        let decoder = JSONDecoder()

        let modelList = try decoder.decode(GoogleModelListResponse.self, from: data)

        return modelList.models.filter { googleModel in
            googleModel.supportedGenerationMethods.contains("generateContent")
        }.map { googleModel in
            let id = String(googleModel.name.split(separator: "/").last ?? "")

            return Model(id: id, object: "model", created: nil, ownedBy: nil, permission: nil, root: nil, parent: nil)
        }
    }

    override public func createChatCompletion(
        model: String,
        messages: [ChatMessage],
        tools: [ToolDescription]? = nil,
        toolChoice: ToolChoice? = nil,
        n: Int? = nil,
        stop: [String]? = nil,
        store: Bool? = nil,
        temperature: Double? = nil,
        maxCompletionTokens: Int? = nil,
        metadata: [String: String]? = nil,
        parallelToolCalls: Bool? = nil,
        presencePenalty: Double? = nil,
        responseFormat: ChatCompletionRequest.ResponseFormat? = nil,
        frequencyPenalty: Double? = nil,
        logitBias: [String: Int]? = nil,
        user: String? = nil,
        options: GenerationOptions? = nil
    ) async throws -> ChatCompletionResponse {
        // Realize the neutral media intent as Gemini's request shape:
        // `responseModalities` lists *every* requested modality (so a
        // text+image request keeps its textual answer, not just the image),
        // and `imageConfig` carries any portable sizing. An `.image` request
        // with no sizing still flips the modality but sends no imageConfig.
        let media = options?.requestedMedia ?? []
        let imageConfig: GoogleImageConfig? = media.firstImageOptions.flatMap { options in
            guard options.size != nil || options.aspectRatio != nil else { return nil }
            return GoogleImageConfig(aspectRatio: options.aspectRatio, imageSize: options.size)
        }
        let modalities = Self.googleResponseModalities(for: media)
        let responseModalities: [String]? = modalities.isEmpty ? nil : modalities

        return try await createChatCompletion(
            model: model,
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            n: n,
            stop: stop,
            store: store,
            temperature: temperature,
            maxCompletionTokens: maxCompletionTokens,
            metadata: metadata,
            parallelToolCalls: parallelToolCalls,
            presencePenalty: presencePenalty,
            responseFormat: responseFormat,
            frequencyPenalty: frequencyPenalty,
            logitBias: logitBias,
            user: user,
            thinkingConfig: nil,
            imageConfig: imageConfig,
            responseModalities: responseModalities
        )
    }

    public func createChatCompletion(
        model: String,
        messages: [ChatMessage],
        tools: [ToolDescription]? = nil,
        toolChoice _: ToolChoice? = nil,
        n _: Int? = nil,
        stop _: [String]? = nil,
        store _: Bool? = nil,
        temperature _: Double? = nil,
        maxCompletionTokens _: Int? = nil,
        metadata _: [String: String]? = nil,
        parallelToolCalls _: Bool? = nil,
        presencePenalty _: Double? = nil,
        responseFormat: ChatCompletionRequest.ResponseFormat? = nil,
        frequencyPenalty _: Double? = nil,
        logitBias _: [String: Int]? = nil,
        user _: String? = nil,
        thinkingConfig: GoogleThinkingConfig? = nil,
        imageConfig: GoogleImageConfig? = nil,
        responseModalities: [String]? = nil
    ) async throws -> ChatCompletionResponse {
        let thinking = thinkingConfig ?? defaultThinkingConfig
        let requestPayload = buildGenerateContentRequest(
            from: messages,
            tools: tools,
            thinkingConfig: thinking,
            imageConfig: imageConfig.map { GoogleGenerateContentRequest.ImageConfig(
                aspectRatio: $0.aspectRatio,
                imageSize: $0.imageSize
            ) },
            responseModalities: responseModalities,
            responseFormat: responseFormat
        )
        let endpoint = "v1beta/models/\(model):generateContent"
        let request = try createUrlRequest(httpMethod: "POST", path: endpoint, body: requestPayload)
        let (data, response) = try await session.data(for: request)
        return try makeChatCompletionResponse(model: model, data: data, response: response)
    }

    /// Generate content using pure Google types (preserves thought signatures)
    public func generateContent(
        model: String,
        request: GoogleGenerateContentRequest
    ) async throws -> GoogleGenerateContentResponse {
        let endpoint = "v1beta/models/\(model):generateContent"
        let urlRequest = try createUrlRequest(httpMethod: "POST", path: endpoint, body: request)

        // Save request JSON with timestamp
        let timestamp = Int(Date().timeIntervalSince1970)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let requestData = try? encoder.encode(request),
            let requestString = String(data: requestData, encoding: .utf8) {
            let requestURL = URL(fileURLWithPath: "/tmp/google_request_\(timestamp).json")
            try? requestString.write(to: requestURL, atomically: true, encoding: .utf8)
        }

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let errorResponse = try? decoder.decode(GoogleErrorResponse.self, from: data) {
                let type = errorResponse.error.status ?? "\(errorResponse.error.code)"
                throw APIError.otherError(type, errorResponse.error.message)
            }

            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.otherError("\(httpResponse.statusCode)", message)
        }

        // Save response JSON with same timestamp
        if let responseString = String(data: data, encoding: .utf8) {
            let responseURL = URL(fileURLWithPath: "/tmp/google_response_\(timestamp).json")
            try? responseString.write(to: responseURL, atomically: true, encoding: .utf8)
        }

        let responsePayload = try decoder.decode(GoogleGenerateContentResponse.self, from: data)

        // Extract and save images from response
        for (index, candidate) in responsePayload.candidates.enumerated() {
            guard let content = candidate.content else { continue }

            for (partIndex, part) in content.parts.enumerated() {
                if let inlineData = part.inlineData {
                    let fileExtension = inlineData.mimeType.preferredFilenameExtension() ?? "png"

                    let filename =
                        "google_response_\(timestamp)_candidate\(index)_part\(partIndex).\(fileExtension)"
                    let imageURL = URL(fileURLWithPath: "/tmp/\(filename)")
                    try? inlineData.data.write(to: imageURL)
                }
            }
        }

        return responsePayload
    }

    override public func createChatCompletionStream(
        model _: String,
        messages _: [ChatMessage],
        tools _: [ToolDescription]? = nil,
        toolChoice _: ToolChoice? = nil,
        n _: Int = 1,
        streamOptions _: ChatCompletionRequest.StreamOptions? = nil,
        stop _: [String]? = nil,
        store _: Bool? = nil,
        temperature _: Double? = nil,
        maxCompletionTokens _: Int? = nil,
        metadata _: [String: String]? = nil,
        parallelToolCalls _: Bool? = nil,
        presencePenalty _: Double = 0.0,
        responseFormat _: ChatCompletionRequest.ResponseFormat? = nil,
        frequencyPenalty _: Double = 0.0,
        logitBias _: [String: Int]? = nil,
        user _: String? = nil
    ) async throws -> AsyncThrowingStream<Chunk, Error> {
        throw APIError.otherError("unsupported", "Streaming is not supported for Google models yet")
    }

    // MARK: - Helpers

    override open func createUrlRequest(
        httpMethod: String = "GET",
        path: String,
        body: Codable? = nil,
        queryItems: [URLQueryItem]? = nil
    ) throws -> URLRequest {
        // Create the URL from the base endpoint and the specific path.
        guard var urlComponents = URLComponents(url: endpointURL.appending(path: path), resolvingAgainstBaseURL: true)
        else {
            throw URLError(.badURL)
        }

        var myQueryItems: [URLQueryItem] = []
        myQueryItems.append(URLQueryItem(name: "key", value: apiKey))

        // If there are query items, add them to the URL.
        if let queryItems, !queryItems.isEmpty {
            myQueryItems.append(contentsOf: queryItems)
        }

        urlComponents.queryItems = myQueryItems

        guard let url = urlComponents.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = httpMethod

        if let apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        }

        // If there is a body to encode and the HTTP method supports a body, encode it as JSON.
        if let body, ["POST", "PUT", "PATCH"].contains(httpMethod) {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }

        return request
    }

    // MARK: - Private Helpers

    /// Maps neutral `RequestedMedia` to Gemini's `responseModalities` strings,
    /// preserving order and including every requested modality. Audio is
    /// omitted — `:generateContent` doesn't support audio output.
    static func googleResponseModalities(for media: [RequestedMedia]) -> [String] {
        media.compactMap { entry in
            switch entry {
                case .text: "TEXT"
                case .image: "IMAGE"
                case .audio: nil
            }
        }
    }

    private func buildGenerateContentRequest(
        from messages: [ChatMessage],
        tools: [ToolDescription]?,
        thinkingConfig: GoogleThinkingConfig?,
        imageConfig: GoogleGenerateContentRequest.ImageConfig?,
        responseModalities: [String]? = nil,
        responseFormat: ChatCompletionRequest.ResponseFormat? = nil
    ) -> GoogleGenerateContentRequest {
        var systemParts: [GoogleGenerateContent.Part] = []
        var contents: [GoogleGenerateContent.Content] = []
        var toolNamesById: [String: String] = [:]

        for message in messages {
            switch message.role {
                case .system, .developer:
                    let parts = googleParts(from: message)
                    if !parts.isEmpty {
                        systemParts.append(contentsOf: parts)
                    }

                case .user:
                    let parts = googleParts(from: message)
                    if !parts.isEmpty {
                        contents.append(.init(role: "user", parts: parts))
                    }

                case .assistant:
                    var parts: [GoogleGenerateContent.Part] = []

                    if let toolCalls = message.toolCalls {
                        for call in toolCalls {
                            if let function = call.function {
                                toolNamesById[call.id] = function.name
                                let argsDict = (try? function.argumentsDictionary()) ?? [:]
                                let wrapped = wrapAsJSONValue(argsDict)
                                let callPart = GoogleGenerateContent.Part(
                                    text: nil,
                                    inlineData: nil,
                                    fileData: nil,
                                    functionCall: .init(name: function.name, args: wrapped),
                                    functionResponse: nil,
                                    thought: nil,
                                    thoughtSignature: nil
                                )
                                parts.append(callPart)
                            }
                        }
                    }

                    parts.append(contentsOf: googleParts(from: message))

                    if !parts.isEmpty {
                        contents.append(.init(role: "model", parts: parts))
                    }

                case .tool:
                    guard let toolCallID = message.toolCallID,
                        let functionName = toolNamesById[toolCallID] else {
                        continue
                    }

                    // The functionResponse part already carries the tool
                    // output text in `response.output`. Don't also append
                    // the raw textContent as a separate text part — Gemini
                    // sees the conversation as "tool already answered, no
                    // user query pending" and emits an empty content with
                    // STOP, breaking `candidates[0].content.parts` decode.
                    let responsePart = GoogleGenerateContent.Part(
                        text: nil,
                        inlineData: nil,
                        fileData: nil,
                        functionCall: nil,
                        functionResponse: .init(
                            name: functionName,
                            response: ["output": JSONValue(message.textContent ?? "")]
                        ),
                        thought: nil,
                        thoughtSignature: nil
                    )
                    contents.append(.init(role: "user", parts: [responsePart]))

                case .function:
                    continue
            }
        }

        let systemInstruction = systemParts.isEmpty ? nil : GoogleGenerateContent.Content(role: nil, parts: systemParts)

        let requestThinkingConfig = thinkingConfig.map { GoogleGenerateContentRequest.ThinkingConfig(from: $0) }

        // Translate the OpenAI-shaped responseFormat into Gemini's
        // `responseSchema` + `responseMimeType` pair. `.json` switches
        // to JSON mode without enforcing a schema; `.jsonSchema(format)`
        // enforces the given schema server-side. `.text` leaves both
        // nil so the model replies in plain text.
        let responseSchema: JSONValue?
        let responseMimeType: String?
        switch responseFormat {
            case .none, .some(.text):
                responseSchema = nil
                responseMimeType = nil
            case .some(.json):
                responseSchema = nil
                responseMimeType = "application/json"
            case let .some(.jsonSchema(format)):
                responseSchema = geminiCompatibleSchema(format.schema)
                responseMimeType = "application/json"
        }

        // Prefer the explicitly requested modalities; fall back to inferring
        // "IMAGE" from a present imageConfig so existing callers are unchanged.
        let effectiveModalities = responseModalities ?? (imageConfig != nil ? ["IMAGE"] : nil)
        let hasGenerationConfig = requestThinkingConfig != nil
            || imageConfig != nil
            || effectiveModalities != nil
            || responseSchema != nil
            || responseMimeType != nil
        let generationConfig = hasGenerationConfig
            ? GoogleGenerateContentRequest.GenerationConfig(
                thinkingConfig: requestThinkingConfig,
                imageConfig: imageConfig,
                responseModalities: effectiveModalities,
                temperature: 1.0,
                responseSchema: responseSchema,
                responseMimeType: responseMimeType
            )
            : nil

        return GoogleGenerateContentRequest(
            contents: contents,
            systemInstruction: systemInstruction,
            tools: makeGoogleTools(from: tools),
            generationConfig: generationConfig
        )
    }

    func makeChatCompletionResponse(model: String, data: Data, response: URLResponse) throws -> ChatCompletionResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let errorResponse = try? decoder.decode(GoogleErrorResponse.self, from: data) {
                let type = errorResponse.error.status ?? "\(errorResponse.error.code)"
                throw APIError.otherError(type, errorResponse.error.message)
            }

            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.otherError("\(httpResponse.statusCode)", message)
        }

        //		#if DEBUG
        //		if let debugString = String(data: data, encoding: .utf8) {
        //			NSLog("Google Response: %@", debugString)
        //		}
        //		#endif
        let responsePayload: GoogleGenerateContentResponse = try decoder.decode(
            GoogleGenerateContentResponse.self,
            from: data
        )

        let choices: [ChatCompletionResponse.Choice] = responsePayload.candidates.enumerated()
            .compactMap { index, candidate in
                guard let content = candidate.content else {
                    return nil
                }

                var textSegments: [String] = []
                var toolCalls: [ToolCall] = []
                var structuredParts: [ChatMessage.ContentPart] = []
                var finishReason = mapFinishReason(candidate.finishReason)
                var reasoningSegments: [String] = []

                for part in content.parts {
                    if part.thought == true {
                        if let text = part.text, !text.isEmpty {
                            reasoningSegments.append(text)
                        }
                        continue
                    }

                    if let text = part.text, !text.isEmpty {
                        textSegments.append(text)
                        structuredParts.append(ChatMessage.ContentPart(text: text))
                    } else if let inline = part.inlineData {
                        // `inline.data` is `Data`; it must be base64-encoded into
                        // the data URL. Interpolating the `Data` directly yields
                        // its description ("N bytes"), which no decoder accepts.
                        let dataURL = "data:\(inline.mimeType);base64,\(inline.data.base64EncodedString())"
                        structuredParts.append(ChatMessage.ContentPart(imageURL: dataURL))
                    } else if let file = part.fileData, let uri = file.fileUri {
                        textSegments.append("file://\(uri)")
                        structuredParts.append(ChatMessage.ContentPart(text: "file://\(uri)"))
                    } else if let functionCall = part.functionCall {
                        let argsString: String = if let args = functionCall.args,
                            let data = try? JSONEncoder().encode(args),
                                let string = String(data: data, encoding: .utf8) {
                            string
                        } else {
                            "{}"
                        }

                        let function = FunctionCall(name: functionCall.name, arguments: argsString)
                        let toolCall = ToolCall(id: UUID().uuidString, type: "function", function: function)
                        toolCalls.append(toolCall)
                        finishReason = .toolCalls
                    }
                }

                let combinedText = textSegments.joined(separator: "\n")
                let richContent: ChatMessage.Content?
                if !structuredParts.isEmpty {
                    let hasNonTextParts = structuredParts.contains { $0.type != .text }
                    if hasNonTextParts {
                        richContent = .parts(structuredParts)
                    } else if !combinedText.isEmpty {
                        richContent = .text(combinedText)
                    } else {
                        richContent = nil
                    }
                } else if !combinedText.isEmpty {
                    richContent = .text(combinedText)
                } else {
                    richContent = nil
                }
                var message = ChatMessage(role: .assistant, content: richContent)

                if !toolCalls.isEmpty {
                    message.toolCalls = toolCalls
                }

                if !reasoningSegments.isEmpty {
                    message.reasoningContent = reasoningSegments.joined(separator: "\n")
                }

                return ChatCompletionResponse.Choice(message: message, finishReason: finishReason, index: index)
            }

        return ChatCompletionResponse(
            id: UUID().uuidString,
            object: "chat.completion",
            created: Date(),
            model: model,
            usage: mapUsage(responsePayload.usageMetadata),
            choices: choices.isEmpty ? [ChatCompletionResponse.Choice(
                message: ChatMessage(role: .assistant, content: nil),
                finishReason: .stop,
                index: 0
            )] : choices
        )
    }

    /// Maps Gemini finish reasons (see
    /// https://ai.google.dev/api/rest/v1/GenerateContentResponse#FinishReason.FinishReason)
    /// to OpenAI-style finish reasons used throughout the app.
    /// The Google API may return STOP, MAX_TOKENS, SAFETY, RECITATION, OTHER, BLOCKLIST, PROHIBITED_CONTENT, SPII,
    /// MALFORMED_FUNCTION_CALL, MODEL_ARMOR, IMAGE_* variants, UNEXPECTED_TOOL_CALL, NO_IMAGE and others.
    private func mapFinishReason(_ reason: String?) -> FinishReason? {
        guard let reason = reason?.lowercased() else {
            return .stop
        }

        switch reason {
            case "stop":
                return .stop
            case "max_tokens":
                return .limit
            case "safety",
                "blocklist",
                    "prohibited_content",
                    "spii",
                    "model_armor",
                    "image_safety",
                    "image_prohibited_content":
                return .contentFilter
            case "recitation",
                "other",
                    "image_other",
                    "image_recitation",
                    "malware",
                    "unknown":
                return .stop
            case "malformed_function_call",
                "unexpected_tool_call":
                return .functionCall
            case "no_image":
                return .limit
            default:
                return .stop
        }
    }

    /// Encode a `JSONSchema` into the OpenAPI 3.0 subset Gemini's
    /// `responseSchema` accepts. Gemini rejects unknown fields outright
    /// (returns `INVALID_ARGUMENT` for `additionalProperties` /
    /// `$schema`), so we strip those — and any other JSON-Schema-only
    /// vocabulary that might creep in — recursively from every nested
    /// object before sending. Returns `nil` if the schema can't be
    /// encoded; the caller falls back to no schema in that case.
    private func geminiCompatibleSchema(_ schema: JSONSchema) -> JSONValue? {
        guard let value = try? JSONValue(encoding: schema) else { return nil }
        return stripGeminiIncompatibleKeys(value)
    }

    /// Drop keys Gemini's schema subset rejects, recursively. Documented
    /// at https://ai.google.dev/api/caching#Schema — the @Schema macro
    /// emits `additionalProperties: false` by default which is the
    /// practical concern; the rest are belt-and-braces.
    private func stripGeminiIncompatibleKeys(_ value: JSONValue) -> JSONValue {
        let disallowed: Set<String> = [
            "additionalProperties",
            "$schema",
            "definitions",
            "$defs",
            "patternProperties"
        ]
        switch value {
            case let .object(dict):
                var sanitised: [String: JSONValue] = [:]
                for (key, child) in dict where !disallowed.contains(key) {
                    sanitised[key] = stripGeminiIncompatibleKeys(child)
                }
                return .object(sanitised)
            case let .array(items):
                return .array(items.map(stripGeminiIncompatibleKeys))
            default:
                return value
        }
    }

    private func makeGoogleTools(from tools: [ToolDescription]?) -> [GoogleGenerateContentRequest.Tool]? {
        guard let tools else {
            return nil
        }

        let declarations = tools.compactMap { tool -> GoogleGenerateContentRequest.FunctionDeclaration? in
            guard let function = tool.function else {
                return nil
            }
            return GoogleGenerateContentRequest.FunctionDeclaration(
                name: function.name,
                description: function.description,
                parameters: function.parameters
            )
        }

        guard !declarations.isEmpty else {
            return nil
        }

        return [GoogleGenerateContentRequest.Tool(functionDeclarations: declarations)]
    }

    private func googleParts(from message: ChatMessage) -> [GoogleGenerateContent.Part] {
        if let parts = message.contentParts, !parts.isEmpty {
            return convertContentParts(parts)
        }
        if let text = message.textContent, !text.isEmpty {
            return [.text(text)]
        }
        return []
    }

    private func convertContentParts(_ parts: [ChatMessage.ContentPart]) -> [GoogleGenerateContent.Part] {
        var result: [GoogleGenerateContent.Part] = []
        for part in parts {
            switch part.type {
                case .text:
                    if let text = part.text {
                        result.append(.text(text))
                    }
                case .imageURL:
                    if let inline = makeInlinePart(from: part) {
                        result.append(inline)
                    } else if let url = part.imageURL?.url {
                        result.append(.file(uri: url, mimeType: part.imageURL?.mimeType))
                    }
                default:
                    continue
            }
        }
        return result
    }

    private func makeInlinePart(from part: ChatMessage.ContentPart) -> GoogleGenerateContent.Part? {
        guard let decoded = part.decodedImageData() else {
            return nil
        }
        let inline = GoogleGenerateContent.Part.InlineData(
            mimeType: decoded.mimeType,
            data: decoded.data
        )
        return GoogleGenerateContent.Part(
            text: nil,
            inlineData: inline,
            fileData: nil,
            functionCall: nil,
            functionResponse: nil,
            thought: nil,
            thoughtSignature: nil
        )
    }

    private func wrapAsJSONValue(_ dictionary: [String: Any]) -> [String: JSONValue]? {
        let wrapped = [String: JSONValue](jsonObject: dictionary)
        return wrapped.isEmpty ? nil : wrapped
    }

    private func mapUsage(_ metadata: GoogleGenerateContentResponse.UsageMetadata?) -> Usage? {
        guard let metadata else { return nil }
        let prompt = metadata.promptTokenCount ?? 0
        let completion = metadata.candidatesTokenCount ?? 0
        let total = metadata.totalTokenCount ?? (prompt + completion)
        return Usage(promptTokens: prompt, completionTokens: completion, totalTokens: total)
    }

    func googleError(from data: Data, response: URLResponse) -> Error {
        guard let httpResponse = response as? HTTPURLResponse else {
            return APIError.invalidResponse
        }
        if let errorResponse = try? decoder.decode(GoogleErrorResponse.self, from: data) {
            let type = errorResponse.error.status ?? "\(errorResponse.error.code)"
            return APIError.otherError(type, errorResponse.error.message)
        }
        let message = String(data: data, encoding: .utf8) ?? "Unknown error"
        return APIError.otherError("\(httpResponse.statusCode)", message)
    }
}
