//
//  String+Timestamp.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 07.05.25.
//


import Foundation

extension String
{
	public static var timestamp: String {
		var ts = timespec()
		clock_gettime(CLOCK_REALTIME, &ts)

		let seconds = ts.tv_sec
		let nanoseconds = ts.tv_nsec
		let microseconds = nanoseconds / 1000

		// Format the seconds portion using Date
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
