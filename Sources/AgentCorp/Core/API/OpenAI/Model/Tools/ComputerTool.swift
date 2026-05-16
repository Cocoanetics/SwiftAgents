import Foundation

public struct ComputerTool: Codable, Sendable {
    /// The height of the computer display.
    public let displayHeight: Double
    /// The width of the computer display.
    public let displayWidth: Double
    /// The type of computer environment to control.
    public let environment: String
} 