import Foundation

extension ToolChoice {
    /// Returns a dictionary representation of the tool choice for generation output.
    public var generationOutput: [String: Any?] {
        switch self {
        case .none:
            return [
                "content": nil,
                "role": "assistant",
                "refusal": nil,
                "tool_calls": nil,
                "function_call": nil,
                "audio": nil,
                "annotations": nil
            ]
        case .auto:
            return [
                "content": nil,
                "role": "assistant",
                "refusal": nil,
                "tool_calls": nil,
                "function_call": nil,
                "audio": nil,
                "annotations": nil
            ]
        case .required:
            return [
                "content": nil,
                "role": "assistant",
                "refusal": nil,
                "tool_calls": nil,
                "function_call": nil,
                "audio": nil,
                "annotations": nil
            ]
        case .tool(let toolDescription):
            if let type = toolDescription.type {
                switch type {
                case "file_search":
                    return [
                        "content": nil,
                        "role": "assistant",
                        "refusal": nil,
                        "tool_calls": [
                            [
                                "function": [
                                    "name": "file_search",
                                    "arguments": "{}"
                                ],
                                "id": UUID().uuidString,
                                "type": "function"
                            ]
                        ],
                        "function_call": nil,
                        "audio": nil,
                        "annotations": nil
                    ]
                case "web_search_preview":
                    return [
                        "content": nil,
                        "role": "assistant",
                        "refusal": nil,
                        "tool_calls": [
                            [
                                "function": [
                                    "name": "web_search_preview",
                                    "arguments": "{}"
                                ],
                                "id": UUID().uuidString,
                                "type": "function"
                            ]
                        ],
                        "function_call": nil,
                        "audio": nil,
                        "annotations": nil
                    ]
                case "computer_use_preview":
                    return [
                        "content": nil,
                        "role": "assistant",
                        "refusal": nil,
                        "tool_calls": [
                            [
                                "function": [
                                    "name": "computer_use_preview",
                                    "arguments": "{}"
                                ],
                                "id": UUID().uuidString,
                                "type": "function"
                            ]
                        ],
                        "function_call": nil,
                        "audio": nil,
                        "annotations": nil
                    ]
                default:
                    if let function = toolDescription.function,
                       let name = function.name {
                        return [
                            "content": nil,
                            "role": "assistant",
                            "refusal": nil,
                            "tool_calls": [
                                [
                                    "function": [
                                        "name": name,
                                        "arguments": "{}"
                                    ],
                                    "id": UUID().uuidString,
                                    "type": "function"
                                ]
                            ],
                            "function_call": nil,
                            "audio": nil,
                            "annotations": nil
                        ]
                    }
                    return [
                        "content": nil,
                        "role": "assistant",
                        "refusal": nil,
                        "tool_calls": nil,
                        "function_call": nil,
                        "audio": nil,
                        "annotations": nil
                    ]
                }
            }
            return [
                "content": nil,
                "role": "assistant",
                "refusal": nil,
                "tool_calls": nil,
                "function_call": nil,
                "audio": nil,
                "annotations": nil
            ]
        }
    }

    /// Creates a ToolChoice from a generation output dictionary.
    public static func from(generationOutput: [String: Any?]) -> ToolChoice? {
        if let toolCalls = generationOutput["tool_calls"] as? [[String: Any]] {
            guard let firstCall = toolCalls.first,
                  let function = firstCall["function"] as? [String: Any],
                  let name = function["name"] as? String else {
                return nil
            }

            switch name {
            case "file_search":
                return .tool(ToolChoiceDescription(type: "file_search"))
            case "web_search_preview":
                return .tool(ToolChoiceDescription(type: "web_search_preview"))
            case "computer_use_preview":
                return .tool(ToolChoiceDescription(type: "computer_use_preview"))
            default:
                return .tool(ToolChoiceDescription(
                    type: "function",
                    function: ToolChoiceDescription.Function(name: name)
                ))
            }
        }

        if generationOutput["content"] is String {
			return ToolChoice.none
        }

        return nil
    }
}
