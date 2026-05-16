//
//  Model.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 08.05.23.
//

import Foundation

/// Represents an OpenAI model.
public struct Model: Codable, Sendable {
	/// The unique identifier of the model.
	public let id: String

	/// The type of object, always "model".
	public let object: String?

	/// The timestamp of when the model was created.
	public let created: Date?

	/// The owner of the model.
	public let ownedBy: String?

	/// An array of permissions associated with the model.
	public let permission: [Permission]?

	/// The root model identifier.
	public let root: String?

	/// The parent model identifier, if any.
	public let parent: String?
}
