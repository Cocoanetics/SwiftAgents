//
//  Assistant.swift
//
//
//  Created by Oliver Drobnik on 30.04.24.
//

import Foundation

/// Represents an assistant object from the API, detailing configuration for a conversational model.
public struct Assistant: Codable {
    /// Unique identifier for the assistant.
    public var id: String

    /// Type of object, consistently an "assistant".
    public var object: String

    /// The timestamp when the assistant was created.
    public var createdAt: Date

    /// Optional name of the assistant.
    public let name: String?

    /// Optional description of the assistant's purpose or capabilities.
    public let description: String?

    /// Identifier of the model used by the assistant.
    public let model: String

    /// Optional instructions that guide the assistant's behavior.
    public let instructions: String?

    /// A list of tools enabled on the assistant, such as code interpreters.
    public var tools: [ToolDescription] = []

    /// Depending on the tool type those are resources to be used by the tool
    public var toolResources: ToolResources = .init()

    /// Optional metadata providing additional information about the assistant in a key-value format.
    public var metadata: [String: String] = [:]

    /// Optional nucleus sampling probability, influencing randomness in responses. Defaults to 1.
    public var topP: Double = 1

    /// Optional temperature setting that affects the randomness of the model's responses. Defaults to 1.
    public var temperature: Double = 1

    /// Optional response format expected from the model, can include text or structured JSON.
    public var responseFormat: ResponseFormat = .auto
}

/// Represents a temporary Assistent object that has all properties optional for creation or modification
struct AssistantOptionals: Codable {
    /// Optional name of the assistant.
    let name: String?

    /// Optional description of the assistant's purpose or capabilities.
    let description: String?

    /// Identifier of the model used by the assistant.
    let model: String?

    /// Optional instructions that guide the assistant's behavior.
    let instructions: String?

    /// A list of tools enabled on the assistant, such as code interpreters.
    var tools: [ToolDescription]?

    /// Depending on the tool type those are resources to be used by the tool
    var toolResources: ToolResources?

    /// Optional metadata providing additional information about the assistant in a key-value format.
    var metadata: [String: String]?

    /// Optional nucleus sampling probability, influencing randomness in responses. Defaults to 1.
    var topP: Double?

    /// Optional temperature setting that affects the randomness of the model's responses. Defaults to 1.
    var temperature: Double?

    /// Optional response format expected from the model, can include text or structured JSON.
    var responseFormat: ResponseFormat?
}
