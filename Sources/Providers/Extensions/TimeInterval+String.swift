//
//  TimeInterval+String.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 24.01.25.
//

import Foundation

extension TimeInterval {
    /// Parses a duration string like "1m0s", "30s", "5ms" into a `TimeInterval` (seconds).
    init(rateLimitString: String) {
        let scanner = Scanner(string: rateLimitString)
        var totalSeconds: TimeInterval = 0

        while !scanner.isAtEnd {
            if let value = scanner.scanDouble() {
                if scanner.scanString("ms") != nil {
                    totalSeconds += value / 1000.0 // Convert milliseconds to seconds
                } else if scanner.scanString("s") != nil {
                    totalSeconds += value
                } else if scanner.scanString("m") != nil {
                    totalSeconds += value * 60.0
                }
            }
        }

        self = totalSeconds
    }
}
