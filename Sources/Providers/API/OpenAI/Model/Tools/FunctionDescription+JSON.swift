//
//  FunctionDescription+JSON.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 20.05.25.
//

import Foundation

public extension [FunctionDescription] {
    /// creates a JSON representation for use when injecting it into the system prompt
    func asJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(self),
            let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }
}
