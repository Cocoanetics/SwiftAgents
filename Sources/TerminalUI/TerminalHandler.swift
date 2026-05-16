import Foundation

public class TerminalHandler {
    public let supportsANSI: Bool

    private var originalTermios = termios()
    private var inputBuffer = ""
    private let prompt: String
    private let placeholder: String

    public var handleInput: ((String) -> Void)?
    public var slashCommandHandler = SlashCommandHandler()

    public init() {
        // Determine ANSI support first
        supportsANSI = TerminalHandler.supportsANSICodes()

        // Initialize prompt and placeholder using the supportsANSI
        prompt = supportsANSI ? ">>> ".bold : ">>> "
        placeholder = supportsANSI ? "Send a message (/? for help)".dim : ""

        setupTerminal()
    }

    deinit {
        resetTerminalMode()
    }

    public static func supportsANSICodes() -> Bool {
        guard let termType = ProcessInfo.processInfo.environment["TERM"] else {
            return false
        }
        return !termType.contains("dumb") && termType.lowercased() != "vt100"
    }

    /// Global reference so the SIGWINCH C handler can trigger a redraw.
    private weak static var activeHandler: TerminalHandler?

    private func setupTerminal() {
        if supportsANSI {
            tcgetattr(STDIN_FILENO, &originalTermios)
            var raw = originalTermios
            raw.c_lflag &= ~UInt(ECHO | ICANON)
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)

            // Listen for terminal resize
            TerminalHandler.activeHandler = self
            signal(SIGWINCH) { _ in
                TerminalHandler.activeHandler?.handleResize()
            }
        }
    }

    private func handleResize() {
        // Terminal reflows text on resize, making cursor position unpredictable.
        // Reset line tracking so the next keystroke redraws cleanly.
        previousVisualLines = 1
    }

    private func resetTerminalMode() {
        if supportsANSI {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
        }
    }

    public func output(_ string: String, addLineFeed: Bool = true) {
        let terminator = addLineFeed ? "\n" : ""

        if supportsANSI {
            print(string, terminator: terminator)
        } else {
            print(string.removingANSISequences(), terminator: terminator)
        }

        fflush(stdout)
        previousVisualLines = 1
    }

    private var terminalWidth: Int {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0 {
            return Int(ws.ws_col)
        }
        return 80
    }

    /// Number of visual lines a string occupies given the terminal width.
    private func visualLineCount(_ text: String) -> Int {
        let cols = terminalWidth
        guard cols > 0 else { return 1 }
        let len = text.removingANSISequences().count
        return max(1, (len + cols - 1) / cols)
    }

    /// Track how many visual lines the previous display used, so we can clear them.
    private var previousVisualLines = 1

    private func updateDisplay() {
        if supportsANSI {
            // Move cursor up to the start of the previous display, clearing each line
            if previousVisualLines > 1 {
                print("\u{001B}[\(previousVisualLines - 1)A", terminator: "")
            }
            for _ in 0 ..< previousVisualLines {
                print("\u{001B}[2K\u{001B}[1B", terminator: "")
            }
            // Move back up to the first line
            print("\u{001B}[\(previousVisualLines)A", terminator: "")
            print("\r", terminator: "")

            let displayText: String
            if inputBuffer.isEmpty {
                displayText = "\(prompt.blue.bold)\(placeholder)"
                print(displayText, terminator: "")
                // Position cursor right after prompt (before placeholder)
                print("\r\(prompt.blue.bold)", terminator: "")
                previousVisualLines = visualLineCount(prompt + placeholder)
            } else {
                displayText = "\(prompt.blue.bold)\(inputBuffer)"
                print(displayText, terminator: "")
                previousVisualLines = visualLineCount(prompt + inputBuffer)
            }
            fflush(stdout)
        } else {
            if inputBuffer.isEmpty {
                print("\(prompt)\(placeholder)", terminator: "")
            }
        }
    }

    public func run() async {
        updateDisplay()
        var escapeSequenceActive = false // Flag for tracking escape sequences
        var escapeBuffer = [UInt8]() // Buffer to capture the escape sequence

        while true {
            var ch: UInt8 = 0
            if read(STDIN_FILENO, &ch, 1) == 1 {
                if escapeSequenceActive {
                    escapeBuffer.append(ch)

                    if escapeBuffer.count == 3 { // Length of typical arrow key sequence
                        if escapeBuffer[0] == 27, escapeBuffer[1] == 91 { // ESC + [
                            if escapeBuffer[2] == 65 || escapeBuffer[2] == 66 || escapeBuffer[2] == 67 ||
                                escapeBuffer[2] == 68 { // A, B, C, D
                                escapeSequenceActive = false // It's an arrow key, ignore this sequence
                                escapeBuffer.removeAll()
                                continue
                            }
                        }
                        // If not a recognized arrow key, stop ignoring and process normally
                        escapeSequenceActive = false
                        for byte in escapeBuffer {
                            await processNormally(byte)
                        }
                        escapeBuffer.removeAll()
                    }
                } else if ch == 27 { // Start of an escape sequence
                    escapeSequenceActive = true
                    escapeBuffer.append(ch)
                    continue
                }

                // Regular input processing
                if !escapeSequenceActive {
                    await processNormally(ch)
                }
            }
        }
    }

    public func processNormally(_ ch: UInt8) async {
        if ch == 10 { // Newline character

            // Beep and stay on the same line if input is empty
            guard !inputBuffer.isEmpty else {
                print("\u{07}", terminator: "")
                fflush(stdout)
                return
            }

            if supportsANSI {
                print("\n")
            } else {
                print("")
            }

            if inputBuffer.hasPrefix("/") {
                let afterSlash = inputBuffer[inputBuffer.index(inputBuffer.startIndex, offsetBy: 1)...]
                let slashCommand = afterSlash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

                do {
                    try await slashCommandHandler.execute(slashCommand: slashCommand)
                } catch {
                    output(error.localizedDescription.red.blink + "\n")
                }
            } else {
                handleInput?(inputBuffer)
            }

            inputBuffer = "" // Clear the buffer after handling the command
            updateDisplay()
        } else if ch == 127 { // Backspace character
            if !inputBuffer.isEmpty {
                inputBuffer.removeLast()
                updateDisplay()
            }
        } else if ch == 23 { // Ctrl+W — delete word
            deleteWord()
            updateDisplay()
        } else {
            inputBuffer.append(Character(UnicodeScalar(ch)))
            updateDisplay()
        }
    }

    // MARK: - Helpers

    /// Delete the last word from the input buffer (Option+Backspace / Ctrl+W).
    private func deleteWord() {
        guard !inputBuffer.isEmpty else { return }
        // Remove trailing whitespace first
        while inputBuffer.last?.isWhitespace == true {
            inputBuffer.removeLast()
        }
        // Then remove until next whitespace or empty
        while !inputBuffer.isEmpty, inputBuffer.last?.isWhitespace != true {
            inputBuffer.removeLast()
        }
    }

    /// Function to clear the screen
    public func clearScreen() {
        guard !supportsANSI else {
            print("\u{001B}[2J\u{001B}[H", terminator: "")
            return
        }

        #if os(macOS)
            // Fallback to using the clear command on macOS
            let task = Process()
            task.launchPath = "/usr/bin/clear"
            task.launch()
            task.waitUntilExit()
        #endif
    }
}
