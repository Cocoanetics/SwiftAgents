//
//  Tool 2.swift
//  AgentCorp
//
//  Created by Oliver Drobnik on 08.04.26.
//


extension Tool: Equatable {
    
    public static func == (lhs: Tool, rhs: Tool) -> Bool {
        switch (lhs, rhs) {
            case (.function(let a), .function(let b)): a.name == b.name
            case (.fileSearch(let a), .fileSearch(let b)): a.vectorStoreIds == b.vectorStoreIds
            case (.webSearch(let a), .webSearch(let b)): a.type == b.type
            case (.computer, .computer): true
            case (.mcp(let a), .mcp(let b)): a == b
            case (.applyPatch, .applyPatch): true
            default: false
        }
    }
}
