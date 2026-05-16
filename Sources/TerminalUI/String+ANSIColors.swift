//
//  String+ANSIColors.swift
//
//
//  Created by Oliver Drobnik on 22.04.24.
//

import Foundation

public extension String {
    /// Ensure reset is added only if necessary
    private var resetIfNeeded: String {
        if !hasSuffix(ANSIColors.reset) {
            return self + ANSIColors.reset
        }
        return self
    }

    /// Style properties
    var bold: String {
        (ANSIColors.bold + self).resetIfNeeded
    }

    var dim: String {
        (ANSIColors.dim + self).resetIfNeeded
    }

    var italic: String {
        (ANSIColors.italic + self).resetIfNeeded
    }

    var underline: String {
        (ANSIColors.underline + self).resetIfNeeded
    }

    var blink: String {
        (ANSIColors.blink + self).resetIfNeeded
    }

    var reverse: String {
        (ANSIColors.reverse + self).resetIfNeeded
    }

    var hidden: String {
        (ANSIColors.hidden + self).resetIfNeeded
    }

    var strike: String {
        (ANSIColors.strike + self).resetIfNeeded
    }

    /// Color properties
    var red: String {
        (ANSIColors.red + self).resetIfNeeded
    }

    var green: String {
        (ANSIColors.green + self).resetIfNeeded
    }

    var yellow: String {
        (ANSIColors.yellow + self).resetIfNeeded
    }

    var blue: String {
        (ANSIColors.blue + self).resetIfNeeded
    }

    var magenta: String {
        (ANSIColors.magenta + self).resetIfNeeded
    }

    var cyan: String {
        (ANSIColors.cyan + self).resetIfNeeded
    }

    var white: String {
        (ANSIColors.white + self).resetIfNeeded
    }

    /// Bright color properties
    var brightRed: String {
        (ANSIColors.brightRed + self).resetIfNeeded
    }

    var brightGreen: String {
        (ANSIColors.brightGreen + self).resetIfNeeded
    }

    var brightYellow: String {
        (ANSIColors.brightYellow + self).resetIfNeeded
    }

    var brightBlue: String {
        (ANSIColors.brightBlue + self).resetIfNeeded
    }

    var brightMagenta: String {
        (ANSIColors.brightMagenta + self).resetIfNeeded
    }

    var brightCyan: String {
        (ANSIColors.brightCyan + self).resetIfNeeded
    }

    var brightWhite: String {
        (ANSIColors.brightWhite + self).resetIfNeeded
    }

    func removingANSISequences() -> String {
        let regex = #"(\u001B\[[0-9;]*m)"#
        return replacingOccurrences(of: regex, with: "", options: .regularExpression)
    }

    /// Converts basic Markdown inline formatting to ANSI escape codes.
    /// Supports **bold**, *italic*, `code`, and ~~strikethrough~~.
    var markdownToANSI: String {
        var result = self
        // Bold: **text**
        result = result.replacingOccurrences(
            of: #"\*\*(.+?)\*\*"#,
            with: ANSIColors.bold + "$1" + ANSIColors.reset,
            options: .regularExpression
        )
        // Italic: *text* — only when * is not a bullet point (preceded by non-whitespace or start-of-string non-newline)
        result = result.replacingOccurrences(
            of: #"(?<=\S)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#,
            with: ANSIColors.italic + "$1" + ANSIColors.reset,
            options: .regularExpression
        )
        // Code: `text`
        result = result.replacingOccurrences(
            of: #"`([^`]+)`"#,
            with: ANSIColors.dim + "$1" + ANSIColors.reset,
            options: .regularExpression
        )
        // Strikethrough: ~~text~~
        result = result.replacingOccurrences(
            of: #"~~(.+?)~~"#,
            with: ANSIColors.strike + "$1" + ANSIColors.reset,
            options: .regularExpression
        )
        return result
    }
}
