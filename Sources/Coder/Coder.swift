import ArgumentParser
import Foundation
import Providers
import SwiftDotenv
import TerminalUI

/// Flushes buffered text, rendering complete markdown inline markers (**bold**, *italic*, `code`).
/// Returns the remaining buffer (text after an unmatched opening marker).
/// Check if a `*` at the given position is a bullet point (not inline italic)
private func isBullet(_ buf: String, at idx: String.Index) -> Bool {
    // * is a bullet if at start of string or preceded by a newline, and followed by whitespace
    let precededByNewline = idx == buf.startIndex ||
        buf[buf.index(before: idx)] == "\n"
    let followedBySpace = buf.index(after: idx) < buf.endIndex &&
        buf[buf.index(after: idx)].isWhitespace
    return precededByNewline && followedBySpace
}

private func flushMarkdown(_ buffer: String, terminal: TerminalHandler, inCodeBlock: inout Bool) -> String {
    var buf = buffer

    // Handle triple-backtick fences — strip them and toggle code block state
    while let range = buf.range(of: "```") {
        // Output text before the fence
        let before = String(buf[buf.startIndex ..< range.lowerBound])
        if !before.isEmpty {
            terminal.output(inCodeBlock ? before.dim : before.markdownToANSI, addLineFeed: false)
        }

        let afterFence = range.upperBound
        if !inCodeBlock {
            // Opening fence — skip language tag on same line
            if let newline = buf[afterFence...].firstIndex(where: { $0 == "\n" }) {
                buf = String(buf[buf.index(after: newline)...])
            } else {
                // Fence at end of buffer, wait for more
                return "```"
            }
        } else {
            // Closing fence — skip trailing newline if present
            if afterFence < buf.endIndex, buf[afterFence] == "\n" {
                buf = String(buf[buf.index(after: afterFence)...])
            } else {
                buf = String(buf[afterFence...])
            }
        }
        inCodeBlock.toggle()
    }

    // If inside a code block, output as dim and keep buffering
    if inCodeBlock {
        if !buf.isEmpty {
            terminal.output(buf.dim, addLineFeed: false)
        }
        return ""
    }

    let markers = ["**", "`", "*"]

    while true {
        var earliestRange: Range<String.Index>?
        var earliestMarker: String?

        for marker in markers {
            var searchStart = buf.startIndex
            while searchStart < buf.endIndex {
                guard let range = buf.range(of: marker, range: searchStart ..< buf.endIndex) else { break }
                // Skip * that is a bullet point
                if marker == "*" && !marker.hasPrefix("**") && isBullet(buf, at: range.lowerBound) {
                    searchStart = range.upperBound
                    continue
                }
                if earliestRange == nil || range.lowerBound < earliestRange!.lowerBound {
                    earliestRange = range
                    earliestMarker = marker
                }
                break
            }
        }

        guard let openRange = earliestRange, let marker = earliestMarker else {
            if !buf.isEmpty {
                terminal.output(buf, addLineFeed: false)
                buf = ""
            }
            return buf
        }

        let afterOpen = openRange.upperBound

        // Find closing marker (skip bullets for *)
        var closeRange: Range<String.Index>?
        if marker == "*" {
            var searchStart = afterOpen
            while searchStart < buf.endIndex {
                guard let range = buf.range(of: marker, range: searchStart ..< buf.endIndex) else { break }
                if isBullet(buf, at: range.lowerBound) {
                    searchStart = range.upperBound
                    continue
                }
                closeRange = range
                break
            }
        } else {
            closeRange = buf.range(of: marker, range: afterOpen ..< buf.endIndex)
        }

        if let closeRange {
            let end = closeRange.upperBound
            let chunk = String(buf[buf.startIndex ..< end])
            terminal.output(chunk.markdownToANSI, addLineFeed: false)
            buf = String(buf[end...])
        } else {
            let before = String(buf[buf.startIndex ..< openRange.lowerBound])
            if !before.isEmpty {
                terminal.output(before, addLineFeed: false)
            }
            return String(buf[openRange.lowerBound...])
        }
    }
}

@main
struct Coder: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "A bare-bones coding agent."
    )

    @Option(name: [.short, .long], help: "Working directory (default: current directory)")
    var directory: String?

    @Option(name: [.short, .long], help: "Model to use (default: gpt-5.4)")
    var model: String = "gpt-5.4"

    func run() async throws {
        let workDir = directory ?? FileManager.default.currentDirectoryPath

        // Load .env file if present (sets missing env vars)
        let envPath = (workDir as NSString).appendingPathComponent(".env")
        try? Dotenv.configure(atPath: envPath)

        // Re-initialize trace exporter now that env vars are loaded
        if let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] {
            let openAI = OpenAI(apiKey: apiKey)
            await TraceProvider.shared.setProcessors([
                BatchTraceProcessor(exporter: BackendSpanExporter(openAI: openAI))
            ])
        }

        let agent = CodingAgent(workingDirectory: workDir, config: RunConfig(model: model))
        let terminal = TerminalHandler()

        terminal.output("Coder Agent".cyan.bold)
        terminal.output("Model: \(model)  Directory: \(workDir)".dim)
        terminal.output("Type /quit to exit.\n\n".dim)

        // Register slash commands
        terminal.slashCommandHandler.register(slashCommand: "quit") { Foundation.exit(0) }
        terminal.slashCommandHandler.register(slashCommand: "bye") { Foundation.exit(0) }
        terminal.slashCommandHandler.register(slashCommand: "exit") { Foundation.exit(0) }
        terminal.slashCommandHandler.register(slashCommand: "clear") { terminal.clearScreen() }
        terminal.slashCommandHandler.register(slashCommand: "?") {
            terminal.output("Available commands:".bold)
            terminal.output("  /quit, /bye, /exit".dim + " — leave the agent")
            terminal.output("  /clear".dim + "            — clear the screen")
        }

        let sessionLogger = SessionLogger(model: model, workingDirectory: workDir)

        // Handle user input
        let model = model
        var lastResponseId: String?
        terminal.handleInput = { input in
            guard !input.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let sema = DispatchSemaphore(value: 0)

            Task {
                defer { sema.signal() }

                sessionLogger.log(.user(UserMessage(content: input)))

                let config = RunConfig(model: model, workFlowName: "Coder Turn")
                let result = Runner.runStreamed(
                    agent: agent,
                    input: input,
                    maxTurns: 50,
                    previousResponseId: lastResponseId,
                    config: config
                )

                do {
                    var hasReasoning = false
                    var hasOutput = false
                    var lastWasToolCall = false
                    var lastDelta = ""
                    var lineBuffer = ""
                    var inCodeBlock = false
                    var completedResponses = [Response]()

                    for try await event in result.events {
                        switch event {
                            case let .rawResponseEvent(e):
                                switch e.object {
                                    case let .reasoningTextDelta(info):
                                        let text = info.delta
                                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        else { break }
                                        hasReasoning = true
                                        terminal.output(text.dim, addLineFeed: false)
                                    case .reasoningTextDone:
                                        break
                                    case let .outputTextDelta(info):
                                        var delta = info.delta
                                        if !hasOutput {
                                            // Strip leading newlines from first output delta
                                            delta = String(delta.drop(while: { $0.isNewline }))
                                            if hasReasoning {
                                                terminal.output("\n\n", addLineFeed: false)
                                            }
                                            hasOutput = true
                                        } else if lastWasToolCall {
                                            // Blank line after tool call before text
                                            delta = String(delta.drop(while: { $0.isNewline }))
                                            terminal.output("", addLineFeed: true)
                                            lastWasToolCall = false
                                        }
                                        lastDelta = info.delta
                                        if !delta.isEmpty {
                                            lineBuffer += delta
                                            lineBuffer = flushMarkdown(
                                                lineBuffer,
                                                terminal: terminal,
                                                inCodeBlock: &inCodeBlock
                                            )
                                        }
                                    case let .responseCompleted(response):
                                        completedResponses.append(response)
                                    default:
                                        break
                                }
                            case let .runItemEvent(name, item):
                                if case .toolOutput = name, case let .toolOutput(callId, output) = item {
                                    sessionLogger.log(.toolResult(ToolResultEntry(callId: callId, output: output)))
                                }
                                if case .toolCalled = name, case let .toolCall(toolName, args, callId) = item {
                                    sessionLogger.log(.toolCall(ToolCallEntry(
                                        name: toolName,
                                        arguments: args,
                                        callId: callId
                                    )))
                                    // Flush any buffered text before tool call
                                    if !lineBuffer.isEmpty {
                                        lastDelta = lineBuffer
                                        terminal.output(lineBuffer.markdownToANSI, addLineFeed: false)
                                        lineBuffer = ""
                                    }
                                    if !hasOutput, hasReasoning {
                                        // End reasoning line, blank line, then tool call
                                        terminal.output("\n", addLineFeed: false)
                                    } else if hasOutput, !lastDelta.hasSuffix("\n") {
                                        // End current text line before tool call
                                        terminal.output("\n", addLineFeed: false)
                                    }
                                    hasOutput = true
                                    lastWasToolCall = true
                                    terminal.output("  ↳ \(toolName)".green.dim + " \(args)".dim)
                                    lastDelta = "\n"
                                }
                            case .agentUpdated:
                                break
                        }
                    }

                    // Flush remaining line buffer
                    if !lineBuffer.isEmpty {
                        terminal.output(lineBuffer.markdownToANSI, addLineFeed: false)
                        lineBuffer = ""
                    }

                    // Ensure blank line before next prompt
                    if lastDelta.hasSuffix("\n") {
                        print("\n")
                    } else {
                        print("\n\n")
                    }
                    lastResponseId = result.lastResponseId

                    // Log assistant messages and usage from completed responses
                    for response in completedResponses {
                        for outputItem in response.output {
                            if case let .message(msg) = outputItem {
                                let text = msg.content
                                    .compactMap { if case let .outputText(t) = $0 { t.text } else { nil } }.joined()
                                if !text.isEmpty {
                                    sessionLogger.log(.assistant(AssistantMessage(content: text)))
                                }
                            }
                        }
                        if let usage = response.usage {
                            sessionLogger.log(.usage(UsageEntry(
                                inputTokens: usage.inputTokens,
                                outputTokens: usage.outputTokens,
                                totalTokens: usage.totalTokens
                            )))
                        }
                    }
                } catch let error as RunnerError {
                    switch error {
                        case .exceededMaxTurns:
                            terminal.output("Error: Agent exceeded maximum number of turns.".red)
                    }
                    print("\n")
                } catch {
                    terminal.output("Error: \(error.localizedDescription)".red)
                    print("\n")
                }
            }

            sema.wait()
        }

        try await withTrace(name: "Coder Session") {
            await terminal.run()
        }
    }
}
