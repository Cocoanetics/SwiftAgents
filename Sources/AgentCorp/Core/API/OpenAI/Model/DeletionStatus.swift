//
//  DeletionStatus.swift
//
//
//  Created by Oliver Drobnik on 01.05.24.
//

import Foundation

/// Statis returned from deleting an object
public struct DeletionStatus: Codable, Sendable
{
	public let id: String
	public let object: String
	public let deleted: Bool
	
	public init(id: String, object: String = "file", deleted: Bool) 
	{
		self.id = id
		self.object = object
		self.deleted = deleted
	}
}
