//
//  Property.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 15.06.23.
//

import Foundation

/// A Codable structure representing a property.
/// Each instance of `Property` contains information regarding the type, description, items and enumeration values of
/// the property.
public struct Property: Codable, Sendable {
    /// A Codable structure that encapsulates the `type` of items of a `Property`.
    public struct Items: Codable, Sendable {
        /// The type of the item in a `Property`. It is a `String` value.
        public var type: String
    }

    /// A `String` value representing the type of the `Property`.
    public var type: String?

    /// An optional `String` value that describes the `Property`.
    public var description: String?

    /// An instance of `Items` that provides information about the items of the `Property`.
    public var items: Items?

    /// An optional array of `String` that represents the enum values of the `Property`.
    public var `enum`: [String]?

    /// Initializer for `Property` struct.
    ///
    /// - Parameters:
    ///   - type: A `String` that specifies the type of the `Property`.
    ///   - description: An optional `String` that gives a description of the `Property`.
    ///   - items: An instance of `Items` that contains information about the items of the `Property`.
    ///   - enum: An optional array of `String` that holds the enum values for the `Property`.
    public init(type: String, description: String? = nil, items: Items? = nil, enum: [String]? = nil) {
        self.type = type
        self.description = description
        self.items = items
        self.enum = `enum`
    }
}
