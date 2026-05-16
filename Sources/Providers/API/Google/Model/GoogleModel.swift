import Foundation

/// Represents a Google AI model.
public struct GoogleModel: Codable {
    /// The resource name of the Model (e.g., "models/gemini-1.5-flash-001")
    public let name: String
    
    /// The name of the base model (e.g., "gemini-1.5-flash")
    public let baseModelId: String?
    
    /// The version number of the model
    public let version: String
    
    /// The human-readable name of the model
    public let displayName: String
    
    /// A short description of the model, if provided
    public let description: String?
    
    /// Maximum number of input tokens allowed
    public let inputTokenLimit: Int
    
    /// Maximum number of output tokens available
    public let outputTokenLimit: Int
    
    /// The model's supported generation methods
    public let supportedGenerationMethods: [String]
    
    /// Controls the randomness of the output (0.0 to maxTemperature)
    public let temperature: Double?
    
    /// The maximum temperature this model can use
    public let maxTemperature: Double?
    
    /// For Nucleus sampling
    public let topP: Double?
    
    /// For Top-k sampling
    public let topK: Int?
}
