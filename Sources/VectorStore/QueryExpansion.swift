//
//  QueryExpansion.swift
//  SwiftAgents
//
//  Query expansion — rewrite a search query into typed sub-queries that retrieve
//  better than the literal text. `lex` widens keyword recall; `vec` rephrases for
//  the embedding space; `hyde` is a hypothetical *answer* passage whose vector
//  lands near real answer chunks (Hypothetical Document Embeddings). A search
//  fuses the original query with its expansions via Reciprocal Rank Fusion.
//
//  Modeled on qmd's lex/vec/hyde expansion (github.com/tobi/qmd, src/store.ts).
//

import Foundation

/// One typed expansion of a query. Routed by `kind`: `.lex` → keyword (FTS5),
/// `.vec` / `.hyde` → vector (vec0).
public struct ExpandedQuery: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case lex   // keyword / lexical variant
        case vec   // semantic rephrasing
        case hyde  // hypothetical answer passage
    }

    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// Produces typed expansions for a query. Implementations may call an LLM
/// (structured output) or be purely local; a consumer with no generation backend
/// can fall back to `TemplateQueryExpander`.
public protocol QueryExpander: Sendable {
    func expand(_ query: String, intent: String?) async throws -> [ExpandedQuery]
}

/// A dependency-free expander: qmd's template HyDE (`Information about <query>`)
/// plus the raw query as both a lexical and a vector probe. No LLM — a safe
/// default, and the fallback when no generation provider is configured.
public struct TemplateQueryExpander: QueryExpander {
    public init() {}

    public func expand(_ query: String, intent: String?) async throws -> [ExpandedQuery] {
        [
            ExpandedQuery(kind: .hyde, text: "Information about \(query)"),
            ExpandedQuery(kind: .lex, text: query),
            ExpandedQuery(kind: .vec, text: query)
        ]
    }
}
