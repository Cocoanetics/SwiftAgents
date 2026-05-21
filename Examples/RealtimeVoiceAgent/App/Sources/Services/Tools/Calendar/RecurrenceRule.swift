//
//  RecurrenceRule.swift
//  API.me
//
//  Created by Oliver Drobnik on 29.03.25.
//

import EventKit
import Foundation
import SwiftMCP

/// A structure representing recurrence rules for calendar events
@Schema
public struct RecurrenceRule: Codable {
    /// Calendar used by this recurrence rule
    public let calendarIdentifier: String

    /// How often the event repeats
    public let frequency: EKRecurrenceFrequency

    /// Interval of the frequency (e.g., 2 for every 2 weeks)
    public let interval: Int

    /// First day of the week (1-7, where 1 is Sunday, 0 means not set)
    public let firstDayOfTheWeek: Int?

    /// Days of the week the event recurs (valid for weekly, monthly, or yearly frequencies)
    public let daysOfTheWeek: [EKWeekday]?

    /// Days of the month the event recurs (1-31 or -31 to -1, valid for monthly frequency)
    public let daysOfTheMonth: [Int]?

    /// Days of the year the event recurs (1-366 or -366 to -1, valid for yearly frequency)
    public let daysOfTheYear: [Int]?

    /// Weeks of the year the event recurs (1-53 or -53 to -1, valid for yearly frequency)
    public let weeksOfTheYear: [Int]?

    /// Months of the year the event recurs (1-12, valid for yearly frequency)
    public let monthsOfTheYear: [Int]?

    /// Set positions for filtering recurrence results (-366 to 366, except 0)
    public let setPositions: [Int]?

    /// When the recurrence ends (either by date or number of occurrences)
    public let recurrenceEnd: RecurrenceEnd?

    /// Creates a new recurrence rule
    /// - Parameters:
    ///   - frequency: How often the event repeats (daily, weekly, monthly, yearly)
    ///   - interval: Interval of the frequency (e.g., 2 for every 2 weeks), defaults to 1
    ///   - calendarIdentifier: Calendar identifier for this rule
    ///   - firstDayOfTheWeek: First day of the week (1-7, where 1 is Sunday, 0 means not set)
    ///   - daysOfTheWeek: Days of the week the event recurs
    ///   - daysOfTheMonth: Days of the month the event recurs (1-31 or -31 to -1)
    ///   - daysOfTheYear: Days of the year the event recurs (1-366 or -366 to -1)
    ///   - weeksOfTheYear: Weeks of the year the event recurs (1-53 or -53 to -1)
    ///   - monthsOfTheYear: Months of the year the event recurs (1-12)
    ///   - setPositions: Set positions for filtering results (-366 to 366, except 0)
    ///   - recurrenceEnd: When the recurrence ends
    public init(
        frequency: EKRecurrenceFrequency,
        interval: Int = 1,
        calendarIdentifier: String,
        firstDayOfTheWeek: Int? = nil,
        daysOfTheWeek: [EKWeekday]? = nil,
        daysOfTheMonth: [Int]? = nil,
        daysOfTheYear: [Int]? = nil,
        weeksOfTheYear: [Int]? = nil,
        monthsOfTheYear: [Int]? = nil,
        setPositions: [Int]? = nil,
        recurrenceEnd: RecurrenceEnd? = nil
    ) {
        self.frequency = frequency
        self.interval = interval
        self.calendarIdentifier = calendarIdentifier
        self.firstDayOfTheWeek = firstDayOfTheWeek
        self.daysOfTheWeek = daysOfTheWeek
        self.daysOfTheMonth = daysOfTheMonth
        self.daysOfTheYear = daysOfTheYear
        self.weeksOfTheYear = weeksOfTheYear
        self.monthsOfTheYear = monthsOfTheYear
        self.setPositions = setPositions
        self.recurrenceEnd = recurrenceEnd
    }

    /// Converts this RecurrenceRule to an EKRecurrenceRule
    /// - Returns: An EKRecurrenceRule configured with this rule's settings
    public func toEKRecurrenceRule() -> EKRecurrenceRule {
        let weekNumber = frequency == .weekly ? 0 : -1  // Use 0 for weekly recurrence, -1 for others
        return EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: interval,
            daysOfTheWeek: daysOfTheWeek?.map { EKRecurrenceDayOfWeek(dayOfTheWeek: $0, weekNumber: weekNumber) },
            daysOfTheMonth: daysOfTheMonth?.map { NSNumber(value: $0) },
            monthsOfTheYear: monthsOfTheYear?.map { NSNumber(value: $0) },
            weeksOfTheYear: weeksOfTheYear?.map { NSNumber(value: $0) },
            daysOfTheYear: daysOfTheYear?.map { NSNumber(value: $0) },
            setPositions: setPositions?.map { NSNumber(value: $0) },
            end: recurrenceEnd?.toEKRecurrenceEnd()
        )
    }
}

extension RecurrenceRule {
    private enum CodingKeys: String, CodingKey {
        case calendarIdentifier
        case frequency
        case interval
        case firstDayOfTheWeek
        case daysOfTheWeek
        case daysOfTheMonth
        case daysOfTheYear
        case weeksOfTheYear
        case monthsOfTheYear
        case setPositions
        case recurrenceEnd
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.calendarIdentifier = try container.decode(String.self, forKey: .calendarIdentifier)

        let frequencyString = try container.decode(String.self, forKey: .frequency)
        guard let frequency = EKRecurrenceFrequency(frequencyString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .frequency,
                in: container,
                debugDescription: "Invalid frequency: \(frequencyString)"
            )
        }
        self.frequency = frequency

        self.interval = try container.decodeIfPresent(Int.self, forKey: .interval) ?? 1
        self.firstDayOfTheWeek = try container.decodeIfPresent(Int.self, forKey: .firstDayOfTheWeek)

        // Decode arrays of weekdays and integers
        if let weekdayStrings = try container.decodeIfPresent([String].self, forKey: .daysOfTheWeek) {
            self.daysOfTheWeek = weekdayStrings.compactMap { EKWeekday($0) }
        } else {
            self.daysOfTheWeek = nil
        }

        self.daysOfTheMonth = try container.decodeIfPresent([Int].self, forKey: .daysOfTheMonth)
        self.daysOfTheYear = try container.decodeIfPresent([Int].self, forKey: .daysOfTheYear)
        self.weeksOfTheYear = try container.decodeIfPresent([Int].self, forKey: .weeksOfTheYear)
        self.monthsOfTheYear = try container.decodeIfPresent([Int].self, forKey: .monthsOfTheYear)
        self.setPositions = try container.decodeIfPresent([Int].self, forKey: .setPositions)
        self.recurrenceEnd = try container.decodeIfPresent(RecurrenceEnd.self, forKey: .recurrenceEnd)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(calendarIdentifier, forKey: .calendarIdentifier)
        try container.encode(frequency.description, forKey: .frequency)
        try container.encode(interval, forKey: .interval)

        if let firstDayOfTheWeek = firstDayOfTheWeek {
            try container.encode(firstDayOfTheWeek, forKey: .firstDayOfTheWeek)
        }

        if let daysOfTheWeek = daysOfTheWeek {
            try container.encode(daysOfTheWeek.map(\.description), forKey: .daysOfTheWeek)
        }

        if let daysOfTheMonth = daysOfTheMonth {
            try container.encode(daysOfTheMonth, forKey: .daysOfTheMonth)
        }

        if let daysOfTheYear = daysOfTheYear {
            try container.encode(daysOfTheYear, forKey: .daysOfTheYear)
        }

        if let weeksOfTheYear = weeksOfTheYear {
            try container.encode(weeksOfTheYear, forKey: .weeksOfTheYear)
        }

        if let monthsOfTheYear = monthsOfTheYear {
            try container.encode(monthsOfTheYear, forKey: .monthsOfTheYear)
        }

        if let setPositions = setPositions {
            try container.encode(setPositions, forKey: .setPositions)
        }

        if let recurrenceEnd = recurrenceEnd {
            try container.encode(recurrenceEnd, forKey: .recurrenceEnd)
        }
    }
}
