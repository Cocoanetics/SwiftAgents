//
//  OpenAI+Runs.swift
//
//
//  Created by Oliver Drobnik on 03.05.24.
//

import Foundation

extension OpenAI {
    /**
     Creates a new run on the OpenAI platform.

     - Parameters:
     - threadId: The unique identifier of the thread to create the run in.
     - assistantId: The ID of the assistant to use to execute this run.
     - model: Optional. The ID of the Model to be used to execute this run. If provided, it will override the model associated with the assistant.
     - instructions: Optional. Overrides the instructions of the assistant. Useful for modifying the behavior on a per-run basis.
     - additionalInstructions: Optional. Appends additional instructions at the end of the instructions for the run. Useful for modifying the behavior on a per-run basis without overriding other instructions.
     - additionalMessages: Optional. Adds additional messages to the thread before creating the run.
     - role: The role of the entity that is creating the message.
     - content: The content of the message.
     - attachments: Optional. A list of files attached to the message, and the tools they should be added to.
     - tools: Optional. Override the tools the assistant can use for this run. Useful for modifying the behavior on a per-run basis.
     - temperature: Optional. The sampling temperature used for this run. Defaults to 1.
     - topP: Optional. The nucleus sampling value used for this run. Defaults to 1.
     - maxPromptTokens: Optional. The maximum number of prompt tokens that may be used over the course of the run.
     - maxCompletionTokens: Optional. The maximum number of completion tokens that may be used over the course of the run.
     - truncationStrategy: Optional. Controls for how a thread will be truncated prior to the run.
     - toolChoice: Optional. Controls which (if any) tool is called by the model.
     - responseFormat: Optional. Specifies the format that the model must output.

     - Returns: Returns the created `Run` object containing the details of the newly created run.

     - SeeAlso: [Create Run API](https://platform.openai.com/docs/api-reference/runs/createRun)
     */
    func createRun(
        threadId: String,
        assistantId: String,
        model: String? = nil,
        instructions: String? = nil,
        additionalInstructions: String? = nil,
        additionalMessages: [MessageCreation]? = nil,
        attachments _: [Attachment]? = nil,
        tools: [ToolDescription]? = nil,
        metadata: [String: String]? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxPromptTokens: Int? = nil,
        maxCompletionTokens: Int? = nil,
        truncationStrategy: TruncationStrategy? = nil,
        toolChoice: ToolChoice? = nil,
        responseFormat: ResponseFormat? = nil
    ) async throws -> Run {
        let runCreation = RunCreation(
            assistantId: assistantId,
            model: model,
            instructions: instructions,
            additionalInstructions: additionalInstructions,
            additionalMessages: additionalMessages,
            tools: tools,
            metadata: metadata,
            temperature: temperature,
            topP: topP,
            stream: false,
            maxPromptTokens: maxPromptTokens,
            maxCompletionTokens: maxCompletionTokens,
            truncationStrategy: truncationStrategy,
            toolChoice: toolChoice,
            responseFormat: responseFormat
        )

        let endpoint = "/v1/threads/\(threadId)/runs"

        let request = try createUrlRequest(httpMethod: "POST", path: endpoint, body: runCreation)

        let (data, response) = try await session.data(for: request)
        return try process(data: data, response: response)
    }

    func createRunStream(
        threadId: String,
        assistantId: String,
        model: String? = nil,
        instructions: String? = nil,
        additionalInstructions: String? = nil,
        additionalMessages: [MessageCreation]? = nil,
        attachments _: [Attachment]? = nil,
        tools: [ToolDescription]? = nil,
        metadata: [String: String]? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxPromptTokens: Int? = nil,
        maxCompletionTokens: Int? = nil,
        truncationStrategy: TruncationStrategy? = nil,
        toolChoice: ToolChoice? = nil,
        responseFormat: ResponseFormat? = nil
    ) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let runCreation = RunCreation(
            assistantId: assistantId,
            model: model,
            instructions: instructions,
            additionalInstructions: additionalInstructions,
            additionalMessages: additionalMessages,
            tools: tools,
            metadata: metadata,
            temperature: temperature,
            topP: topP,
            stream: true,
            maxPromptTokens: maxPromptTokens,
            maxCompletionTokens: maxCompletionTokens,
            truncationStrategy: truncationStrategy,
            toolChoice: toolChoice,
            responseFormat: responseFormat
        )

        let endpoint = "/v1/threads/\(threadId)/runs"

        let request = try createUrlRequest(httpMethod: "POST", path: endpoint, body: runCreation)

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        return try await processEventStream(asyncBytes: asyncBytes, response: response)
    }

    /**
     Processes an asynchronous byte stream from a URLSession and returns a `ChatCompletionResponse`.

     - Parameters:
     - asyncBytes: The asynchronous byte stream from the URLSession.
     - response: The HTTP URL response associated with the request.

     - Returns: A `ChatCompletionResponse` object parsed from the asynchronous byte stream.

     - Throws: An error if the response is invalid (non-200 status code), or if there's an issue parsing the JSON data.

     - Note: This function assumes that the API call returns a continuous stream of JSON strings, each representing a `Chunk` object. The function aggregates these `Chunk` objects into a single `ChatCompletionResponse`.

     */
    func processEventStream(
        asyncBytes: URLSession.AsyncBytes,
        response: URLResponse
    ) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        if let response = response as? HTTPURLResponse, response.statusCode != 200 {
            // read until end
            let data = try await asyncBytes.reduce(into: Data()) { partialResult, byte in
                partialResult.append(byte)
            }

            throw errorFromResponse(data: data, response: response)
        }

        return AsyncThrowingStream { continuation in
            Task {
                var currentEvent = ""

                for try await line in asyncBytes.lines {
                    print(line)

                    if let range = line.range(of: "event: ") {
                        currentEvent = String(line[range.upperBound...])
                        continue
                    }

                    guard let range = line.range(of: "data: ") else {
                        throw APIError.apiError("Didn't get data at beginning of line")
                    }

                    let jsonString = line[range.upperBound...]

                    if jsonString == "[DONE]" {
                        continuation.finish()
                        return
                    }

                    let jsonData = jsonString.data(using: .utf8)!

                    do {
                        if currentEvent.hasPrefix("thread.message.delta") {
                            let messageDelta = try self.decoder.decode(ThreadMessageDelta.self, from: jsonData)
                            let event = StreamEvent(type: currentEvent, object: .messageDelta(messageDelta))
                            continuation.yield(event)
                        } else if currentEvent.hasPrefix("thread.run.step.delta") {
                            let runStepDelta = try self.decoder.decode(RunStepDelta.self, from: jsonData)
                            let event = StreamEvent(type: currentEvent, object: .runStepDelta(runStepDelta))
                            continuation.yield(event)
                        } else if currentEvent.hasPrefix("thread.run.step") {
                            let runStep = try self.decoder.decode(RunStep.self, from: jsonData)
                            let event = StreamEvent(type: currentEvent, object: .runStep(runStep))
                            continuation.yield(event)
                        } else if currentEvent.hasPrefix("thread.run") {
                            let run = try self.decoder.decode(Run.self, from: jsonData)
                            let event = StreamEvent(type: currentEvent, object: .run(run))
                            continuation.yield(event)
                        } else if currentEvent.hasPrefix("thread.message") {
                            let message = try self.decoder.decode(Message.self, from: jsonData)
                            let event = StreamEvent(type: currentEvent, object: .message(message))
                            continuation.yield(event)
                        } else if currentEvent.hasPrefix("thread") {
                            let thread = try self.decoder.decode(Thread.self, from: jsonData)
                            let event = StreamEvent(type: currentEvent, object: .thread(thread))
                            continuation.yield(event)
                        } else if currentEvent.hasPrefix("error") {
                            let error = try self.decoder.decode(ErrorDetail.self, from: jsonData)
                            let event = StreamEvent(type: currentEvent, object: .error(error))
                            continuation.yield(event)
                        } else {
                            print("Unknown event type '\(currentEvent)'")
                        }
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    /**
     Retrieves a list of runs belonging to a specific thread on the OpenAI platform.

     - Parameters:
       - threadId: The unique identifier of the thread whose runs are to be listed.
       - limit: Optional. The maximum number of runs to return, default is 20.
       - order: Optional. The order of the runs returned
       - after: Optional. A cursor for pagination; specifies an object ID to list runs after it.
       - before: Optional. A cursor for pagination; specifies an object ID to list runs before it.

     - Returns: Returns a `ListPagedResponse<Run>` object containing the list of runs for the given thread.

     - SeeAlso: [List Runs API](https://platform.openai.com/docs/api-reference/runs/listRuns)
     */
    func listRuns(
        threadId: String,
        limit: Int = 20,
        order: SortOrder = .descending,
        after: String? = nil,
        before: String? = nil
    ) async throws -> ListPagedResponse<Run> {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "order", value: order.rawValue)
        ]

        if let after {
            queryItems.append(URLQueryItem(name: "after", value: after))
        }

        if let before {
            queryItems.append(URLQueryItem(name: "before", value: before))
        }

        let request = try createUrlRequest(path: "/v1/threads/\(threadId)/runs", queryItems: queryItems)

        let (data, response) = try await URLSession.shared.data(for: request)

        return try process(data: data, response: response)
    }

    /**
     Retrieves a single run from a specific thread on the OpenAI platform.

     - Parameters:
       - threadId: The unique identifier of the thread where the run belongs.
       - runId: The unique identifier of the run to retrieve.

     - Returns: Returns a `Run` object containing the details of the retrieved run.

     - SeeAlso: [Retrieve Run API](https://platform.openai.com/docs/api-reference/runs/getRun)
     */
    func retrieveRun(threadId: String, runId: String) async throws -> Run {
        let request = try createUrlRequest(path: "/v1/threads/\(threadId)/runs/\(runId)")

        let (data, response) = try await URLSession.shared.data(for: request)

        return try process(data: data, response: response)
    }

    /**
     Modifies a run on the OpenAI platform using the thread's unique identifier and the run's unique identifier.

     - Parameters:
     - threadId: The unique identifier of the thread that the run belongs to.
     - runId: The unique identifier of the run to modify.
     - metadata: Key-value pairs providing additional information about the run. Keys can be a maximum of 64 characters long and values can be a maximum of 512 characters long.

     - Returns: Returns the modified `Run` object containing updated details.

     - SeeAlso: [Modify Run API](https://platform.openai.com/docs/api-reference/runs/modifyRun)
     */
    func modifyRun(
        threadId: String,
        runId: String,
        metadata: [String: String]
    ) async throws -> Run {
        let body = ["metadata": metadata]
        let request = try createUrlRequest(
            httpMethod: "POST",
            path: "/v1/threads/\(threadId)/runs/\(runId)",
            body: body
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        return try process(data: data, response: response)
    }

    /**
     Cancels a run on the OpenAI platform that is in_progress.

     - Parameters:
       - threadId: The unique identifier of the thread that the run belongs to.
       - runId: The unique identifier of the run to cancel.

     - Returns: Returns the modified `Run` object matching the specified ID.

     - SeeAlso: [Cancel Run API](https://platform.openai.com/docs/api-reference/runs/cancelRun)
     */
    func cancelRun(threadId: String, runId: String) async throws -> Run {
        let endpoint = "/v1/threads/\(threadId)/runs/\(runId)/cancel"
        let request = try createUrlRequest(httpMethod: "POST", path: endpoint)

        let (data, response) = try await URLSession.shared.data(for: request)

        return try process(data: data, response: response)
    }

    /**
     Submits tool outputs to a run on the OpenAI platform.

     - Parameters:
     - threadId: The unique identifier of the thread to which the run belongs.
     - runId: The unique identifier of the run that requires the tool output submission.
     - toolOutputs: A list of tool outputs being submitted.
     - stream: Optional. If true, returns a stream of events that happen during the run as server-sent events, terminating when the run enters a terminal state with a data: [DONE] message.

     - Returns: Returns the modified `Run` object matching the specified ID.

     - SeeAlso: [Submit Tool Outputs to Run API](https://platform.openai.com/docs/api-reference/runs/submitToolOutputs)
     */
    @discardableResult
    func submitToolOutputs(toThreadId threadId: String, runId: String, toolOutputs: [ToolOutput]) async throws -> Run {
        let endpoint = "/v1/threads/\(threadId)/runs/\(runId)/submit_tool_outputs"

        struct ToolOutputsSubmission: Codable {
            let toolOutputs: [ToolOutput]
            let stream: Bool
        }

        let submission = ToolOutputsSubmission(toolOutputs: toolOutputs, stream: false)
        let request = try createUrlRequest(httpMethod: "POST", path: endpoint, body: submission)

        let (data, response) = try await URLSession.shared.data(for: request)

        return try process(data: data, response: response)
    }

    func submitToolOutputsStream(
        toThreadId threadId: String,
        runId: String,
        toolOutputs: [ToolOutput]
    ) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let endpoint = "/v1/threads/\(threadId)/runs/\(runId)/submit_tool_outputs"

        struct ToolOutputsSubmission: Codable {
            let toolOutputs: [ToolOutput]
            let stream: Bool
        }

        let submission = ToolOutputsSubmission(toolOutputs: toolOutputs, stream: true)
        let request = try createUrlRequest(httpMethod: "POST", path: endpoint, body: submission)

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        return try await processEventStream(asyncBytes: asyncBytes, response: response)
    }

    /**
     Waits until a run is finished on the OpenAI platform.

     - Parameters:
     - threadId: The unique identifier of the thread that the run belongs to.
     - runId: The unique identifier of the run to wait for.
     - interval: The interval (in seconds) between each poll to check the status of the run. Default is 5 seconds.

     - Returns: Returns the run.

     - Throws: Throws an error if there is an issue while retrieving the status of the run or if the run is cancelled, failed, or expired.

     - SeeAlso: [Retrieve Run API](https://platform.openai.com/docs/api-reference/runs/getRun)
     */
    @discardableResult
    func waitUntilRunIsFinished(threadId: String, runId: String, interval: TimeInterval = 5) async throws -> Run {
        while true {
            // Retrieve the current status of the run
            let run = try await retrieveRun(threadId: threadId, runId: runId)

            switch run.status {
                case .cancelled, .failed, .completed, .expired, .requiresAction:
                    return run
                default:
                    // The run is still in progress, continue waiting
                    break
            }

            // Sleep for a few seconds before polling again to manage API request frequency
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }
}
