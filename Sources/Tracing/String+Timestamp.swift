//
//  String+Timestamp.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 07.05.25.
//

import Foundation
import SwiftCross

public extension String {
    static var timestamp: String {
        // Wall-clock time at nanosecond resolution. OpenAI's trace ingestion
        // needs nanosecond-precision timestamps, and Foundation's `Date` can't
        // represent them (its `Double` seconds carry only ~100 ns of
        // granularity near the current epoch), so source the time from
        // SwiftCross's `WallClock` — `clock_gettime(CLOCK_REALTIME)` on POSIX,
        // `GetSystemTimePreciseAsFileTime` on Windows.
        let (seconds, nanoseconds) = WallClock.now()

        // Format the seconds portion using Date.
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let base = formatter.string(from: date)
        let nanosString = String(format: "%09d", nanoseconds)
        return "\(base).\(nanosString)+00:00"
    }
}
