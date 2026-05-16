//
//  Permission.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 19.04.24.
//

import Foundation

/// Represents a permission associated with a model.
/// - note: All properties optional because of LM Studio's response with {} for no permissions
public struct Permission: Codable, Sendable {
	/// The unique identifier of the permission.
	public var id: String?

	/// The type of object, always "permission".
	public var object: String?

	/// The timestamp of when the permission was created.
	public var created: Date?

	/// A flag indicating whether the permission allows creating an engine with this model.
	public var allowCreateEngine: Bool?

	/// A flag indicating whether the permission allows sampling from this model.
	public var allowSampling: Bool?

	/// A flag indicating whether the permission allows retrieving log probabilities from this model.
	public var allowLogprobs: Bool?

	/// A flag indicating whether the permission allows searching indices with this model.
	public var allowSearchIndices: Bool?

	/// A flag indicating whether the permission allows viewing the model.
	public var allowView: Bool?

	/// A flag indicating whether the permission allows fine-tuning the model.
	public var allowFineTuning: Bool?

	/// The organization associated with the permission.
	public var organization: String?

	/// The group associated with the permission, if any.
	public var group: String?

	/// A flag indicating whether the permission is blocking.
	public var isBlocking: Bool?
}
