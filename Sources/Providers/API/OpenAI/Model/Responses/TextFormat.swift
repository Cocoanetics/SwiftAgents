//
//  TextFormat.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 24.04.25.
//

import Foundation
import SwiftMCP

/// Format options for text responses.
public enum TextFormat: Codable, Sendable {
    /// Default text response format
    case text

    /// JSON response format
    case json

    /// JSON Schema response format
    case jsonSchema(JSONSchemaFormat)

    private enum CodingKeys: String, CodingKey {
        case type
        case name
        case schema
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
            case .text:
                try container.encode("text", forKey: .type)
            case .json:
                try container.encode("json_object", forKey: .type)
            case let .jsonSchema(format):
                try container.encode("json_schema", forKey: .type)
                try container.encode(format.name, forKey: .name)
                try container.encode(format.schema, forKey: .schema)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
            case "text":
                self = .text
            case "json_object":
                self = .json
            case "json_schema":
                let name = try container.decode(String.self, forKey: .name)
                let schema = try container.decode(JSONSchema.self, forKey: .schema)
                self = .jsonSchema(JSONSchemaFormat(name: name, schema: schema))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Invalid response format type"
                )
        }
    }
}

/// JSON Schema format configuration
public struct JSONSchemaFormat: Codable, Sendable {
    /// The name of the response format
    public let name: String

    /// The schema for the response format
    public let schema: JSONSchema

    public init(name: String, schema: JSONSchema) {
        self.name = name
        self.schema = schema
    }
}
