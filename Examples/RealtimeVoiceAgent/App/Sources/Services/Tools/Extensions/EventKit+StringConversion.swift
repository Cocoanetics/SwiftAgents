import EventKit

extension EKRecurrenceFrequency: @retroactive CustomStringConvertible {}
extension EKRecurrenceFrequency: @retroactive LosslessStringConvertible {
    public init?(_ description: String) {
        switch description.lowercased() {
        case "daily": self = .daily
        case "weekly": self = .weekly
        case "monthly": self = .monthly
        case "yearly": self = .yearly
        default: return nil
        }
    }

    public var description: String {
        switch self {
        case .daily: return "daily"
        case .weekly: return "weekly"
        case .monthly: return "monthly"
        case .yearly: return "yearly"
        @unknown default: return "daily"
        }
    }
}
