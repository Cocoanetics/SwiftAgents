import Foundation
import EventKit

actor CalendarHandler {
    private let eventStore = EKEventStore()

    private func ensureCalendarAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess:
            return
        case .notDetermined:
            let granted = try await eventStore.requestFullAccessToEvents()
            guard granted else { throw CalendarError.notAuthorized }
        default:
            throw CalendarError.notAuthorized
        }
    }

    /**
     Retrieves a list of all available calendars from the user's system.
     
     - Note: This function requires full calendar access authorization. If not authorized, it will throw a CalendarError.notAuthorized error.
     */
    func listCalendars() async throws -> [EKCalendar] {
        try await ensureCalendarAccess()

        // Get all calendars
        let calendars = eventStore.calendars(for: .event)

        return calendars
    }

    /**
     Get events from the calendar with flexible filtering options.
     
     - Parameters:
        - startDate: ISO date string for the start of the date range (defaults to now if not specified)
        - endDate: ISO date string for the end of the date range (defaults to one week from start if not specified)
        - calendarNames: Names of calendars to fetch from. If empty or not specified, fetches from all calendars.
        - calendarIdentifiers: Identifiers of calendars to fetch from. Takes precedence over calendarNames if both are provided.
        - searchText: Text to search for in event titles, locations, notes, URLs, and external identifiers
        - includeAllDay: Whether to include all-day events (defaults to true)
        - status: Filter by event status ("none", "tentative", "confirmed", "canceled")
        - availability: Filter by availability status ("busy", "free", "tentative", "unavailable")
        - hasAlarms: Filter for events that have alarms/reminders set
        - isRecurring: Filter for recurring/non-recurring events
     */
    func fetchEvents(
        startDate: Date? = nil,
        endDate: Date? = nil,
        calendarNames: [String]? = nil,
        calendarIdentifiers: [String]? = nil,
        searchText: String? = nil,
        includeAllDay: Bool = true,
        status: EKEventStatus? = nil,
        availability: EKEventAvailability? = nil,
        hasAlarms: Bool? = nil,
        isRecurring: Bool? = nil
    ) async throws -> [EKEvent] {
        try await ensureCalendarAccess()

        // Get all calendars or filter by names/identifiers
        var eventCalendars = eventStore.calendars(for: .event)

        if let calendarIdentifiers = calendarIdentifiers, !calendarIdentifiers.isEmpty {
            let requestedIds = Set(calendarIdentifiers)
            eventCalendars = eventCalendars.filter {
                requestedIds.contains($0.calendarIdentifier)
            }
        } else if let calendarNames = calendarNames, !calendarNames.isEmpty {
            let requestedNames = Set(calendarNames.map { $0.lowercased() })
            eventCalendars = eventCalendars.filter {
                requestedNames.contains($0.title.lowercased())
            }
        }

        // Set default date range if not provided
        let now = Date()
        let defaultStartDate = startDate ?? now
        let defaultEndDate = endDate ?? Calendar.current.date(byAdding: .month, value: 1, to: defaultStartDate)!

        // Create predicate for date range and calendars using EventKit's method
        let predicate = eventStore.predicateForEvents(
            withStart: defaultStartDate,
            end: defaultEndDate,
            calendars: eventCalendars
        )

        // Fetch events
        var events = eventStore.events(matching: predicate)

        // Apply additional filters in memory since EventKit doesn't support filtering them via predicate
        if !includeAllDay {
            events = events.filter { !$0.isAllDay }
        }

        if let searchText = searchText, !searchText.isEmpty {
            events = events.filter { event in
                // Search in title and location
                let titleMatch = event.title?.localizedCaseInsensitiveContains(searchText) == true
                let locationMatch = event.location?.localizedCaseInsensitiveContains(searchText) == true

                // Search in notes
                let notesMatch = event.notes?.localizedCaseInsensitiveContains(searchText) == true

                // Search in URL
                var urlString: String?
                if let url = event.url {
                    urlString = url.absoluteString
                }
                let urlMatch = urlString?.localizedCaseInsensitiveContains(searchText) == true

                // Search in external identifier
                let externalIdMatch = event.calendarItemExternalIdentifier?.localizedCaseInsensitiveContains(searchText) == true

                return titleMatch || locationMatch || notesMatch || urlMatch || externalIdMatch
            }
        }

        if let eventStatus = status {
            events = events.filter { $0.status == eventStatus }
        }

        if let eventAvailability = availability {
            events = events.filter { $0.availability == eventAvailability }
        }

        if let hasAlarms = hasAlarms {
            events = events.filter { $0.hasAlarms == hasAlarms }
        }

        if let isRecurring = isRecurring {
            events = events.filter { $0.hasRecurrenceRules == isRecurring }
        }

        // Sort events by start date and title
        events.sort { event1, event2 in
            if let date1 = event1.startDate,
               let date2 = event2.startDate {
                if date1 != date2 {
                    return date1 < date2
                }
            }
            return (event1.title ?? "") < (event2.title ?? "")
        }

        return events
    }

    /**
     Create a new calendar event with specified properties
     
     - Parameters:
        - title: The title of the event
        - startDate: Start time of the event
        - endDate: End time of the event
        - calendarName: Name of the calendar to create the event in (uses default calendar if not specified)
        - calendarIdentifier: Identifier of the calendar to create the event in (takes precedence over calendarName)
        - location: Location of the event
        - notes: Notes or description for the event
        - url: URL associated with the event (e.g., meeting link)
        - isAllDay: Whether this is an all-day event (default: false)
        - availability: Availability status for the event ("busy", "free", "tentative", "unavailable", default: "busy")
        - alarms: The relative offset to the to the dueDate in seconds (optional)
        - recurrence: Recurrence rules for the event (frequency: "daily", "weekly", "monthly", "yearly", interval: number, endDate or occurrences)
     */
    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        calendarName: String? = nil,
        calendarIdentifier: String? = nil,
        location: String? = nil,
        notes: String? = nil,
        url: URL? = nil,
        isAllDay: Bool = false,
        availability: EKEventAvailability = .busy,
        alarms: [Int] = [],
        recurrence: [RecurrenceRule]? = nil
    ) async throws -> EKEvent {
        try await ensureCalendarAccess()

        // Create new event
        let event = EKEvent(eventStore: eventStore)

        // Set required properties
        event.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !event.title.isEmpty else {
            throw CalendarError.emptyTitle
        }

        event.startDate = startDate
        event.endDate = endDate

        // Set calendar (identifier takes precedence over name)
        var calendar = eventStore.defaultCalendarForNewEvents
        if let identifier = calendarIdentifier {
            if let matchingCalendar = eventStore.calendars(for: .event)
                .first(where: { $0.calendarIdentifier == identifier }) {
                calendar = matchingCalendar
            } else {
                throw CalendarError.calendarNotFound("Calendar with identifier '\(identifier)' not found")
            }
        } else if let name = calendarName {
            if let matchingCalendar = eventStore.calendars(for: .event)
                .first(where: { $0.title.lowercased() == name.lowercased() }) {
                calendar = matchingCalendar
            } else {
                throw CalendarError.calendarNotFound("Calendar named '\(name)' not found")
            }
        }

        guard let calendar = calendar else {
            throw CalendarError.noDefaultCalendar
        }
        event.calendar = calendar

        // Set optional properties
        if let location = location {
            event.location = location
        }

        if let notes = notes {
            event.notes = notes
        }

        if let url = url {
            event.url = url
        }

        event.isAllDay = isAllDay
        event.availability = availability

        // Set alarms
        event.alarms = alarms.map {
            EKAlarm(relativeOffset: TimeInterval($0))
        }

		event.recurrenceRules = recurrence?.map({ rule in

			return rule.toEKRecurrenceRule()
		})

        // Save the event
        try eventStore.save(event, span: .thisEvent)

        return event
    }

    /**
     Modify an existing event's properties
     
     - Parameters:
        - identifier: The unique identifier of the event
        - title: Optional new title for the event
        - startDate: Optional new start date as ISO date string
        - endDate: Optional new end date as ISO date string
        - isAllDay: Optional new all-day status
        - location: Optional new location for the event
        - url: Optional new URL for the event
        - notes: Optional new notes for the event
        - availability: Optional new availability status ("busy", "free", "tentative", "unavailable")
        - alarms: The relative offset to the to the startDate in seconds (optional)
        - span: Whether to modify just this event or this and all future events for recurring events ("thisEvent" or "futureEvents", default: "thisEvent")
     */
    func modifyEvent(
        identifier: String,
        title: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        isAllDay: Bool? = nil,
        location: String? = nil,
        url: URL? = nil,
        notes: String? = nil,
        availability: EKEventAvailability? = nil,
        alarms: [Int]? = nil,
        span: EKSpan = .thisEvent
    ) async throws -> EKEvent {
        try await ensureCalendarAccess()

        // Find the event by identifier
        guard let event = eventStore.calendarItem(withIdentifier: identifier) as? EKEvent else {
            throw CalendarError.eventNotFound(identifier)
        }

        // Update properties if provided
        if let title = title {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else {
                throw CalendarError.emptyTitle
            }
            event.title = trimmedTitle
        }

        if let startDate = startDate {
            event.startDate = startDate
        }

        if let endDate = endDate {
            event.endDate = endDate
        }

        if let location = location {
            event.location = location
        }

        if let notes = notes {
            event.notes = notes
        }

        if let url = url {
            event.url = url
        }

        if let isAllDay = isAllDay {
            event.isAllDay = isAllDay
        }

        if let availability = availability {
            event.availability = availability
        }

        if let alarms = alarms {
            event.alarms = alarms.map {
                EKAlarm(relativeOffset: TimeInterval($0))
            }
        }

        // Save changes
        try eventStore.save(event, span: span)

        return event
    }

    /**
     Remove an event from the calendar
     
     - Parameters:
        - identifier: The unique identifier of the event to remove
        - span: Whether to remove just this event or this and all future events for recurring events ("thisEvent" or "futureEvents", default: "thisEvent")
     */
    func removeEvent(
        identifier: String,
        span: EKSpan = .thisEvent
    ) async throws {
        try await ensureCalendarAccess()

        // Find the event by identifier
        guard let event = eventStore.calendarItem(withIdentifier: identifier) as? EKEvent else {
            throw CalendarError.eventNotFound(identifier)
        }

        // Remove the event
        do {
            try eventStore.remove(event, span: span)
        } catch {
            throw CalendarError.removeEventFailed(error.localizedDescription)
        }
    }
}
