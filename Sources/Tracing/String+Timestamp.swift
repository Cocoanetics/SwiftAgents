//
//  String+Timestamp.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 07.05.25.
//

import Foundation

public extension String {
    static var timestamp: String {
        // Wall-clock time since 1970. `Date` is cross-platform — POSIX
        // `clock_gettime` / `CLOCK_REALTIME` aren't available on Windows — and
        // microsecond precision is plenty for trace timestamps.
        let now = Date().timeIntervalSince1970
        let seconds = now.rounded(.down)
        let microseconds = Int((now - seconds) * 1_000_000)

        // Format the seconds portion using Date
        let date = Date(timeIntervalSince1970: seconds)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let base = formatter.string(from: date)
        let microsString = String(format: "%06d", microseconds)
        return "\(base).\(microsString)+00:00"
    }
}
