//
//  OpenAI+Responses.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 24.04.25.
//
//  SeeAlso: [List Responses API](https://platform.openai.com/docs/api-reference/responses/list)

import Foundation

public extension OpenAI {
    // MARK: - Creating Responses

    /**
     Creates a response from the OpenAI API with the specified parameters.

     - Parameters:
     - input: Required. Text, image, or file inputs to the model.
     - model: Required. Model ID used to generate the response.
     - contextManagement: Optional. Context management entries such as compaction thresholds.
     - include: Optional. Additional output data to include.
     - instructions: Optional. System message to insert as first item in context.
     - maxOutputTokens: Optional. Upper bound for number of tokens to generate.
     - metadata: Optional. Key-value pairs for additional information.
     - parallelToolCalls: Optional. Whether to allow parallel tool calls.
     - previousResponseId: Optional. ID of previous response for conversation state.
     - reasoning: Optional. Configuration for reasoning models.
     - serviceTier: Optional. Latency tier for processing.
     - store: Optional. Whether to store the response.
     - stream: Optional. Whether to stream the response.
     - temperature: Optional. Sampling temperature.
     - text: Optional. Text response configuration.
     - toolChoice: Optional. Tool selection configuration.
     - tools: Optional. Available tools for the model. Supports function, file_search, web_search, computer, and mcp (remote MCP tool server) tool types.
     - topP: Optional. Nucleus sampling probability.
     - truncation: Optional. Truncation strategy.
     - user: Optional. End-user identifier.
     - background: Optional. Whether to run the response in background mode (asynchronous execution)

     - Returns: Returns a `Response` object containing the model's response.

     - SeeAlso: [Create Response API](https://platform.openai.com/docs/api-reference/responses/create)
     */
    func createResponse(
        input: Response.Input,
        model: String,
        contextManagement: [Response.ContextManagement]? = nil,
        conversation: String? = nil,
        include: [Include]? = nil,
        instructions: String? = nil,
        maxOutputTokens: Int? = nil,
        maxToolCalls: Int? = nil,
        metadata: [String: String]? = nil,
        parallelToolCalls: Bool? = nil,
        previousResponseId: String? = nil,
        prompt: Response.Prompt? = nil,
        promptCacheKey: String? = nil,
        promptCacheRetention: Response.PromptCacheRetention? = nil,
        reasoning: Reasoning? = nil,
        safetyIdentifier: String? = nil,
        serviceTier: ServiceTier? = nil,
        store: Bool? = nil,
        stream: Bool? = nil,
        temperature: Double? = nil,
        textFormat: TextFormat? = nil,
        toolChoice: ToolChoice? = nil,
        tools: [Tool]? = nil,
        topP: Double? = nil,
        truncation: Response.TruncationStrategy? = nil,
        user: String? = nil,
        background: Bool? = nil
    ) async throws -> Response {
        let text: TextConfiguration? = if let textFormat {
            TextConfiguration(format: textFormat)
        } else {
            // defaults to format: text
            nil
        }

        let details = ResponseOptionals(
            input: input,
            model: model,
            contextManagement: contextManagement,
            conversation: conversation,
            include: include,
            instructions: instructions,
            maxOutputTokens: maxOutputTokens,
            maxToolCalls: maxToolCalls,
            metadata: metadata,
            parallelToolCalls: parallelToolCalls,
            previousResponseId: previousResponseId,
            prompt: prompt,
            promptCacheKey: promptCacheKey,
            promptCacheRetention: promptCacheRetention,
            reasoning: reasoning,
            safetyIdentifier: safetyIdentifier,
            serviceTier: serviceTier,
            store: store,
            stream: stream,
            temperature: temperature,
            text: text,
            toolChoice: toolChoice,
            tools: tools,
            topP: topP,
            truncation: truncation,
            user: user,
            background: background
        )

        let request = try createUrlRequest(httpMethod: "POST", path: "/v1/responses", body: details)

        //		let string = String(data: request.httpBody!, encoding: .utf8)!
        //		print("Request body: \(string)")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 300

        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(for: request)

        return try process(data: data, response: response)
    }

    /**
     Creates a streaming response from the OpenAI API with the specified parameters.

     - Parameters:
     - input: Required. Text, image, or file inputs to the model.
     - model: Required. Model ID used to generate the response.
     - contextManagement: Optional. Context management entries such as compaction thresholds.
     - include: Optional. Additional output data to include.
     - instructions: Optional. System message to insert as first item in context.
     - maxOutputTokens: Optional. Upper bound for number of tokens to generate.
     - metadata: Optional. Key-value pairs for additional information.
     - parallelToolCalls: Optional. Whether to allow parallel tool calls.
     - previousResponseId: Optional. ID of previous response for conversation state.
     - reasoning: Optional. Configuration for reasoning models.
     - serviceTier: Optional. Latency tier for processing.
     - store: Optional. Whether to store the response.
     - temperature: Optional. Sampling temperature.
     - text: Optional. Text response configuration.
     - toolChoice: Optional. Tool selection configuration.
     - tools: Optional. Available tools for the model.
     - topP: Optional. Nucleus sampling probability.
     - truncation: Optional. Truncation strategy.
     - user: Optional. End-user identifier.
     - background: Optional. Whether to run the response in background mode (asynchronous execution)

     - Returns: Returns an AsyncThrowingStream of ResponseStreamEvent objects containing the model's response.

     - SeeAlso: [Create Response API](https://platform.openai.com/docs/api-reference/responses/create)
     */
    func createResponseStream(
        input: Response.Input,
        model: String,
        contextManagement: [Response.ContextManagement]? = nil,
        conversation: String? = nil,
        include: [Include]? = nil,
        instructions: String? = nil,
        maxOutputTokens: Int? = nil,
        maxToolCalls: Int? = nil,
        metadata: [String: String]? = nil,
        parallelToolCalls: Bool? = nil,
        previousResponseId: String? = nil,
        prompt: Response.Prompt? = nil,
        promptCacheKey: String? = nil,
        promptCacheRetention: Response.PromptCacheRetention? = nil,
        reasoning: Reasoning? = nil,
        safetyIdentifier: String? = nil,
        serviceTier: ServiceTier? = nil,
        store: Bool? = nil,
        temperature: Double? = nil,
        text: TextConfiguration? = nil,
        toolChoice: ToolChoice? = nil,
        tools: [Tool]? = nil,
        topP: Double? = nil,
        truncation: Response.TruncationStrategy? = nil,
        user: String? = nil,
        background: Bool? = nil
    ) async throws -> AsyncThrowingStream<ResponsesStreamEvent, Error> {
        let details = ResponseOptionals(
            input: input,
            model: model,
            contextManagement: contextManagement,
            conversation: conversation,
            include: include,
            instructions: instructions,
            maxOutputTokens: maxOutputTokens,
            maxToolCalls: maxToolCalls,
            metadata: metadata,
            parallelToolCalls: parallelToolCalls,
            previousResponseId: previousResponseId,
            prompt: prompt,
            promptCacheKey: promptCacheKey,
            promptCacheRetention: promptCacheRetention,
            reasoning: reasoning,
            safetyIdentifier: safetyIdentifier,
            serviceTier: serviceTier,
            store: store,
            stream: true,
            temperature: temperature,
            text: text,
            toolChoice: toolChoice,
            tools: tools,
            topP: topP,
            truncation: truncation,
            user: user,
            background: background
        )

        let request = try createUrlRequest(httpMethod: "POST", path: "/v1/responses", body: details)

        if ProcessInfo.processInfo.environment["DEBUG_REQUESTS"] != nil {
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            NSLog("[DEBUG] Request body:\n%@", body)
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 600
        let streamSession = URLSession(configuration: config)

        let (asyncBytes, response) = try await streamSession.bytes(for: request)
        return try await processResponseEventStream(asyncBytes: asyncBytes, response: response)
    }

    // MARK: - Managing Responses

    /**
     Retrieves a model response with the given ID.

     - Parameters:
     - id: Required. The ID of the response to retrieve.
     - include: Optional. Additional fields to include in the response. See the include parameter for Response creation above for more information.

     - Returns: The Response object matching the specified ID.

     - SeeAlso: [Get Response API](https://platform.openai.com/docs/api-reference/responses/get)
     */
    func getResponse(id: String, include: [Include]? = nil) async throws -> Response {
        var queryItems: [URLQueryItem] = []

        if let include, !include.isEmpty {
            queryItems.append(URLQueryItem(name: "include", value: include.map(\.rawValue).joined(separator: ",")))
        }

        let request = try createUrlRequest(path: "/v1/responses/\(id)", queryItems: queryItems)

        let (data, response) = try await URLSession.shared.data(for: request)

        return try process(data: data, response: response)
    }

    /**
     Deletes a model response with the given ID.

     - Parameters:
     - id: Required. The ID of the response to delete.

     - Returns: A boolean indicating whether the deletion was successful.

     - SeeAlso: [Delete Response API](https://platform.openai.com/docs/api-reference/responses/delete)
     */
    @discardableResult
    func deleteResponse(id: String) async throws -> Bool {
        let request = try createUrlRequest(httpMethod: "DELETE", path: "/v1/responses/\(id)")

        let (data, response) = try await URLSession.shared.data(for: request)

        let deletionStatus: DeletionStatus = try process(data: data, response: response)

        return deletionStatus.deleted
    }

    /**
     Lists input items for a given response.

     - Parameters:
     - responseId: Required. The ID of the response to retrieve input items for.
     - after: Optional. An item ID to list items after, used in pagination.
     - before: Optional. An item ID to list items before, used in pagination.
     - include: Optional. Additional fields to include in the response.
     - limit: Optional. A limit on the number of objects to be returned. Defaults to 20.
     - order: Optional. The order to return the input items in. Default is "asc".

     - Returns: A list of input item objects.

     - SeeAlso: [List Input Items API](https://platform.openai.com/docs/api-reference/responses/input-items)
     */
    func listInputItems(
        responseId: String,
        after: String? = nil,
        before: String? = nil,
        include: [Include]? = nil,
        limit: Int? = nil,
        order: SortOrder? = nil
    ) async throws -> ResponseInputList {
        var queryItems: [URLQueryItem] = []

        if let after {
            queryItems.append(URLQueryItem(name: "after", value: after))
        }

        if let before {
            queryItems.append(URLQueryItem(name: "before", value: before))
        }

        if let include, !include.isEmpty {
            for option in include {
                queryItems.append(URLQueryItem(name: "include[]", value: option.rawValue))
            }
        }

        if let limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }

        if let order {
            queryItems.append(URLQueryItem(name: "order", value: order.rawValue))
        }

        let request = try createUrlRequest(path: "/v1/responses/\(responseId)/input_items", queryItems: queryItems)

        let (data, response) = try await URLSession.shared.data(for: request)

        return try process(data: data, response: response)
    }

    // MARK: - Helpers

    /**
     Processes an asynchronous byte stream from a URLSession and returns a stream of ResponsesStreamEvent.

     - Parameters:
     - asyncBytes: The asynchronous byte stream from the URLSession.
     - response: The HTTP URL response associated with the request.

     - Returns: An AsyncThrowingStream of ResponsesStreamEvent objects.

     - Throws: An error if the response is invalid (non-200 status code), or if there's an issue parsing the JSON data.
     */
    internal func processResponseEventStream(
        asyncBytes: URLSession.AsyncBytes,
        response: URLResponse
    ) async throws -> AsyncThrowingStream<ResponsesStreamEvent, Error> {
        if let response = response as? HTTPURLResponse, response.statusCode != 200 {
            // read until end
            let data = try await asyncBytes.reduce(into: Data()) { partialResult, byte in
                partialResult.append(byte)
            }

            if ProcessInfo.processInfo.environment["DEBUG_RESPONSES"] != nil {
                let debugLine = "HTTP \(response.statusCode)\n\(String(data: data, encoding: .utf8) ?? "<binary>")\n\n"
                let debugPath = "/tmp/agentcorp_responses.log"
                try? debugLine.write(toFile: debugPath, atomically: false, encoding: .utf8)
                NSLog("[DEBUG] Response error: HTTP %d — see %@", response.statusCode, debugPath)
            }

            throw errorFromResponse(data: data, response: response)
        }

        return AsyncThrowingStream { continuation in
            Task {
                var currentEvent = ""

                for try await line in asyncBytes.lines {
                    if let range = line.range(of: "event: ") {
                        currentEvent = String(line[range.upperBound...])
                        continue
                    }

                    guard let range = line.range(of: "data: ") else {
                        // Skip blank lines and other non-data lines (SSE separators)
                        continue
                    }

                    let jsonString = line[range.upperBound...]

                    if jsonString == "[DONE]" {
                        continuation.finish()
                        return
                    }

                    let jsonData = jsonString.data(using: .utf8)!

                    do {
                        // Dump raw SSE JSON to file if DEBUG_RESPONSES is set
                        if ProcessInfo.processInfo.environment["DEBUG_RESPONSES"] != nil {
                            let debugLine = "event: \(currentEvent)\ndata: \(jsonString)\n\n"
                            let debugPath = "/tmp/agentcorp_responses.log"
                            if let handle = FileHandle(forWritingAtPath: debugPath) {
                                handle.seekToEndOfFile()
                                handle.write(debugLine.data(using: .utf8)!)
                                handle.closeFile()
                            } else {
                                try? debugLine.write(toFile: debugPath, atomically: false, encoding: .utf8)
                            }
                        }

                        switch currentEvent {
                            case "response.created":
                                let wrapper = try self.decoder.decode(ResponseWrapper.self, from: jsonData)
                                let event = ResponsesStreamEvent(
                                    type: currentEvent,
                                    object: .responseCreated(wrapper.response)
                                )
                                continuation.yield(event)
                            case "response.in_progress":
                                let wrapper = try self.decoder.decode(ResponseWrapper.self, from: jsonData)
                                let event = ResponsesStreamEvent(
                                    type: currentEvent,
                                    object: .responseInProgress(wrapper.response)
                                )
                                continuation.yield(event)
                            case "response.completed":
                                let wrapper = try self.decoder.decode(ResponseWrapper.self, from: jsonData)
                                let event = ResponsesStreamEvent(
                                    type: currentEvent,
                                    object: .responseCompleted(wrapper.response)
                                )
                                continuation.yield(event)
                            case "response.failed":
                                let wrapper = try self.decoder.decode(ResponseWrapper.self, from: jsonData)
                                let event = ResponsesStreamEvent(
                                    type: currentEvent,
                                    object: .responseFailed(wrapper.response)
                                )
                                continuation.yield(event)
                            case "response.incomplete":
                                let wrapper = try self.decoder.decode(ResponseWrapper.self, from: jsonData)
                                let event = ResponsesStreamEvent(
                                    type: currentEvent,
                                    object: .responseIncomplete(wrapper.response)
                                )
                                continuation.yield(event)
                            case "response.output_item.added":
                                let info = try self.decoder.decode(
                                    ResponsesStreamEvent.OutputItemInfo.self,
                                    from: jsonData
                                )
                                let event = ResponsesStreamEvent(type: currentEvent, object: .outputItemAdded(info))
                                continuation.yield(event)
                            case "response.output_item.done":
                                let info = try self.decoder.decode(
                                    ResponsesStreamEvent.OutputItemInfo.self,
                                    from: jsonData
                                )
                                let event = ResponsesStreamEvent(type: currentEvent, object: .outputItemDone(info))
                                continuation.yield(event)
                            case "response.content_part.added":
                                let info = try self.decoder.decode(
                                    ResponsesStreamEvent.ContentPartInfo.self,
                                    from: jsonData
                                )
                                let event = ResponsesStreamEvent(type: currentEvent, object: .contentPartAdded(info))
                                continuation.yield(event)
                            case "response.content_part.done":
                                let info = try self.decoder.decode(
                                    ResponsesStreamEvent.ContentPartInfo.self,
                                    from: jsonData
                                )
                                let event = ResponsesStreamEvent(type: currentEvent, object: .contentPartDone(info))
                                continuation.yield(event)
                            case "response.output_text.delta":
                                let info = try self.decoder.decode(
                                    ResponsesStreamEvent.OutputTextDeltaInfo.self,
                                    from: jsonData
                                )
                                let event = ResponsesStreamEvent(type: currentEvent, object: .outputTextDelta(info))
                                continuation.yield(event)
                            case "response.output_text.annotation.added":
                                let info = try self.decoder.decode(
                                    ResponsesStreamEvent.OutputTextAnnotationInfo.self,
                                    from: jsonData
                                )
                                let event = ResponsesStreamEvent(
                                    type: currentEvent,
                                    object: .outputTextAnnotationAdded(info)
                                )
                                continuation.yield(event)
                            case "response.output_text.done":
                                let info = try self.decoder.decode(
                                    ResponsesStreamEvent.OutputTextDoneInfo.self,
                                    from: jsonData
                                )
                                let event = ResponsesStreamEvent(type: currentEvent, object: .outputTextDone(info))
                                continuation.yield(event)
                            case "response.refusal.delta":
                                let info = try self.decoder.decode(
                                    ResponsesStreamEvent.RefusalDeltaInfo.self,
                                    from: jsonData
                                )
                                let event = ResponsesStreamEvent(type: currentEvent, object: .refusalDelta(info))
                                continuation.yield(event)
                            case "response.refusal.done":
                                let info = try self.decoder.decode(
                                    ResponsesStreamEvent.RefusalDoneInfo.self,
                                    from: jsonData
                                )
                                let event = ResponsesStreamEvent(type: currentEvent, object: .refusalDone(info))
                                continuation.yield(event)
                            case "response.function_call_arguments.delta":
                                let info = try self.decoder.decode(
                                    ResponsesStreamEvent.FunctionCallArgumentsDeltaInfo.self,
                                    from: jsonData
                                )
                                let event = ResponsesStreamEvent(
                                    type: currentEvent,
                                    object: .functionCallArgumentsDelta(info)
                                )
                                continuation.yield(event)
                            case "response.function_call_arguments.done":
                                let info = try self.decoder.decode(
                                    ResponsesStreamEvent.FunctionCallArgumentsDoneInfo.self,
                                    from: jsonData
                                )
                                let event = ResponsesStreamEvent(
                                    type: currentEvent,
                                    object: .functionCallArgumentsDone(info)
                                )
                                continuation.yield(event)
                            case "response.file_search_call.in_progress":
                                let info = try self.decoder.decode(
                                    ResponsesStreamEvent.FileSearchCallInfo.self,
                                    from: jsonData
                                )
                                let event = ResponsesStreamEvent(
                                    type: currentEvent,
                                    object: .fileSearchCallInProgress(info)
                                )
                                continuation.yield(event)
                            case "response.file_search_call.searching":
                                let info = try self.decoder.decode(
                                    ResponsesStreamEvent.FileSearchCallInfo.self,
                                    from: jsonData
                                )
                                let event = ResponsesStreamEvent(
                                    type: currentEvent,
                                    object: .fileSearchCallSearching(info)
                                )
                                continuation.yield(event)
                            case "response.file_search_call.completed":
                                let info = try self.decoder.decode(
                                    ResponsesStreamEvent.FileSearchCallInfo.self,
                                    from: jsonData
                                )
                                let event = ResponsesStreamEvent(
                                    type: currentEvent,
                                    object: .fileSearchCallCompleted(info)
                                )
                                continuation.yield(event)
                            case "response.web_search_call.in_progress":
                                let info = try self.decoder.decode(
                                    ResponsesStreamEvent.WebSearchCallInfo.self,
                                    from: jsonData
                                )
                                let event = ResponsesStreamEvent(
                                    type: currentEvent,
                                    object: .webSearchCallInProgress(info)
                                )
                                continuation.yield(event)
                            case "response.web_search_call.searching":
                                let info = try self.decoder.decode(
                                    ResponsesStreamEvent.WebSearchCallInfo.self,
                                    from: jsonData
                                )
                                let event = ResponsesStreamEvent(
                                    type: currentEvent,
                                    object: .webSearchCallSearching(info)
                                )
                                continuation.yield(event)
                            case "response.web_search_call.completed":
                                let info = try self.decoder.decode(
                                    ResponsesStreamEvent.WebSearchCallInfo.self,
                                    from: jsonData
                                )
                                let event = ResponsesStreamEvent(
                                    type: currentEvent,
                                    object: .webSearchCallCompleted(info)
                                )
                                continuation.yield(event)
                            case "response.reasoning_summary_part.added":
                                let info = try self.decoder.decode(
                                    ResponsesStreamEvent.ReasoningSummaryPartInfo.self,
                                    from: jsonData
                                )
                                let event = ResponsesStreamEvent(
                                    type: currentEvent,
                                    object: .reasoningSummaryPartAdded(info)
                                )
                                continuation.yield(event)
                            case "response.reasoning_summary_part.done":
                                let info = try self.decoder.decode(
                                    ResponsesStreamEvent.ReasoningSummaryPartInfo.self,
                                    from: jsonData
                                )
                                let event = ResponsesStreamEvent(
                                    type: currentEvent,
                                    object: .reasoningSummaryPartDone(info)
                                )
                                continuation.yield(event)
                            case "response.reasoning_summary.text":
                                let info = try self.decoder.decode(
                                    ResponsesStreamEvent.ReasoningSummaryInfo.self,
                                    from: jsonData
                                )
                                let event = ResponsesStreamEvent(
                                    type: currentEvent,
                                    object: .reasoningSummaryText(info)
                                )
                                continuation.yield(event)
                            case "error":
                                // Try bare ErrorDetail first (OpenAI), then wrapped ErrorResponse (LM Studio)
                                let errorDetail: ErrorDetail
                                if let bare = try? self.decoder.decode(ErrorDetail.self, from: jsonData) {
                                    errorDetail = bare
                                } else {
                                    let wrapped = try self.decoder.decode(ErrorResponse.self, from: jsonData)
                                    errorDetail = wrapped.error
                                }
                                let event = ResponsesStreamEvent(type: currentEvent, object: .error(errorDetail))
                                continuation.yield(event)
                            case "response.reasoning_text.delta":
                                let info = try self.decoder.decode(
                                    ResponsesStreamEvent.ReasoningTextDeltaInfo.self,
                                    from: jsonData
                                )
                                let event = ResponsesStreamEvent(type: currentEvent, object: .reasoningTextDelta(info))
                                continuation.yield(event)
                            case "response.reasoning_text.done":
                                let info = try self.decoder.decode(
                                    ResponsesStreamEvent.ReasoningTextDoneInfo.self,
                                    from: jsonData
                                )
                                let event = ResponsesStreamEvent(type: currentEvent, object: .reasoningTextDone(info))
                                continuation.yield(event)
                            default:
                                // Silently ignore apply_patch streaming deltas
                                if !currentEvent.hasPrefix("response.apply_patch_call") {
                                    print("Unknown event type '\(currentEvent)'")
                                }
                        }
                    } catch {
                        if ProcessInfo.processInfo.environment["DEBUG_RESPONSES"] != nil {
                            NSLog(
                                "[DEBUG] Decoding error for event '%@': %@\nJSON: %@",
                                currentEvent,
                                String(describing: error),
                                String(jsonString)
                            )
                        }
                        continuation.finish(throwing: error)
                    }
                }

                // Stream ended naturally
                continuation.finish()
            }
        }
    }
}

/// Represents optional parameters for creating a response
struct ResponseOptionals: Codable {
    /// Text, image, or file inputs to the model
    let input: Response.Input

    /// Model ID used to generate the response
    let model: String

    /// Context management configuration for this request.
    let contextManagement: [Response.ContextManagement]?

    /// Conversation ID to attach this response to
    let conversation: String?

    /// Specify additional output data to include
    let include: [Include]?

    /// System message to insert as first item in context
    let instructions: String?

    /// Upper bound for number of tokens to generate
    let maxOutputTokens: Int?

    /// Maximum number of built-in tool calls the model may make.
    let maxToolCalls: Int?

    /// Key-value pairs for additional information
    let metadata: [String: String]?

    /// Whether to allow parallel tool calls
    let parallelToolCalls: Bool?

    /// ID of previous response for conversation state
    let previousResponseId: String?

    /// Reference to a prompt template and its variables.
    let prompt: Response.Prompt?

    /// Used to improve prompt cache hit rates.
    let promptCacheKey: String?

    /// Prompt cache retention policy.
    let promptCacheRetention: Response.PromptCacheRetention?

    /// Configuration for reasoning models
    let reasoning: Reasoning?

    /// Stable identifier for OpenAI safety systems.
    let safetyIdentifier: String?

    /// Latency tier for processing
    let serviceTier: ServiceTier?

    /// Whether to store the response
    let store: Bool?

    /// Whether to stream the response
    let stream: Bool?

    /// Sampling temperature
    let temperature: Double?

    /// Text response configuration
    let text: TextConfiguration?

    /// Tool selection configuration
    let toolChoice: ToolChoice?

    /// Available tools for the model
    let tools: [Tool]?

    /// Nucleus sampling probability
    let topP: Double?

    /// Truncation strategy
    let truncation: Response.TruncationStrategy?

    /// End-user identifier
    let user: String?

    /// Whether to run the response in background mode (asynchronous execution)
    let background: Bool?
}

/// Wrapper type for decoding response events that contain a nested response object
private struct ResponseWrapper: Decodable {
    let type: String
    let response: Response
}
