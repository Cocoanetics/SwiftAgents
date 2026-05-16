//
//  Tool+AgentSpan.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 06.05.25.
//

import Foundation

extension Tool {
    /** Returns the name of the tool as it should appear in agent spans

     This property provides a consistent way to identify tools in tracing and monitoring.
     The name is used to track which tools are being used by agents during execution.

     Returns: A string representing the tool's name in the format expected by agent spans

     The name is determined based on the tool type:
     - For function tools: The function's name
     - For file search: "file_search"
     - For web search: The search type
     - For computer tools: "computer_use_preview"
     */
    var nameForAgentSpan: String {
        switch self {
            case let .function(function):
                return function.name
            case .fileSearch:
                return "file_search"
            case let .webSearch(search):
                return search.type
            case .computer:
                return "computer_use_preview"
            case .mcp:
                return "mcp"
            case .applyPatch:
                return "apply_patch"
        }
    }
}
