//
//  IncompleteDetails.swift
//
//
//  Created by Oliver Drobnik on 03.05.24.
//

import Foundation

/// Represents the details about why a message or run is incomplete.
public struct IncompleteDetails: Codable, Sendable {
    var reason: String
}
