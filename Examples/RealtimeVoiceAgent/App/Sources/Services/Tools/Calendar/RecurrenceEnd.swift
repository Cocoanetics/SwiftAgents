//
//  RecurrenceEnd.swift
//  API.me
//
//  Created by Oliver Drobnik on 29.03.25.
//

import EventKit
import Foundation
import SwiftMCP

/// A structure representing when a recurring event ends, either by date or occurrence count
@Schema
public struct RecurrenceEnd: Codable {
    /// The end date of this recurrence, or nil if it's count-based
    public let endDate: Date?

    /// The maximum occurrence count, or 0 if it's date-based
    public let occurrenceCount: Int

    /// Creates a recurrence end with a specific end date
    /// - Parameter endDate: The date when the recurrence should end
    public init(end endDate: Date) {
        self.endDate = endDate
        self.occurrenceCount = 0
    }

    /// Creates a recurrence end with a maximum occurrence count
    /// - Parameter occurrenceCount: The number of times the event should occur
    public init(occurrenceCount: Int) {
        self.endDate = nil
        self.occurrenceCount = occurrenceCount
    }

    /// Converts this RecurrenceEnd to an EKRecurrenceEnd
    /// - Returns: An EKRecurrenceEnd configured with this rule's settings
    public func toEKRecurrenceEnd() -> EKRecurrenceEnd {
        if let endDate = endDate {
            return EKRecurrenceEnd(end: endDate)
        } else {
            return EKRecurrenceEnd(occurrenceCount: occurrenceCount)
        }
    }
}

extension RecurrenceEnd {
    private enum CodingKeys: String, CodingKey {
        case endDate
        case occurrenceCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let endDate = try container.decodeIfPresent(Date.self, forKey: .endDate) {
            self.endDate = endDate
            self.occurrenceCount = 0
        } else {
            self.endDate = nil
            self.occurrenceCount = try container.decode(Int.self, forKey: .occurrenceCount)
        }

        // Validate that we have either an end date or occurrence count, but not both
        if endDate != nil && occurrenceCount != 0 {
            throw DecodingError.dataCorruptedError(
                forKey: .endDate,
                in: container,
                debugDescription: "Cannot specify both endDate and occurrenceCount"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        if let endDate = endDate {
            try container.encode(endDate, forKey: .endDate)
        } else {
            try container.encode(occurrenceCount, forKey: .occurrenceCount)
        }
    }
}
