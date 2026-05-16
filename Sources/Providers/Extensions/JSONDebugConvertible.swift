//
//  JSONDebugConvertible.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 28.05.25.
//

import Foundation

/// Helper to encode any Encodable
private struct AnyEncodable: Encodable {
    let value: Encodable
    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}

private struct PrettyJSONProxy: Encodable {
    let value: Any

    func encode(to encoder: Encoder) throws {
        // Handle Optional
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            if let child = mirror.children.first {
                // Optional.some: encode the wrapped value
                try PrettyJSONProxy(value: child.value).encode(to: encoder)
            } else {
                // Optional.none: encode as null (but we will omit these in parent containers)
                // Do not encode anything here; parent will omit nils
                var container = encoder.singleValueContainer()
                try container.encodeNil()
            }
            return
        }
        var container = encoder.singleValueContainer()
        switch value {
            case let v as Int:
                try container.encode(v)
            case let v as Double:
                let rounded = Double(String(format: "%.6f", v)) ?? v
                try container.encode(rounded)
            case let v as Decimal:
                let ns = NSDecimalNumber(decimal: v)
                let doubleValue = ns.doubleValue
                if doubleValue.isFinite {
                    let rounded = Double(String(format: "%.6f", doubleValue)) ?? doubleValue
                    try container.encode(rounded)
                } else {
                    try container.encode(ns.stringValue)
                }
            case let v as String:
                try container.encode(v)
            case let v as Bool:
                try container.encode(v)
            case let v as Date:
                let str = ISO8601DateFormatter().string(from: v)
                try container.encode(str)
            case let v as URL:
                try container.encode(v.absoluteString)
            case let v as [Any]:
                let filtered = v.compactMap { elem -> PrettyJSONProxy? in
                    // Omit nils in arrays
                    let mirror = Mirror(reflecting: elem)
                    if mirror.displayStyle == .optional, mirror.children.first == nil {
                        return nil
                    }
                    return PrettyJSONProxy(value: elem)
                }
                // Only encode if the array is not empty
                if !filtered.isEmpty {
                    try container.encode(filtered)
                } else {
                    // Encode empty array as null to be omitted by parent
                    try container.encodeNil()
                }
            case let v as [String: Any]:
                let mapped = v.compactMapValues { elem -> PrettyJSONProxy? in
                    let mirror = Mirror(reflecting: elem)
                    if mirror.displayStyle == .optional, mirror.children.first == nil {
                        return nil
                    }
                    return PrettyJSONProxy(value: elem)
                }
                try container.encode(mapped)
            default:
                // Try to encode as Encodable, fallback to string
                if let encodable = value as? Encodable {
                    // For custom Encodable types, first try to get the encoded property names and types
                    // by creating a temporary encoding, then use reflection with proper mapping
                    let mirror = Mirror(reflecting: encodable)
                    if mirror.displayStyle == .struct || mirror.displayStyle == .class {
                        var dict: [String: Any] = [:]

                        // Use reflection to get the actual property values (preserving types)
                        for child in mirror.children {
                            if let label = child.label {
                                let childMirror = Mirror(reflecting: child.value)
                                if childMirror.displayStyle == .optional, childMirror.children.first == nil {
                                    continue // omit nil
                                }
                                // Check if it's an empty array and omit it
                                if let array = child.value as? [Any], array.isEmpty {
                                    continue // omit empty array
                                }
                                dict[label] = child.value
                            }
                        }

                        let mapped = dict.compactMapValues { elem -> PrettyJSONProxy? in
                            let mirror = Mirror(reflecting: elem)
                            if mirror.displayStyle == .optional, mirror.children.first == nil {
                                return nil
                            }
                            // Check if it's an empty array and omit it
                            if let array = elem as? [Any], array.isEmpty {
                                return nil
                            }
                            return PrettyJSONProxy(value: elem)
                        }
                        try container.encode(mapped)
                        return
                    }
                }
                try container.encode(String(describing: value))
        }
    }
}

public extension Encodable {
    var prettyJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let proxy = PrettyJSONProxy(value: self)
            let data = try encoder.encode(proxy)
            return String(data: data, encoding: .utf8) ?? "<invalid utf8>"
        } catch {
            return "<encoding error: \(error)>"
        }
    }
}
