import Foundation
import SwiftMCP

public protocol RealtimeAgent: Agent where OutputType == String {
    var sessionConfiguration: RealtimeSessionConfiguration { get }
}

public extension RealtimeAgent {
    var sessionConfiguration: RealtimeSessionConfiguration {
        RealtimeSessionConfiguration(
            instructions: instructions,
            maxOutputTokens: modelSettings.maxCompletionTokens.map { .finite($0) },
            outputModalities: [.text],
            toolChoice: modelSettings.toolChoice
        )
    }
}

extension Tool {
    var isRealtimeCompatible: Bool {
        switch self {
            case .function, .mcp:
                return true
            case .fileSearch, .webSearch, .computer, .applyPatch:
                return false
        }
    }

    var functionName: String? {
        if case let .function(function) = self {
            return function.name
        }

        return nil
    }
}
