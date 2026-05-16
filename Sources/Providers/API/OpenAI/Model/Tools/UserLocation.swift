import Foundation

public struct UserLocation: Codable, Sendable {
    /// The type of location approximation.
    public let type: String
    /// Free text input for the city of the user.
    public let city: String?
    /// The two-letter ISO country code of the user.
    public let country: String?
    /// Free text input for the region of the user.
    public let region: String?
    /// The IANA timezone of the user.
    public let timezone: String?
    public init(type: String, city: String?, country: String?, region: String?, timezone: String?) {
        self.type = type
        self.city = city
        self.country = country
        self.region = region
        self.timezone = timezone
    }
}
