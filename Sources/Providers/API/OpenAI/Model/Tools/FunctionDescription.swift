//
//  FunctionDescription.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 14.06.23.
//

import Foundation
import JSONFoundation

/// A Codable structure that describes a function.
/// Each instance of `FunctionDescription` provides information about the name, description and parameters of the
/// function.
public struct FunctionDescription: Codable, Sendable {
    /// A `String` value representing the name of the function.
    public var name: String

    /// An optional `String` value that provides a description of the function.
    public var description: String?

    /// A JSON schema describing the parameters of the function.
    public var parameters: JSONSchema

    /// Initializer for `FunctionDescription` struct.
    ///
    /// - Parameters:
    ///   - name: A `String` that specifies the name of the function.
    ///   - description: An optional `String` that gives a description of the function.
    ///   - parameters: A `JSONSchema` describing the parameters of the function.
    ///                 Defaults to an empty object schema for no-argument functions.
    public init(
        name: String,
        description: String? = nil,
        parameters: JSONSchema = .object(.init(properties: [:], required: []))
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}
