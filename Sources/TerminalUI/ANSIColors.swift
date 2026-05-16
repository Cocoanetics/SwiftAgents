//
//  ANSIColors.swift
//
//
//  Created by Oliver Drobnik on 22.04.24.
//

import Foundation

// https://gist.github.com/fnky/458719343aabd01cfb17a3a4f7296797

public enum ANSIColors {
    /// Reset
    public static let reset = "\u{001B}[0m"

    // Foreground Colors
    public static let black = "\u{001B}[30m"
    public static let red = "\u{001B}[31m"
    public static let green = "\u{001B}[32m"
    public static let yellow = "\u{001B}[33m"
    public static let blue = "\u{001B}[34m"
    public static let magenta = "\u{001B}[35m"
    public static let cyan = "\u{001B}[36m"
    public static let white = "\u{001B}[37m"
    public static let brightBlack = "\u{001B}[30;1m"
    public static let brightRed = "\u{001B}[31;1m"
    public static let brightGreen = "\u{001B}[32;1m"
    public static let brightYellow = "\u{001B}[33;1m"
    public static let brightBlue = "\u{001B}[34;1m"
    public static let brightMagenta = "\u{001B}[35;1m"
    public static let brightCyan = "\u{001B}[36;1m"
    public static let brightWhite = "\u{001B}[37;1m"

    // Background Colors
    public static let bgBlack = "\u{001B}[40m"
    public static let bgRed = "\u{001B}[41m"
    public static let bgGreen = "\u{001B}[42m"
    public static let bgYellow = "\u{001B}[43m"
    public static let bgBlue = "\u{001B}[44m"
    public static let bgMagenta = "\u{001B}[45m"
    public static let bgCyan = "\u{001B}[46m"
    public static let bgWhite = "\u{001B}[47m"

    // Styles
    public static let bold = "\u{001B}[1m"
    public static let dim = "\u{001B}[2m"
    public static let italic = "\u{001B}[3m"
    public static let underline = "\u{001B}[4m"
    public static let blink = "\u{001B}[5m"
    public static let reverse = "\u{001B}[7m"
    public static let hidden = "\u{001B}[8m"
    public static let strike = "\u{001B}[9m"
}
