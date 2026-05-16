//
//  CoderToolError.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 04.04.26.
//

import Foundation

enum CoderToolError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
            case let .message(msg): return msg
        }
    }
}
