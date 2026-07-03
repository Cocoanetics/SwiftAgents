import Foundation
import JSONFoundation

public struct FunctionTool: Codable, Sendable {
    /// The name of the function to call.
    public let name: String
    /// A description of the function.
    public let description: String?
    /// A JSON schema describing the parameters of the function.
    public let parameters: JSONSchema
    /// Whether to enforce strict parameter validation. Defaults to `false`.
    /// Only set `true` when `parameters` is strict-conformant per OpenAI's
    /// rules: every property listed in `required` and every object carrying
    /// `additionalProperties: false`. Non-conformant schemas are rejected by
    /// the API when the flag is on.
    public let strict: Bool

    public init(name: String, description: String?, parameters: JSONSchema, strict: Bool = false) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.strict = strict
    }
}
