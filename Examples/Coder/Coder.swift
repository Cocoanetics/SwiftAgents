import ACPServer
import ArgumentParser
import Foundation
import SwiftAgents
import TerminalUI

// swift-dotenv 2.1.0 builds on Apple platforms and Linux but not
// Windows or Android. On platforms where it's not linked the CLI
// reads vars from `ProcessInfo.processInfo.environment` directly.
#if canImport(SwiftDotenv)
    import SwiftDotenv
#endif

/// Reference box holding the rolling response id across REPL turns.
/// `@unchecked Sendable`: the input handler runs each turn's `Task` to
/// completion (via the semaphore) before returning, so accesses to `value`
/// never overlap.
private final class ResponseIdBox: @unchecked Sendable {
    var value: String?
}

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

    // Hold back trailing 1-2 backticks (partial fence). Stream tokens
    // routinely split a `` ``` `` fence between two chunks (`` `` `` in
    // one delta, `` ` `` in the next). Without this guard the partial
    // ticks get processed by the loops below and leak into the visible
    // output — outside a code block they're consumed as an empty
    // inline-code marker and the next chunk's `\n<lang>` lands as
    // plain text; inside a code block they're dim-printed verbatim
    // and the closing fence ends up visible. We hold them back so
    // they recombine into a real `` ``` `` on the next call.
    //
    // Only 1 or 2 trailing ticks are partial — 3+ form a real fence
    // and belong to the fence loop below; 0 means no work to do.
    var heldBack = ""
    let trailingTicks = buf.reversed().prefix(while: { $0 == "`" }).count
    if (1 ... 2).contains(trailingTicks) {
        heldBack = String(buf.suffix(trailingTicks))
        buf.removeLast(trailingTicks)
    }

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
                return "```" + heldBack
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
        return heldBack
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
            return buf + heldBack
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
            return String(buf[openRange.lowerBound...]) + heldBack
        }
    }
}

/// Builds the file URL for this session's JSONL transcript:
/// `~/.coder/sessions/YYYY/MM/DD/session-{timestamp}-{uuid}.jsonl`.
private func makeSessionFileURL() -> URL {
    let now = Date()
    let cal = Calendar.current
    let year = String(cal.component(.year, from: now))
    let month = String(format: "%02d", cal.component(.month, from: now))
    let day = String(format: "%02d", cal.component(.day, from: now))

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
    let timestamp = formatter.string(from: now)
    let uuid = UUID().uuidString.lowercased()

    let home = FileManager.default.homeDirectoryForCurrentUser
    return home
        .appendingPathComponent(".coder/sessions/\(year)/\(month)/\(day)", isDirectory: true)
        .appendingPathComponent("session-\(timestamp)-\(uuid).jsonl")
}

/// `coder acp` — serve over the Agent Client Protocol on stdio, for ACP clients
/// (Zed, acpx, …). The handshake succeeds without a key; a missing
/// `OPENAI_API_KEY` then surfaces as a normal turn error to the client.
struct Acp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "acp",
        abstract: "Serve over the Agent Client Protocol on stdio."
    )

    @Option(name: [.short, .long], help: "Working directory (default: current directory)")
    var directory: String?

    @Option(name: [.short, .long], help: "Model to use (default: gpt-5.4)")
    var model: String = "gpt-5.4"

    func run() async throws {
        let workDir = directory ?? FileManager.default.currentDirectoryPath

        // Load .env so the key is available for prompts; no fail-fast guard here —
        // the ACP handshake must succeed without a key. stdout carries JSON-RPC
        // only (Coder's diagnostics already go to stderr).
        #if canImport(SwiftDotenv)
            try? Dotenv.configure(atPath: (workDir as NSString).appendingPathComponent(".env"))
        #endif

        try await ACPAgentServer.serveStdio(
            handler: CoderACPHandler(workingDirectory: workDir, model: model)
        )
    }
}

@main
struct Coder: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "A bare-bones coding agent.",
        subcommands: [Acp.self]
    )

    @Option(name: [.short, .long], help: "Working directory (default: current directory)")
    var directory: String?

    @Option(name: [.short, .long], help: "Model to use (default: gpt-5.4)")
    var model: String = "gpt-5.4"

    func run() async throws {
        let workDir = directory ?? FileManager.default.currentDirectoryPath

        // Load .env file if present (sets missing env vars). Apple-only
        // — see the conditional `import SwiftDotenv` at the top of file.
        #if canImport(SwiftDotenv)
            let envPath = (workDir as NSString).appendingPathComponent(".env")
            try? Dotenv.configure(atPath: envPath)
        #endif

        // Fail fast when no OpenAI key is available — otherwise the
        // REPL prints its banner, accepts a prompt, then dies on the
        // first turn with "Missing API key for provider: OpenAI"
        // (a confusing experience). The check runs AFTER the .env
        // load so a key in `<workDir>/.env` is honoured.
        let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
        guard !apiKey.isEmpty else {
            FileHandle.standardError.write(Data("""
            error: OPENAI_API_KEY is not set.
              • Export it in your shell:  export OPENAI_API_KEY=sk-...
              • Or drop it into a `.env` file in the working directory.

            """.utf8))
            throw ExitCode(1)
        }

        // The `OpenAITraceExporter` auto-registers when the first `OpenAI`
        // client is constructed with `OPENAI_API_KEY` set; trigger it
        // explicitly here so it lands before the first run starts. Then
        // add the JSONL processor alongside.
        OpenAITracingAutoConfig.configureIfNeeded()
        let sessionFileURL = makeSessionFileURL()
        await TraceProvider.shared.addProcessor(
            JSONLTracingProcessor(fileURL: sessionFileURL)
        )

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

        // Handle user input
        let model = model
        let lastResponseId = ResponseIdBox()
        terminal.handleInput = { input in
            guard !input.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let sema = DispatchSemaphore(value: 0)

            Task {
                defer { sema.signal() }

                let config = RunConfig(model: model, workFlowName: "Coder Turn")
                let result = Runner.runStreamed(
                    agent: agent,
                    input: input,
                    maxTurns: 50,
                    previousResponseId: lastResponseId.value,
                    config: config
                )

                do {
                    var hasReasoning = false
                    var hasOutput = false
                    var lastWasToolCall = false
                    var lastDelta = ""
                    var lineBuffer = ""
                    var inCodeBlock = false

                    for try await event in result.events {
                        switch event {
                            case let .rawResponseEvent(raw):
                                switch raw.object {
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
                                    default:
                                        break
                                }
                            case let .runItemEvent(name, item):
                                if case .toolCalled = name, case let .toolCall(toolName, args, _) = item {
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
                    lastResponseId.value = result.lastResponseId
                } catch let error as RunnerError {
                    switch error {
                        case .exceededMaxTurns:
                            terminal.output("Error: Agent exceeded maximum number of turns.".red)
                        case .mediaOutputNotStreamable:
                            terminal.output("Error: Streaming isn't supported for media output.".red)
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
