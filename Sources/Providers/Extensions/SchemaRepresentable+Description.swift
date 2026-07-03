//
//  SchemaRepresentable+Description.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 19.04.25.
//

import Foundation
import JSONFoundation

/**
 Extension to SchemaRepresentable that provides schema description functionality.

 This extension adds the ability to generate a named JSON schema for any type that conforms to SchemaRepresentable.
 */
public extension SchemaRepresentable {
    /**
     Returns the named JSON schema for the conforming type, for use in
     structured-output response formats.

     Built from the type's schema metadata, with `additionalProperties: false`
     applied to every object recursively — the strict shape OpenAI-style
     structured outputs require (and Anthropic mandates).
     */
    static var jsonSchema: JSONSchemaFormat {
        JSONSchemaFormat(
            name: schemaMetadata.name,
            schema: schemaMetadata.schema.addingAdditionalPropertiesRestrictionToObjects
        )
    }
}
