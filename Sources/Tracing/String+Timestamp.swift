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
        // UTC trace timestamp with 6 fractional (microsecond) digits — the
        // exact format used before. The value is sourced from SwiftCross's
        // `WallClock`, a true nanosecond clock (clock_gettime(CLOCK_REALTIME)
        // on POSIX, GetSystemTimePreciseAsFileTime on Windows), so the
        // microseconds are exact and the same source works on every platform.
        // Foundation's `Date` can't supply this (its Double seconds carry only
        // ~100ns of granularity), which is why the clock lives in SwiftCross.
        let (seconds, nanoseconds) = WallClock.now()
        let microseconds = nanoseconds / 1000

        // Format the seconds portion using Date.
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let base = formatter.string(from: date)
        let microsString = String(format: "%06d", microseconds)
        return "\(base).\(microsString)+00:00"
    }
}
