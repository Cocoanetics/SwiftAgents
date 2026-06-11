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

/// An LLM-backed expander. Prompts a generation model for typed `lex`/`vec`/`hyde`
/// lines (qmd's approach), parses them, and keeps only expansions that share a
/// term with the original query (grounding — guards against the model wandering
/// off topic). Falls back to `TemplateQueryExpander` when the model returns
/// nothing usable or errors.
///
/// Provider-agnostic: supply a `generate` closure. A consumer wires it to a
/// SwiftAgents chat client (OpenAI / Ollama / …), optionally with structured
/// output to constrain the format; the engine stays free of any specific client.
public struct LLMQueryExpander: QueryExpander {
    public typealias Generate = @Sendable (_ prompt: String) async throws -> String

    private let generate: Generate
    private let includeLexical: Bool

    public init(includeLexical: Bool = true, generate: @escaping Generate) {
        self.includeLexical = includeLexical
        self.generate = generate
    }

    public func expand(_ query: String, intent: String?) async throws -> [ExpandedQuery] {
        let raw = (try? await generate(Self.prompt(query: query, intent: intent))) ?? ""
        let parsed = Self.parse(raw, query: query, includeLexical: includeLexical)
        if !parsed.isEmpty { return parsed }

        let fallback = (try? await TemplateQueryExpander().expand(query, intent: intent)) ?? []
        return includeLexical ? fallback : fallback.filter { $0.kind != .lex }
    }

    static func prompt(query: String, intent: String?) -> String {
        var lines = [
            "Expand this search query into retrieval sub-queries — one per line, each",
            "prefixed with its type, and nothing else:",
            "  lex: a keyword/phrase variant for full-text search",
            "  vec: a semantic rephrasing for embedding search",
            "  hyde: a one-sentence hypothetical passage that would answer the query",
            "Query: \(query)"
        ]
        if let intent, !intent.isEmpty { lines.append("Intent: \(intent)") }
        return lines.joined(separator: "\n")
    }

    static func parse(_ raw: String, query: String, includeLexical: Bool) -> [ExpandedQuery] {
        let terms = queryTerms(query)
        func grounded(_ text: String) -> Bool {
            terms.isEmpty || terms.contains { text.lowercased().contains($0) }
        }

        var result: [ExpandedQuery] = []
        for rawLine in raw.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let kind = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let text = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, grounded(text) else { continue }
            switch kind {
                case "lex" where includeLexical: result.append(ExpandedQuery(kind: .lex, text: text))
                case "vec": result.append(ExpandedQuery(kind: .vec, text: text))
                case "hyde": result.append(ExpandedQuery(kind: .hyde, text: text))
                default: continue
            }
        }
        return result
    }

    static func queryTerms(_ query: String) -> [String] {
        query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !$0.isEmpty }
    }
}
