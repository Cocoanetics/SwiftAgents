//
//  Thread.swift
//
//
//  Created by Oliver Drobnik on 02.05.24.
//

import Foundation

/**
 Represents a thread object from the API, containing messages within a conversational context.
 */
public struct Thread: Codable
{
	/// Unique identifier for the thread.
	public var id: String

	/// Type of object, consistently a "thread".
	public var object: String

	/// The timestamp when the thread was created.
	public var createdAt: Date

	/// Resources specific to tools used within the thread, such as code interpreters or file searches.
	public var toolResources: ToolResources?

	/// Metadata providing additional information about the thread in a key-value format.
	public var metadata: [String: String] = [:]
}


/// Represents the details necessary for creating or modifying a thread on the OpenAI platform.
struct ThreadOptionals: Codable
{
	/// An array of messages that are included when starting the thread.
	var messages: [MessageCreation]?
	
	/// Tool-specific resources that are made available to the assistant's tools in this thread.
	var toolResources: ToolResources?
	
	/// Metadata providing additional structured information about the thread.
	var metadata: [String: String]?
}
