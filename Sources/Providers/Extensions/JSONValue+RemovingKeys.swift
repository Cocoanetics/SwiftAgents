//
//  JSONValue+RemovingKeys.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 03.07.26.
//

import Foundation
import JSONFoundation

extension JSONValue {
    /// Returns a copy of the value with every occurrence of `keys` removed
    /// from all nested objects, recursively. Array elements are transformed
    /// in place; scalars pass through unchanged.
    ///
    /// Used to sanitise JSON schemas for providers that reject parts of the
    /// JSON-Schema vocabulary (Anthropic's `output_config` and Gemini's
    /// OpenAPI 3.0 subset each supply their own disallowed-key set).
    func removingKeys(_ keys: Set<String>) -> JSONValue {
        switch self {
            case let .object(dict):
                var sanitised: [String: JSONValue] = [:]
                for (key, child) in dict where !keys.contains(key) {
                    sanitised[key] = child.removingKeys(keys)
                }
                return .object(sanitised)
            case let .array(items):
                return .array(items.map { $0.removingKeys(keys) })
            default:
                return self
        }
    }
}
