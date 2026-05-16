//
//  Tool 2.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 08.04.26.
//

extension Tool: Equatable {

    public static func == (lhs: Tool, rhs: Tool) -> Bool {
        switch (lhs, rhs) {
        case (.function(let lhsFn), .function(let rhsFn)): lhsFn.name == rhsFn.name
        case (.fileSearch(let lhsFs), .fileSearch(let rhsFs)): lhsFs.vectorStoreIds == rhsFs.vectorStoreIds
        case (.webSearch(let lhsWs), .webSearch(let rhsWs)): lhsWs.type == rhsWs.type
        case (.computer, .computer): true
        case (.mcp(let lhsMcp), .mcp(let rhsMcp)): lhsMcp == rhsMcp
        case (.applyPatch, .applyPatch): true
        default: false
        }
    }
}
