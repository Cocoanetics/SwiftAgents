import Foundation
import SwiftMCP

/// Shared types for Google Generate Content API (used by both request and response)
public enum GoogleGenerateContent {
    public struct Content: Codable, Sendable {
        public let role: String?
        public let parts: [Part]

        public init(role: String? = nil, parts: [Part]) {
            self.role = role
            self.parts = parts
        }
    }

    public struct Part: Codable, Sendable {
        public let text: String?
        public let inlineData: InlineData?
        public let fileData: FileData?
        public let functionCall: FunctionCall?
        public let functionResponse: FunctionResponse?
        public let thought: Bool?
        public let thoughtSignature: String?

        public init(
            text: String? = nil,
            inlineData: InlineData? = nil,
            fileData: FileData? = nil,
            functionCall: FunctionCall? = nil,
            functionResponse: FunctionResponse? = nil,
            thought: Bool? = nil,
            thoughtSignature: String? = nil
        ) {
            self.text = text
            self.inlineData = inlineData
            self.fileData = fileData
            self.functionCall = functionCall
            self.functionResponse = functionResponse
            self.thought = thought
            self.thoughtSignature = thoughtSignature
        }

        public struct InlineData: Codable, Sendable {
            public let mimeType: String
            /// Raw decoded bytes. JSONDecoder's default `.base64` data
            /// strategy converts the on-wire base64 string to `Data`
            /// automatically, and `JSONEncoder` reverses it on the way out.
            public let data: Data

            public init(mimeType: String, data: Data) {
                self.mimeType = mimeType
                self.data = data
            }
        }

        public struct FileData: Codable, Sendable {
            public let fileUri: String?
            public let mimeType: String?

            public init(fileUri: String? = nil, mimeType: String? = nil) {
                self.fileUri = fileUri
                self.mimeType = mimeType
            }
        }

        public struct FunctionCall: Codable, @unchecked Sendable {
            public let name: String
            public let args: [String: JSONValue]?

            public init(name: String, args: [String: JSONValue]? = nil) {
                self.name = name
                self.args = args
            }
        }

        public struct FunctionResponse: Codable, @unchecked Sendable {
            public let name: String
            public let response: [String: JSONValue]?

            public init(name: String, response: [String: JSONValue]? = nil) {
                self.name = name
                self.response = response
            }
        }

        public static func text(_ value: String) -> Part {
            Part(
                text: value,
                inlineData: nil,
                fileData: nil,
                functionCall: nil,
                functionResponse: nil,
                thought: nil,
                thoughtSignature: nil
            )
        }

        public static func inlineData(mimeType: String, data: Data) -> Part {
            Part(
                text: nil,
                inlineData: InlineData(mimeType: mimeType, data: data),
                fileData: nil,
                functionCall: nil,
                functionResponse: nil,
                thought: nil,
                thoughtSignature: nil
            )
        }

        public static func file(uri: String, mimeType: String?) -> Part {
            Part(
                text: nil,
                inlineData: nil,
                fileData: FileData(fileUri: uri, mimeType: mimeType),
                functionCall: nil,
                functionResponse: nil,
                thought: nil,
                thoughtSignature: nil
            )
        }
    }
}
