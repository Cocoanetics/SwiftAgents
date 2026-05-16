//
//  Parameters.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 15.06.23.
//

import Foundation
import SwiftMCP

/// A Codable structure representing parameters.
/// Each instance of `Parameters` includes information about the properties of parameters and whether they are required or not.
/// 
public struct Parameters: Codable, Sendable {
	/// A `String` value that defines the type of the `Parameters`. It is set to "object" by default.
	var type = "object"

	/// A dictionary that maps `String` keys to `Property` values. Represents the properties of the `Parameters`.
	public var properties: [String: JSONSchema] = [:]

	/// An optional array of `String` that lists the names of required properties.
	public var required: [String]?

	/// A static instance of `Parameters` with no properties.
	public static let none = Parameters(properties: [:])

	/// Initializer for `Parameters` struct.
	///
	/// - Parameters:
	///   - properties: A dictionary that maps `String` keys to `Property` values.
	///                 Represents the properties of the `Parameters`.
	///   - required: An optional array of `String` that contains the names of required properties.
	public init(properties: [String: JSONSchema] = [:], required: [String]? = nil) {
		self.properties = properties
		self.required = required
	}
}
