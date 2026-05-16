import Foundation
import SwiftMCP

private let agentLogsEnabled = ProcessInfo.processInfo.environment["AGENT_LOGS"] != nil

@inline(__always)
private func logAgent(_ message: @autoclosure () -> String) {
	guard agentLogsEnabled else { return }
	NSLog("%@", message())
}

// Enum to represent outcomes from the task group for guardrails
private enum GuardrailOutcome<OutputType: Sendable>: Sendable {
	case agent(AgentResult<OutputType>)
	case guardrail(name: String, result: InputGuardrailResult)
	case taskError(Error)
}

/** Main runner for executing agent workflows
 
 This struct handles the execution of agent workflows, managing the interaction
 between agents, tools, and the OpenAI API.
 */
public actor Runner {

	public static func run<A: Agent>(agent: A, input: String, maxTurns: Int = 10, config: RunConfig = RunConfig()) async throws -> RunResult<A.OutputType> {
		let decoder: JSONDecoder = .init()
		decoder.dateDecodingStrategy = config.dateDecodingStrategy

		if TraceContext.currentTrace == nil {
			// no current trace context, so we start one with default name
			return try await withTrace(name: "Agent Workflow") {
				return try await run(agent: agent, input: input, maxTurns: maxTurns, config: config)
			}
		}

		var turns = 0
		let nextInput: Response.Input = Response.Input.text(input)
		let previousResponse: Response? = nil

		var currentAgent: A = agent

		repeat {
			let model = config.model ?? currentAgent.model ?? "gpt-4.1"
			let api = try await Providers.shared.api(for: model)

			// Reset these for each agent in the workflow
			var currentNextInput = nextInput
			var currentPreviousResponse = previousResponse

			let agentResult: AgentResult<A.OutputType> = try await withSpan { agentSpan in

				var tools: [Tool] = currentAgent.createTools()

				for proxy in currentAgent.mcpServers {

					tools += try await withSpan { mcpListSpan in

						let serverName = await proxy.serverName
						let mcpTools = try await proxy.listTools()

						let myTools = mcpTools.map { mcpTool in

							let parameters: Parameters

							if case .object(let object, _) = mcpTool.inputSchema {

								parameters = Parameters(properties: object.properties)
							} else {
								parameters = .none
							}

							return Tool.function(FunctionTool(name: mcpTool.name, description: mcpTool.description, parameters: parameters, strict: true))
						}

						let names = mcpTools.map { $0.name }

						mcpListSpan.spanData = MCPListToolsSpanData(server: serverName, result: names )

						return myTools
					}
				}

				agentSpan.spanData = AgentSpanData(
					name: currentAgent.name,
					handoffs: currentAgent.handoffs.compactMap { $0.targetAgent?.name },
					tools: tools.map { $0.nameForAgentSpan },
					outputType: currentAgent.outputTypeForAgentSpan
				)

				// Check if we should run input guardrails (only for the first agent in a workflow)
				if !currentAgent.inputGuardrails.isEmpty && agentSpan.parentID == nil {
					// Execute agent with guardrails in parallel
					let result = try await executeWithInputGuardrails(
						agent: currentAgent,
						input: input,
						agentSpan: agentSpan,
						tools: tools,
						maxTurns: maxTurns,
						model: model,
						api: api,
						nextInput: currentNextInput,
						previousResponse: currentPreviousResponse,
						decoder: decoder,
						config: config
					)

					// Update the current input/response state if needed
					if case .continueWithState(let state) = result.continuation {
						currentNextInput = state.nextInput
						currentPreviousResponse = state.previousResponse
					}

					// Check output guardrails before returning the result from the agent's span
					if case .finalOutput(let output, _) = result.result {
						try await Runner.checkOutputGuardrails(currentAgent.outputGuardrails + config.outputGuardrails, output: output, agent: currentAgent)
					}
					return result.result
				} else {
					// Execute the agent directly using the turnState to track nextInput and previousResponse
					var turnState = TurnState(
						nextInput: currentNextInput,
						previousResponse: currentPreviousResponse,
						turns: turns
					)

					let result = try await executeAgentTurns(
						agent: currentAgent,
						agentSpan: agentSpan,
						tools: tools,
						maxTurns: maxTurns,
						model: model,
						api: api,
						turnState: &turnState,
						decoder: decoder
					)

					// Update outer variables with final turn state
					turns = turnState.turns

					// Check output guardrails before returning the result from the agent's span
					if case .finalOutput(let output, _) = result {
						let combinedOutputGuardrails = currentAgent.outputGuardrails + config.outputGuardrails
						try await Runner.checkOutputGuardrails(combinedOutputGuardrails, output: output, agent: currentAgent)
					}
					return result
				}
			}

			switch agentResult {
				case .finalOutput(let output, let reasoning):
					return RunResult(finalOutput: output, finalReasoning: reasoning)
				case .handOff(let nextAgent):
					if let nextAgentTyped = nextAgent as? A {
						currentAgent = nextAgentTyped
					} else {
						// This shouldn't happen - but we need to handle it to satisfy the compiler
						// The most reasonable thing to do is just terminate with an error
						throw RunnerError.exceededMaxTurns
					}
			}
		} while true
	}

    // MARK: - Helpers

	// Helper struct to track state across turns
	private struct TurnState {
		var nextInput: Response.Input
		var previousResponse: Response?
		var turns: Int
		var chatHistory: [ChatMessage] = []
	}

	// Result type for the executeWithInputGuardrails function to include continuation state
	private struct GuardrailExecutionResult<T> {
		let result: AgentResult<T>
		let continuation: ContinuationState

		enum ContinuationState {
			case completed
			case continueWithState(state: TurnState)
		}
	}

	// Helper function for executing an agent with input guardrails
	private static func executeWithInputGuardrails<A: Agent>(
		agent: A,
		input: String,
		agentSpan: TraceSpan,
		tools: [Tool],
		maxTurns: Int,
		model: String,
		api: API,
		nextInput: Response.Input,
		previousResponse: Response?,
		decoder: JSONDecoder,
		config: RunConfig
	) async throws -> GuardrailExecutionResult<A.OutputType> {
		// Initialize turn state
		var turnState = TurnState(
			nextInput: nextInput,
			previousResponse: previousResponse,
			turns: 0
		)

		// Track if the agent finished before any guardrail
		var agentFinishedFirst = false
		var guardrailResults: [(name: String, result: InputGuardrailResult)] = []
		var storedAgentResult: AgentResult<A.OutputType>?
		var firstEncounteredError: Error?

		return try await withThrowingTaskGroup(of: GuardrailOutcome<A.OutputType>.self) { group in
			// Start agent task
			group.addTask {
				do {
					let result = try await executeAgentTurns(
						agent: agent,
						agentSpan: agentSpan,
						tools: tools,
						maxTurns: maxTurns,
						model: model,
						api: api,
						turnState: &turnState,
						decoder: decoder
					)
					return .agent(result)
				} catch {
					return .taskError(error)
				}
			}

			// Start each guardrail task
			for inputGuardrail in (agent.inputGuardrails + config.inputGuardrails) {
				group.addTask {
					do {
						// Use withSpan for the guardrail evaluation
						let evaluationResult = try await withSpan { span in
							let result = try await inputGuardrail.evaluate(input)
							span.spanData = GuardrailSpanData(name: inputGuardrail.name, triggered: result.tripwireTriggered)
							return result
						}
						return .guardrail(name: inputGuardrail.name, result: evaluationResult)
					} catch {
						// If withSpan or evaluate throws, record the error and propagate
						TraceContext.currentSpan?.spanData = GuardrailSpanData(name: inputGuardrail.name, triggered: false)
						return .taskError(error)
					}
				}
			}

			var triggeredGuardrailError: Error?

			// Process results from tasks
			while let outcome = await group.nextResult() {
				switch outcome {
					case .success(let guardrailOutcome):
						switch guardrailOutcome {
							case .agent(let result):
								if triggeredGuardrailError == nil {
									storedAgentResult = result
									agentFinishedFirst = true
								}
							case .guardrail(let name, let gResult):
								guardrailResults.append((name, gResult))
								if gResult.tripwireTriggered && triggeredGuardrailError == nil {
									// First guardrail to trigger
									triggeredGuardrailError = InputGuardrailTripwireTriggered(
										guardrailName: name,
										result: gResult
									)
									group.cancelAll() // Cancel other tasks
								}
							case .taskError(let err):
								if triggeredGuardrailError == nil && firstEncounteredError == nil {
									firstEncounteredError = err
								}
						}
					case .failure(let error):
						if triggeredGuardrailError == nil && firstEncounteredError == nil {
							firstEncounteredError = error
						}
				}
			}

			// If the agent finished first, but a guardrail result triggered later, throw the guardrail error
			if agentFinishedFirst {
				if let tripped = guardrailResults.first(where: { $0.result.tripwireTriggered }) {
					throw InputGuardrailTripwireTriggered(
						guardrailName: tripped.name,
						result: tripped.result
					)
				}
			}

			// Prioritize throwing the specific guardrail tripwire error
			if let specificError = triggeredGuardrailError as? InputGuardrailTripwireTriggered {
				throw specificError
			}

			// If a guardrail didn't trigger, but an agent or guardrail task failed, throw that error
			if let errorToThrow = firstEncounteredError {
				throw errorToThrow
			}

			// If agent completed successfully and no guardrail triggered, return the stored result
			if let result = storedAgentResult {
				return GuardrailExecutionResult(
					result: result,
					continuation: .continueWithState(state: turnState)
				)
			}

			// This should not be reached if logic is sound
			throw CancellationError()
		}
	}

	// Helper function for executing agent turns
	private static func executeAgentTurns<A: Agent>(
		agent: A,
		agentSpan: TraceSpan,
		tools: [Tool],
		maxTurns: Int,
		model: String,
		api: API,
		turnState: inout TurnState,
		decoder: JSONDecoder
	) async throws -> AgentResult<A.OutputType> {
		while turnState.turns < maxTurns {

			if turnState.turns == 0 {
				// Add chat history management, used with chat completions models
		turnState.chatHistory.append(ChatMessage(role: .system, content: .text(agent.instructions)))
			}

			turnState.turns += 1

			// Improved logging: agent name, model, turn number
			logAgent("[Agent: \(agent.name)] [Model: \(model)] Starting turn \(turnState.turns)")

			var roundResult = ""
			var roundReasoning: String?

			do {
				var response: Response

				if let openAI = api as? OpenAI {
					response = try await withSpan { resultSpan in
						// set it without response up front, in case of error
						resultSpan.spanData = ResponseSpanData(input: turnState.nextInput)

						let response = try await openAI.createResponse(
							input: turnState.nextInput,
							model: model,
							instructions: agent.instructions,
							maxOutputTokens: agent.modelSettings.maxCompletionTokens,
							metadata: agent.modelSettings.metadata,
							parallelToolCalls: agent.modelSettings.parallelToolCalls,
							previousResponseId: turnState.previousResponse?.id,
							reasoning: agent.modelSettings.reasoning,
							store: agent.modelSettings.store,
							temperature: agent.modelSettings.temperature,
							textFormat: agent.outputType,
							toolChoice: agent.modelSettings.toolChoice,
							tools: tools,
							topP: agent.modelSettings.topP,
							truncation: agent.modelSettings.truncation,
						)
						resultSpan.spanData = ResponseSpanData(response: response, input: turnState.nextInput)
						return response
					}
				} else {
					// Fallback for APIs that only support chat completion style
					response = try await withSpan { resultSpan in
						let messages = turnState.nextInput.toChatMessage()
						turnState.chatHistory.append(contentsOf: messages)

						// Call chat completion on generic API
						let completion = try await api.createChatCompletion(
							model: model,
							messages: turnState.chatHistory,
							tools: tools.toolDescriptions,
							n: nil,
							stop: nil,
							store: agent.modelSettings.store,
							temperature: agent.modelSettings.temperature,
							maxCompletionTokens: agent.modelSettings.maxCompletionTokens,
							metadata: agent.modelSettings.metadata,
							presencePenalty: agent.modelSettings.presencePenalty,
							responseFormat: agent.responseFormat,
							frequencyPenalty: agent.modelSettings.frequencyPenalty,
							logitBias: nil,
							user: nil
						)

						// Convert completion to Response
						let response = completion.toResponse(
							input: turnState.nextInput,
							agent: agent,
							modelSettings: agent.modelSettings
						)

						// Build span data for generation
						let inputMessages: [[String: JSONValue]] = turnState.chatHistory.map { msg in
							var dict: [String: JSONValue] = [
								"role": JSONValue(msg.role.rawValue)
							]

						// only add content if it is not empty
						if let content = msg.content {
							switch content {
								case .text(let text):
									if !text.isEmpty {
										dict["content"] = JSONValue(text)
									}
					case .parts(let parts):
						let structured: [[String: JSONValue]] = parts.map { part in
							var entry: [String: JSONValue] = ["type": JSONValue(part.encodedType)]
										if let text = part.text {
											entry["text"] = JSONValue(text)
										}
										if let url = part.imageURL?.url {
											entry["image_url"] = JSONValue(["url": JSONValue(url)])
										}
										return entry
									}
									if !structured.isEmpty {
										dict["content"] = JSONValue(structured)
									}
							}
						}

							if let toolCalls = msg.toolCalls {
								dict["tool_calls"] = JSONValue(toolCalls.map { call -> [String: JSONValue] in
									[
										"id": JSONValue(call.id),
										"type": JSONValue("function"),
										"function": JSONValue([
											"name": JSONValue(call.function?.name ?? ""),
											"arguments": JSONValue(call.function?.arguments ?? "")
										])
									]
								})
							}
							if let toolCallID = msg.toolCallID {
								dict["tool_call_id"] = JSONValue(toolCallID)
							}
							return dict
						}

						let outputMessages: [[String: JSONValue]] = response.output.map(Self.outputItemToDict)

						let modelConfig: [String: JSONValue] = [
							"temperature": JSONValue(agent.modelSettings.temperature),
							"top_p": JSONValue(agent.modelSettings.topP),
							"frequency_penalty": JSONValue(agent.modelSettings.frequencyPenalty),
							"presence_penalty": JSONValue(agent.modelSettings.presencePenalty),
							"tool_choice": JSONValue(agent.modelSettings.toolChoice),
							"parallel_tool_calls": JSONValue(agent.modelSettings.parallelToolCalls),
							"truncation": JSONValue(agent.modelSettings.truncation),
							"max_tokens": JSONValue(agent.modelSettings.maxCompletionTokens),
							"reasoning": JSONValue(agent.modelSettings.reasoning),
							"metadata": JSONValue(agent.modelSettings.metadata),
							"store": JSONValue(agent.modelSettings.store),
							"include_usage": JSONValue(agent.modelSettings.includeUsage),
							"extra_query": JSONValue(agent.modelSettings.extraQuery),
							"extra_body": JSONValue(agent.modelSettings.extraBody),
							"extra_headers": JSONValue(agent.modelSettings.extraHeaders),
							"base_url": JSONValue(agent.modelSettings.baseURL ?? api.endpointURL.absoluteString)
						]

						let usage: [String: JSONValue] = [
							"input_tokens": JSONValue(completion.usage?.promptTokens ?? 0),
							"output_tokens": JSONValue(completion.usage?.completionTokens ?? 0)
						]

						resultSpan.spanData = GenerationSpanData(
							input: inputMessages,
							output: outputMessages,
							model: model,
							modelConfig: modelConfig,
							usage: usage
						)

						// Append assistant message to history for next rounds
						if let assistantMessage = completion.choices.first?.message {
							turnState.chatHistory.append(assistantMessage)
						}

						return response
					}
				}

				var newInputs = [Response.Input.Element]()
				var functionCalls = [OutputItem.FunctionCall]()

				for outputItem in response.output {

					switch outputItem {

						case .functionCall(let functionCall):

							if let handoff = agent.handoffs.first(where: { $0.toolName == functionCall.name }), let targetAgent = handoff.targetAgent {
								do {
									if handoff.inputType.self == Void.self {
										try await handoff.callPerform(input: ())
									} else {
										if let payload = functionCall.arguments.data(using: .utf8),
										   let codableType = handoff.inputType as? Decodable.Type {
											let typedInput = try JSONDecoder().decode(codableType, from: payload)
											try await handoff.callPerform(input: typedInput)
										}
									}
								} catch {
									let inputElement = Response.Input.Element.functionCallOutput(.init(callId: functionCall.callId, output: error.localizedDescription))
									newInputs.append(inputElement)
									continue
								}

								try await withSpan { span in
									span.spanData = HandoffSpanData(fromAgent: agent.name, toAgent: targetAgent.name)

									// respond with standard transfer message that only mentions the new agent name
									let inputElement = Response.Input.Element.functionCallOutput(.init(callId: functionCall.callId, output: handoff.getTransferMessage()))
									newInputs.append(inputElement)
								}

								// Store updates before returning
								if !newInputs.isEmpty {
									turnState.nextInput = .array(newInputs)
									turnState.previousResponse = response
								}

								// Return the handoff agent directly
								return AgentResult<A.OutputType>.handOff(targetAgent)
							} else {
								functionCalls.append(functionCall)
							}

						case .reasoning(let reasoningOutput):
							roundReasoning = reasoningOutput.summary.map { $0.text }.joined(separator: "\n\n")

						case .message(let messageOutput):
							for output in messageOutput.content {
								// get the last message text of the last output
								if case .outputText(let outputText) = output {
									roundResult = outputText.text
								}
							}

						case .mcpListTools:
							// Decide how to handle this - for now, just continue
							// This might involve logging, preparing a new input, or specific actions
							logAgent("Received mcp_list_tools output, continuing.")
							continue
						case .mcpApprovalRequest(let approvalRequest):
							logAgent("Received mcp_approval_request (id: \(approvalRequest.id)), automatically approving.")
							let approvalResponse = Response.Input.Element.mcpApprovalResponse(
								Response.Input.MCPApprovalResponseInput(
									approve: true,
									approvalRequestId: approvalRequest.id
								)
							)
							newInputs.append(approvalResponse)
							// Continue to the next iteration to process newInputs
							continue
						case .mcpCall(let mcpCall):
							logAgent("Received mcp_call output (id: \(mcpCall.id)), continuing.")
							continue
						case .applyPatchCall(let patchCall):
							let result = executeApplyPatch(patchCall, agent: agent)
							newInputs.append(.applyPatchCallOutput(result))
						default:
							continue
					}
				}

				if !functionCalls.isEmpty {
					let results = try await agent.executeToolCalls(functionCalls)
					newInputs.append(contentsOf: results)
				}

				if !newInputs.isEmpty {
					turnState.nextInput = .array(newInputs)
					turnState.previousResponse = response
				} else {
					if functionCalls.isEmpty {
						if A.OutputType.self == String.self {
							return AgentResult.finalOutput(roundResult as! A.OutputType, roundReasoning)
						} else if let data = roundResult.data(using: .utf8) {
							if let decoded = decoder.decodeWithResultsUnwrap(data, as: A.OutputType.self) {
								return AgentResult.finalOutput(decoded, roundReasoning)
							}
						}

						// invalid response, just do the same response a second time
						logAgent("Invalid response, repeating.\n\n\(roundResult)")
					}
				}

			} catch {
				throw error
			}

			try Task.checkCancellation()

			// try another round

			// wait so that the next span has a slightly later start time
			try? await Task.sleep(nanoseconds: 200_000)
		}

		throw RunnerError.exceededMaxTurns
	}

	/// Wraps `agent.applyPatch(path:diff:type:)` and constructs the result.
	static func executeApplyPatch<A: Agent>(_ call: ApplyPatchCallOutput, agent: A) -> ApplyPatchCallOutputResult {
		guard let patcher = agent as? AppliesPatches else {
			return ApplyPatchCallOutputResult(callId: call.resolvedCallId, output: "Error: Agent does not support apply_patch", status: .failed)
		}
		do {
			try patcher.applyPatch(path: call.operation.path, diff: call.operation.diff, type: call.operation.type)
			let verb = switch call.operation.type {
				case .createFile: "Created"
				case .updateFile: "Updated"
				case .deleteFile: "Deleted"
			}
			return ApplyPatchCallOutputResult(callId: call.resolvedCallId, output: "\(verb) \(call.operation.path)")
		} catch {
			return ApplyPatchCallOutputResult(callId: call.resolvedCallId, output: "Error: \(error.localizedDescription)", status: .failed)
		}
	}

	// Helper to serialize OutputItem to a dictionary for tracing
	private static func outputItemToDict(_ item: OutputItem) -> [String: JSONValue] {
		switch item {
			case .message(let message):
				let content = message.content.compactMap { c in
					if case .outputText(let t) = c { return t.text }
					return nil
				}.joined(separator: "\n")
				return [
					"type": JSONValue("message"),
					"role": JSONValue(message.role.rawValue),
					"content": JSONValue(content)
				]
			case .functionCall(let call):
				// Try to decode arguments as JSON, fallback to string
				let args: JSONValue
				if let data = call.arguments.data(using: .utf8),
				   let obj = try? JSONSerialization.jsonObject(with: data) {
					args = JSONValue(jsonObject: obj)
				} else {
					args = JSONValue(call.arguments)
				}
				return [
					"type": JSONValue("tool_call"),
					"tool_call_id": JSONValue(call.callId),
					"tool_name": JSONValue(call.name),
					"arguments": args
				]
			case .fileSearch(let file):
				return [
					"type": JSONValue("file_search"),
					"id": JSONValue(file.id),
					"queries": JSONValue(file.queries),
					"results": JSONValue(file.results ?? [])
				]
			case .webSearch(let web):
				return [
					"type": JSONValue("web_search"),
					"id": JSONValue(web.id)
				]
			case .computer(let comp):
				return [
					"type": JSONValue("computer"),
					"id": JSONValue(comp.id),
					"action": JSONValue(String(describing: comp.action))
				]
			case .reasoning(let reasoning):
				let text = reasoning.summary.map { $0.text }.joined(separator: "\n")
				return [
					"type": JSONValue("reasoning"),
					"content": JSONValue(text)
				]
			case .mcpListTools(let mcpList):
				return [
					"type": JSONValue("mcp_list_tools"),
					"id": JSONValue(mcpList.id),
					"server_label": JSONValue(mcpList.serverLabel),
					"tools": JSONValue(mcpList.tools.map { tool in
						[
							"name": JSONValue(tool.name),
							"description": JSONValue(tool.description),
							"input_schema": JSONValue(tool.inputSchema),
							"annotations": JSONValue(tool.annotations)
						]
					})
				]
			case .mcpApprovalRequest(let approval):
				return [
					"type": JSONValue("mcp_approval_request"),
					"id": JSONValue(approval.id),
					"name": JSONValue(approval.name),
					"server_label": JSONValue(approval.serverLabel),
					"arguments": JSONValue(approval.arguments)
				]
			case .mcpCall(let mcpCall):
				return [
					"type": JSONValue("mcp_call"),
					"id": JSONValue(mcpCall.id),
					"approval_request_id": JSONValue(mcpCall.approvalRequestId),
					"arguments": JSONValue(mcpCall.arguments),
					"error": JSONValue(mcpCall.error),
					"name": JSONValue(mcpCall.name),
					"output": JSONValue(mcpCall.output),
					"server_label": JSONValue(mcpCall.serverLabel)
				]
			case .applyPatchCall(let patchCall):
				return [
					"type": JSONValue("apply_patch_call"),
					"id": JSONValue(patchCall.id),
					"operation_type": JSONValue(patchCall.operation.type.rawValue),
					"path": JSONValue(patchCall.operation.path)
				]
		}
	}

	private static func checkOutputGuardrails<A: Agent>(_ guardrails: [any OutputGuardrail], output: A.OutputType, agent: A) async throws {
		if guardrails.isEmpty { return }

		try await withThrowingTaskGroup(of: OutputGuardrailResult?.self) { group in
			for guardrail in guardrails {
				group.addTask {
					try await withSpan { span in
						let result = try await guardrail.evaluate(output, agent: agent)

						let outputResult = OutputGuardrailResult(
							guardrail: guardrail,
							agentOutput: (output as? any Encodable).map(JSONValue.init) ?? .string(String(describing: output)),
							agent: agent,
							output: result
						)
						span.spanData = GuardrailSpanData(
							name: guardrail.name,
							triggered: result.tripwireTriggered
						)
						return outputResult
					}
				}
			}
			// As soon as one returns tripwireTriggered, cancel all and throw
			while let result = try await group.next() {
				if let r = result, r.output.tripwireTriggered {
					group.cancelAll()
					throw OutputGuardrailTripwireTriggered(
						guardrailName: r.guardrail.name,
						result: r.output
					)
				}
			}
		}
	}
}
