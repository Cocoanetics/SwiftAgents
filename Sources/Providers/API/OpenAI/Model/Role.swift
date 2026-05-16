//
//  File.swift
//  
//
//  Created by Oliver Drobnik on 23.04.24.
//

import Foundation

/// The role of the author of this message.
public enum Role: String, Codable, Sendable {
	case system
	case user
	case assistant
	case function
	case tool
	case developer
}
