import Foundation

public struct FunctionTool: Codable, Sendable {
    /// The name of the function to call.
    public let name: String
    /// A description of the function.
    public let description: String?
    /// A JSON schema object describing the parameters of the function.
    public let parameters: Parameters
    /// Whether to enforce strict parameter validation.
    public let strict: Bool

    public init(name: String, description: String?, parameters: Parameters, strict: Bool) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.strict = strict
    }
}
