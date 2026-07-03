//
//  String+FunctionCalls.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 12.04.24.
//

import Foundation
import JSONFoundation

/// Extend the String class to add functionality for extracting function calls.
extension String {
    /// Parses the calling String instance as a function-call arguments JSON string.
    ///
    /// Supports the standard JSON-object form as well as the `[{"name": …, "value": …}]`
    /// array form some models emit.
    ///
    /// - Returns: The arguments as a `[String: JSONValue]` dictionary; empty for
    /// non-object/non-array JSON.
    /// - Throws: Decoding errors when the string is not valid JSON.
    func functionArgumentsDictionary() throws -> [String: JSONValue] {
        guard !isEmpty, let data = data(using: .utf8) else {
            return [:]
        }

        let value = try JSONDecoder().decode(JSONValue.self, from: data)

        if let dictionary = value.dictionaryValue {
            return dictionary
        }

        if let array = value.arrayValue {
            var argumentsDict: [String: JSONValue] = [:]

            for item in array {
                if let name = item["name"]?.stringValue,
                    let value = item["value"] {
                    argumentsDict[name] = value
                }
            }

            return argumentsDict
        }

        return [:]
    }

    /// Extracts function calls from a JSON-formatted string embedded within the calling String instance.
    /// Before extraction, strips out any inline comments that follow the '//' pattern, which are not part of the
    /// official JSON specification.
    /// Utilizes a regular expression to identify and isolate valid JSON objects that represent function calls.
    /// Each JSON object is expected to contain a "function" key with a string value and an "arguments" key with a
    /// JSON-formatted string value.
    ///
    /// - Returns: An array of `FunctionCall` structs, each representing a function call with its name and
    /// JSON-formatted arguments string.
    /// - Throws: This method can throw errors related to regular expression failures or JSON parsing issues, which are
    /// caught internally and logged.
    func extractFunctionCalls() -> [FunctionCall]? {
        let functionCalls: [FunctionCall] = containedJsonStrings().compactMap { string in
            guard let jsonData = string.data(using: .utf8),
                let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []) else {
                return nil
            }

            var function: String?
            var arguments = [String: Any]()

            if let dict = jsonObject as? [String: Any] {
                for key in dict.keys {
                    let value = dict[key]

                    if let string = value as? String {
                        if ["tool", "function"].contains(key) {
                            // that's the function name
                            function = string
                            continue
                        }
                    } else if let dict = value as? [String: Any] {
                        // copy all the values
                        for (innerKey, innerValue) in dict {
                            if ["tool_input", "parameters", "arguments"].contains(innerKey) {
                                // handle nested dictionaries
                                if let nestedDict = innerValue as? [String: Any] {
                                    for (nestedKey, nestedValue) in nestedDict {
                                        arguments[nestedKey] = nestedValue
                                    }
                                }
                            } else {
                                arguments[innerKey] = innerValue
                            }
                        }
                        continue
                    } else if let array = value as? [[String: Any]] {
                        for dict in array {
                            if let name = dict["name"] as? String, let value = dict["value"] {
                                // treat as argument value
                                arguments[name] = value
                            } else {
                                // copy all the values
                                for (key, value) in dict {
                                    arguments[key] = value
                                }
                            }
                        }
                        continue
                    }

                    // treat as argument value
                    arguments[key] = value
                }
            }

            if let function {
                guard let argumentsData = try? JSONSerialization.data(withJSONObject: arguments, options: []),
                    let argumentsString = String(data: argumentsData, encoding: .utf8) else {
                    return nil
                }
                return FunctionCall(name: function, arguments: argumentsString)
            }

            return nil
        }

        guard !functionCalls.isEmpty else {
            return nil
        }

        return functionCalls
    }

    public func containedJsonStrings() -> [String] {
        var jsonObjects = [String]()
        var depth = 0
        var inString = false
        var escape = false
        var startIndex: String.Index?

        for (index, char) in enumerated() {
            switch char {
                case "\"":
                    if !escape {
                        inString.toggle() // Toggle the inString state if the quote is not escaped
                    }
                case "{":
                    if !inString {
                        if depth == 0 {
                            startIndex = self.index(self.startIndex, offsetBy: index)
                        }
                        depth += 1
                    }
                case "}":
                    if !inString {
                        depth -= 1
                        if depth == 0, let start = startIndex {
                            let endIndex = self.index(self.startIndex, offsetBy: index + 1)
                            let jsonString = String(self[start ..< endIndex])
                            jsonObjects.append(jsonString)
                            startIndex = nil
                        }
                    }
                default:
                    break
            }

            // Handle escaping within strings
            escape = (char == "\\" && !escape && inString)
        }

        return jsonObjects
    }
}
