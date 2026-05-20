//
//  EKWeekday+Retroative.swift
//  API.me
//
//  Created by Oliver Drobnik on 29.03.25.
//

import EventKit

extension EKWeekday: @retroactive LosslessStringConvertible {
    public init?(_ description: String) {
        switch description.lowercased() {
            case "sunday": self = .sunday
            case "monday": self = .monday
            case "tuesday": self = .tuesday
            case "wednesday": self = .wednesday
            case "thursday": self = .thursday
            case "friday": self = .friday
            case "saturday": self = .saturday
            default: return nil
        }
    }
}

extension EKWeekday: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
            case .sunday: return "sunday"
            case .monday: return "monday"
            case .tuesday: return "tuesday"
            case .wednesday: return "wednesday"
            case .thursday: return "thursday"
            case .friday: return "friday"
            case .saturday: return "saturday"
            @unknown default: return "unknown"
        }
    }
}

extension EKWeekday: @retroactive CaseIterable {
    public static var allCases: [EKWeekday] {
        return [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
    }
}
