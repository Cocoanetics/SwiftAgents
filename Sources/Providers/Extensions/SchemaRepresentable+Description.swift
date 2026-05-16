//
//  SchemaRepresentable+Description.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 19.04.25.
//

import Foundation
import SwiftMCP

/**
 Extension to SchemaRepresentable that provides schema description functionality.
 
 This extension adds the ability to generate a schema description for any type that conforms to SchemaRepresentable.
 */
extension SchemaRepresentable {
	/**
	 Returns a schema description for the conforming type.
	 
	 This computed property generates a SchemaDescription using the type's schema metadata,
	 which includes the name and schema definition.
	 
	 - Returns: A SchemaDescription containing the type's name and schema definition.
	 */
	public static var schemaDescription: SchemaDescription {

		SchemaDescription(name: self.schemaMetadata.name, schema: self.schemaMetadata.schema)
	}

	public static var jsonSchema: JSONSchemaFormat {
		JSONSchemaFormat(name: schemaMetadata.name, schema: schemaDescription.schema.addingAdditionalPropertiesRestrictionToObjects)
	}
}
