//
//  NamedSchema.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 11.01.25.
//

import Foundation
import SwiftMCP

/**
 A structure that represents a JSON schema description with additional metadata.

 SchemaDescription combines a JSON schema with a name, optional description, and strictness flag
 to provide a complete schema definition that can be used for validation and documentation.
 */
public struct SchemaDescription: Codable, Sendable {
    /**
     The name of the schema
     */
    public let name: String

    /**
     An optional description of the schema's purpose and usage
     */
    public let description: String?

    /**
     The JSON schema definition that describes the structure and validation rules
     */
    public let schema: JSONSchema

    /**
     A flag indicating whether the schema should be enforced strictly
     */
    public let strict: Bool

    /**
     Creates a new schema description.

     - Parameters:
        - name: The name of the schema
        - description: An optional description of the schema
        - schema: The JSON schema definition
        - strict: Whether to enforce the schema strictly (defaults to true)
     */
    public init(name: String, description: String? = nil, schema: JSONSchema, strict: Bool = true) {
        self.name = name
        self.description = description
        self.schema = schema.addingAdditionalPropertiesRestrictionToObjects
        self.strict = strict
    }
}
