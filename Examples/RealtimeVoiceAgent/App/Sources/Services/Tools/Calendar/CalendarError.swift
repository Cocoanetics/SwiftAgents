//
//  CalendarError.swift
//  API.me
//
//  Created by Oliver Drobnik on 27.03.25.
//

import Foundation

enum CalendarError: LocalizedError {
	case notAuthorized
	case noDefaultCalendar
	case emptyTitle
	case calendarNotFound(String)
	case eventNotFound(String)
	case removeEventFailed(String)

	var errorDescription: String? {
		switch self {
		case .notAuthorized:
			return "Calendar access is not authorized. Please grant access in Settings."
		case .noDefaultCalendar:
			return "No default calendar available for creating events."
		case .emptyTitle:
			return "Event title cannot be empty."
		case .calendarNotFound(let message):
			return message
		case .eventNotFound(let identifier):
			return "Event with identifier '\(identifier)' not found."
		case .removeEventFailed(let message):
			return "Failed to remove event: \(message)"
		}
	}
}
