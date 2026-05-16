//
//  ToolResources.swift
//
//
//  Created by Oliver Drobnik on 30.04.24.
//

import Foundation

public struct ToolResources: Codable {
    /// Nested structs for each tool type.
    public struct CodeInterpreter: Codable {
        public let fileIds: [String]
    }

    public struct FileSearch: Codable {
        public let vectorStoreIds: [String]
    }

    public struct VectorStoreFiles: Codable {
        public let fileIds: [String]
        public let metadata: [String: String]?
    }

    // Optional properties for each tool type.
    public var codeInterpreter: CodeInterpreter?
    public var fileSearch: FileSearch?
    public var vectorStores: [VectorStoreFiles]? // Assuming multiple vector stores can be attached.

    public init() {}

    /// Custom initializer from Decoder to handle optional decoding.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        codeInterpreter = try container.decodeIfPresent(CodeInterpreter.self, forKey: .codeInterpreter)
        fileSearch = try container.decodeIfPresent(FileSearch.self, forKey: .fileSearch)
        vectorStores = try container.decodeIfPresent([VectorStoreFiles].self, forKey: .vectorStores)
    }

    /// Encoding function to handle optional properties.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(codeInterpreter, forKey: .codeInterpreter)
        try container.encodeIfPresent(fileSearch, forKey: .fileSearch)
        try container.encodeIfPresent(vectorStores, forKey: .vectorStores)
    }

    /// Keys matching the JSON property names.
    private enum CodingKeys: String, CodingKey {
        case codeInterpreter = "code_interpreter"
        case fileSearch = "file_search"
        case vectorStores
    }
}
