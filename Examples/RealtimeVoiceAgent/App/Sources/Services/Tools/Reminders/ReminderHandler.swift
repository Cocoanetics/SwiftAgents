//
//  ReminderHandler.swift
//  API.me
//
//  Created by Oliver Drobnik on 27.03.25.
//

import Foundation
import EventKit

actor ReminderHandler {
	private let eventStore = EKEventStore()

	private func ensureReminderAccess() async throws {
		let status = EKEventStore.authorizationStatus(for: .reminder)
		switch status {
		case .fullAccess:
			return
		case .notDetermined:
			let granted = try await eventStore.requestFullAccessToReminders()
			guard granted else { throw ReminderError.notAuthorized }
		default:
			throw ReminderError.notAuthorized
		}
	}

	/**
	 Retrieves a list of all available reminder lists from the user's system.
	 
	 - Note: This function requires full calendar access authorization. If not authorized, it will throw a CalendarError.notAuthorized error.
	 */
	func listReminderLists() async throws -> [EKCalendar] {
		// Get all reminder lists
		let lists = eventStore.calendars(for: .reminder)

		return lists
//
//		// Map to our simplified model
//		return lists.map { list in
//			ReminderList(calendar: list)
//		}
	}

	/**
	 Get reminders from the reminders app with flexible filtering options.
	 
	 - Parameters:
	    - completed: If true, fetch completed reminders. If false, fetch incomplete reminders. If not specified, fetch all reminders.
	    - startDate: ISO date string for the start of the date range to fetch reminders from
	    - endDate: ISO date string for the end of the date range to fetch reminders from
	    - listNames: Names of reminder lists to fetch from. If empty or not specified, fetches from all lists.
	    - searchText: Text to search for in reminder titles
	 */
	func fetchReminders(
		completed: Bool? = nil,
		startDate: Date? = nil,
		endDate: Date? = nil,
		listNames: [String]? = nil,
		searchText: String? = nil
	) async throws -> [EKReminder] {
		try await ensureReminderAccess()

		// Get all reminder lists or filter by names
		var reminderLists = eventStore.calendars(for: .reminder)
		if let listNames = listNames, !listNames.isEmpty {
			let requestedNames = Set(listNames.map { $0.lowercased() })
			reminderLists = reminderLists.filter {
				requestedNames.contains($0.title.lowercased())
			}
		}

		// Create predicate based on completion status
		let predicate: NSPredicate
		if let completed = completed {
			if completed {
				predicate = eventStore.predicateForCompletedReminders(
					withCompletionDateStarting: startDate,
					ending: endDate,
					calendars: reminderLists
				)
			} else {
				predicate = eventStore.predicateForIncompleteReminders(
					withDueDateStarting: startDate,
					ending: endDate,
					calendars: reminderLists
				)
			}
		} else {
			predicate = eventStore.predicateForReminders(in: reminderLists)
		}

		// Fetch reminders
		let reminders = try await eventStore.fetchReminders(matching: predicate)

		// Apply search text filter if provided
		var filteredReminders = reminders
		if let searchText = searchText, !searchText.isEmpty {
			filteredReminders = filteredReminders.filter {
				$0.title.localizedCaseInsensitiveContains(searchText)
			}
		}

		// Sort reminders by due date (if available) and title
		filteredReminders.sort { reminder1, reminder2 in
			if let date1 = reminder1.dueDateComponents?.date,
			   let date2 = reminder2.dueDateComponents?.date {
				if date1 != date2 {
					return date1 < date2
				}
			}
			return reminder1.title < reminder2.title
		}

		return filteredReminders
	}

	/**
	 Create a new reminder with specified properties
	 
	 - Parameters:
	    - title: The title of the reminder
	    - dueDate: ISO date string for when the reminder is due
	    - listName: Name of the reminder list to add the reminder to (uses default if not specified)
	    - notes: Additional notes for the reminder
	    - priority: Priorities run from 1 (highest) to 9 (lowest).  A priority of 0 means no priority.
	    - alarms: The relative offset to the to the dueDate in seconds
	 */
	func createReminder(
		title: String,
		dueDate: Date? = nil,
		listName: String? = nil,
		notes: String? = nil,
		priority: Int = 0,
		alarms: [Int]
	) async throws -> EKReminder {
		try await ensureReminderAccess()

		let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

		// Validate title
		guard !trimmedTitle.isEmpty else {
			throw ReminderError.emptyTitle
		}

		let reminder = EKReminder(eventStore: eventStore)

		// Set required properties
		reminder.title = trimmedTitle

		if let listName = listName {
			let matchingCalendar = eventStore.calendars(for: .reminder)
				.first(where: { $0.title.lowercased() == listName.lowercased() })

			guard let calendar = matchingCalendar else {
				throw ReminderError.listNotFound(listName)
			}

			reminder.calendar = calendar
		} else {
			// Set default calendar
			guard let calendar = eventStore.defaultCalendarForNewReminders() else {
				throw ReminderError.noDefaultCalendar
			}

			reminder.calendar = calendar
		}

		// Set optional properties
		if let dueDate = dueDate {
			reminder.dueDateComponents = Calendar.current.dateComponents(
				[.year, .month, .day, .hour, .minute, .second], from: dueDate)
		}

		if let notes = notes {
			reminder.notes = notes
		}

		reminder.priority = priority
		reminder.alarms = alarms.map { EKAlarm(relativeOffset: TimeInterval($0)) }

		try eventStore.save(reminder, commit: true)

		return reminder
	}

	/**
	 Modify an existing reminder's properties
	 
	 - Parameters:
	    - identifier: The unique identifier of the reminder
	    - isCompleted: Optional new completion status
	    - title: Optional new title for the reminder
	    - dueDate: Optional new due date as ISO date string
	    - notes: Optional new notes for the reminder
	    - priority: Priorities run from 1 (highest) to 9 (lowest).  A priority of 0 means no priority.
	    - alarms: The relative offset to the to the dueDate in seconds (optional)

	 - Returns: The modified reminder
	 - Throws: ReminderError if the reminder is not found or access is not authorized
	 */
	func modifyReminder(
		identifier: String,
		isCompleted: Bool? = nil,
		title: String? = nil,
		dueDate: Date? = nil,
		notes: String? = nil,
		priority: Int? = nil,
		alarms: [Int]? = nil
	) async throws -> EKReminder {
		try await ensureReminderAccess()

		// Find the reminder by identifier
		guard let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else {
			throw ReminderError.reminderNotFound(identifier)
		}

		// Update properties if provided
		if let isCompleted = isCompleted {
			reminder.isCompleted = isCompleted
			reminder.completionDate = isCompleted ? Date() : nil
		}

		if let title = title {
			let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmedTitle.isEmpty else {
				throw ReminderError.emptyTitle
			}
			reminder.title = trimmedTitle
		}

		if let dueDate = dueDate {
			reminder.dueDateComponents = Calendar.current.dateComponents(
				[.year, .month, .day, .hour, .minute, .second], from: dueDate)
		}

		if let notes = notes {
			reminder.notes = notes
		}

		if let priority = priority {
			reminder.priority = priority
		}

		if let alarms = alarms {
			reminder.alarms = alarms.map { EKAlarm(relativeOffset: TimeInterval($0)) }
		}

		// Save changes
		try eventStore.save(reminder, commit: true)

		return reminder
	}

	/**
	 Remove a reminder
	 
	 - Parameters:
	    - identifier: The unique identifier of the reminder to remove
	 */
	func removeReminder(identifier: String) async throws {
		// Check authorization status
		try await ensureReminderAccess()

		// Find the reminder by identifier
		guard let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else {
			throw ReminderError.reminderNotFound(identifier)
		}

		// Remove the reminder
		do {
			try eventStore.remove(reminder, commit: true)
		} catch {
			throw ReminderError.removeReminderFailed(error.localizedDescription)
		}
	}
}
