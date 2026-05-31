//
//  Tool 2.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 08.04.26.
//

extension Tool: Equatable {
    public static func == (lhs: Tool, rhs: Tool) -> Bool {
        switch (lhs, rhs) {
            case let (.function(lhsFn), .function(rhsFn)): lhsFn.name == rhsFn.name
            case let (.fileSearch(lhsFs), .fileSearch(rhsFs)): lhsFs.vectorStoreIds == rhsFs.vectorStoreIds
            case let (.webSearch(lhsWs), .webSearch(rhsWs)): lhsWs.type == rhsWs.type
            case (.computer, .computer): true
            case let (.mcp(lhsMcp), .mcp(rhsMcp)): lhsMcp == rhsMcp
            case (.applyPatch, .applyPatch): true
            case let (.imageGeneration(lhsImg), .imageGeneration(rhsImg)): lhsImg == rhsImg
            default: false
        }
    }
}
