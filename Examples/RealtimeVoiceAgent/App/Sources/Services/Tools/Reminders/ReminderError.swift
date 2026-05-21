import Foundation

enum ReminderError: LocalizedError {
	case notAuthorized
	case noDefaultCalendar
	case listNotFound(String)
	case emptyTitle
	case reminderNotFound(String)
	case removeReminderFailed(String)

	var errorDescription: String? {
		switch self {
		case .notAuthorized:
			return "Reminder access is not authorized. Please grant access in Settings."
		case .noDefaultCalendar:
			return "No default calendar available for creating reminders."
		case .listNotFound(let name):
			return "Reminder list '\(name)' not found."
		case .emptyTitle:
			return "Reminder title cannot be empty."
		case .reminderNotFound(let identifier):
			return "Reminder with identifier '\(identifier)' not found."
		case .removeReminderFailed(let message):
			return "Failed to remove reminder: \(message)"
		}
	}
}
