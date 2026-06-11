//
//  VectorStoreSearch.swift
//
//  Wire types for the vector store search endpoint and the per-file
//  `attributes` metadata it filters on: a scored result chunk, the result
//  page, the attribute value union (string | number | bool), and the
//  attribute filter tree.
//
//  - SeeAlso: [Search Vector Store](https://platform.openai.com/docs/api-reference/vector-stores/search)
//

import Foundation

/// One value in a vector store file's `attributes` dictionary — OpenAI allows
/// strings, numbers, and booleans.
///
/// - Note: The shared OpenAI coder converts *all* JSON keys between
///   snake_case and camelCase, including dictionary keys — attribute keys
///   containing underscores or capitals round-trip mangled. Stick to plain
///   lowercase keys (`path`, `source`, `hash`).
public enum VectorStoreAttribute: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)

    /// The string payload, when the attribute is a string.
    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// The numeric payload, when the attribute is a number.
    public var doubleValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    /// The boolean payload, when the attribute is a bool.
    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
            case let .string(value): try container.encode(value)
            case let .number(value): try container.encode(value)
            case let .bool(value): try container.encode(value)
        }
    }
}

extension VectorStoreAttribute: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

/// An attribute filter for vector store search — a comparison leaf
/// (`.eq("source", "wiki")`) or an `and`/`or` combination of sub-filters.
public indirect enum VectorStoreFilter: Codable, Sendable, Equatable {
    case comparison(key: String, operation: Comparison, value: VectorStoreAttribute)
    case and([VectorStoreFilter])
    case or([VectorStoreFilter])

    /// The comparison operators the search endpoint supports.
    public enum Comparison: String, Codable, Sendable {
        case eq, ne, gt, gte, lt, lte
    }

    public static func eq(_ key: String, _ value: VectorStoreAttribute) -> VectorStoreFilter {
        .comparison(key: key, operation: .eq, value: value)
    }

    public static func ne(_ key: String, _ value: VectorStoreAttribute) -> VectorStoreFilter {
        .comparison(key: key, operation: .ne, value: value)
    }

    private enum CodingKeys: String, CodingKey {
        case type, key, value, filters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
            case "and":
                self = .and(try container.decode([VectorStoreFilter].self, forKey: .filters))
            case "or":
                self = .or(try container.decode([VectorStoreFilter].self, forKey: .filters))
            default:
                guard let operation = Comparison(rawValue: type) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .type, in: container,
                        debugDescription: "unknown filter type '\(type)'"
                    )
                }
                self = .comparison(
                    key: try container.decode(String.self, forKey: .key),
                    operation: operation,
                    value: try container.decode(VectorStoreAttribute.self, forKey: .value)
                )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
            case let .comparison(key, operation, value):
                try container.encode(operation.rawValue, forKey: .type)
                try container.encode(key, forKey: .key)
                try container.encode(value, forKey: .value)
            case let .and(filters):
                try container.encode("and", forKey: .type)
                try container.encode(filters, forKey: .filters)
            case let .or(filters):
                try container.encode("or", forKey: .type)
                try container.encode(filters, forKey: .filters)
        }
    }
}

/// One scored chunk returned by vector store search.
public struct VectorStoreSearchResult: Codable, Sendable {
    /// The ID of the uploaded `File` the chunk came from.
    public let fileId: String

    /// The filename the chunk came from.
    public let filename: String

    /// Relevance score, higher is better.
    public let score: Double

    /// The attributes attached to the file when it was added to the store.
    public let attributes: [String: VectorStoreAttribute]?

    /// The chunk's content parts (currently text parts).
    public let content: [Content]

    /// One content part of a search result chunk.
    public struct Content: Codable, Sendable {
        public let type: String
        public let text: String?
    }

    /// All text parts joined with newlines.
    public var text: String {
        content.compactMap(\.text).joined(separator: "\n")
    }
}

/// The page of results returned by vector store search.
public struct VectorStoreSearchResultsPage: Codable, Sendable {
    /// The object type — "vector_store.search_results.page".
    public let object: String

    /// The query (or queries) the service actually executed. With
    /// `rewrite_query` enabled this is the rewritten form, so it shows what
    /// the rewriter did; empty when the service omits the field.
    public let searchQuery: [String]

    /// The scored result chunks, best first.
    public let data: [VectorStoreSearchResult]

    /// Whether more results are available.
    public let hasMore: Bool

    /// Pagination token for the next page, if any.
    public let nextPage: String?

    private enum CodingKeys: String, CodingKey {
        case object, searchQuery, data, hasMore, nextPage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        object = try container.decode(String.self, forKey: .object)
        data = try container.decode([VectorStoreSearchResult].self, forKey: .data)
        hasMore = try container.decode(Bool.self, forKey: .hasMore)
        nextPage = try container.decodeIfPresent(String.self, forKey: .nextPage)
        // Tolerate both wire forms: an array of strings (observed live) and a
        // single string (the documented example form).
        if let list = try? container.decodeIfPresent([String].self, forKey: .searchQuery) {
            searchQuery = list
        } else if let single = try? container.decodeIfPresent(String.self, forKey: .searchQuery) {
            searchQuery = [single]
        } else {
            searchQuery = []
        }
    }
}
