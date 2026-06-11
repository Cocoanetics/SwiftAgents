# SemanticStore

Three embedding-backed stores for semantic search:

- **`LocalVectorStore`** — in-memory, brute-force cosine. Zero setup, good for
  a few hundred chunks that live only for the session.
- **`SQLiteVectorStore`** — **persistent**, SQLite-backed. Semantic (vec0
  cosine KNN), keyword (FTS5 bm25), and hybrid search over one file, with
  file-level provenance and incremental re-indexing. This is what you want for
  an on-disk knowledge base.
- **`OpenAIVectorStore`** — **hosted**, backed by OpenAI's vector stores (the
  ones the Responses/Assistants `file_search` tool reads). Chunking, embedding,
  and ranking run server-side; no local engine, no API-key-free mode.

The local stores reuse the `Providers.EmbeddingProvider` abstraction, so you
can embed with OpenAI, Ollama, or — on Apple platforms — on-device
`NLContextualEmbedding` (no API key, no model download beyond the OS asset).

`SQLiteVectorStore` and `OpenAIVectorStore` share one protocol, so retrieval
code can stay store-agnostic:

```swift
public protocol SemanticStore: AnyObject {
    @discardableResult func indexText(_ text: String, path: String, source: String) async throws -> Int
    @discardableResult func indexFile(at filePath: String, source: String, workspaceDir: String?) async throws -> IndexOutcome
    @discardableResult func sync(files: [String], source: String, workspaceDir: String?) async throws -> SyncSummary
    func search(text: String, topN: Int, sources: [String]?) async throws -> [MemoryMatch]
    func count() async throws -> Int
}
```

Engine extras stay on the concrete types: keyword / hybrid / fused / expanded
search and reranking are `SQLiteVectorStore` capabilities; the hosted store
ranks with OpenAI's own (semantic + reranker) pipeline.

## Enabling `SQLiteVectorStore`

It's behind an opt-in package trait so the default build stays free of the
SQLite engine. In your `Package.swift`:

```swift
.package(url: "https://github.com/Cocoanetics/SwiftAgents", from: "x.y.z", traits: ["SQLiteVectorStore"]),
// …
.target(name: "MyApp", dependencies: [
    .product(name: "SemanticStore", package: "SwiftAgents"),
    .product(name: "Providers", package: "SwiftAgents"),
])
```

`LocalVectorStore` needs no trait. (`SQLiteVectorStore` pulls in
[`SQLiteKit`](https://github.com/Cocoanetics/SQLiteKit); building it requires
the `SQLiteVectorStore` trait — locally, `swift build --traits SQLiteVectorStore`.)

## Quick start

```swift
import Providers
import SemanticStore

// On-disk store. On Apple, embeddings default to on-device NLContextualEmbedding.
let store = try SQLiteVectorStore(storage: .file("\(appSupport)/memory.sqlite"))

// …or bring your own embedder:
let store = try SQLiteVectorStore(
    storage: .file(dbPath),
    embeddingProvider: OpenAI(apiKey: key)            // or OllamaAPI(endpointURL:)
)

// Index ad-hoc text under a (path, source) identity.
try await store.indexText(noteBody, path: "ideas/2026-06.md", source: "notes")

// Search — hybrid by default (semantic + keyword fused 0.7 / 0.3).
let hits = try await store.hybridSearch(text: "how do I rotate the key?", topN: 5)
for hit in hits {
    print(hit.citation)   // "notes:ideas/2026-06.md:12:34"
    print(hit.text)
}
```

## Indexing

| Method | Use |
|---|---|
| `indexText(_:path:source:)` | Index a string. Re-indexing the same `(path, source)` replaces its chunks. |
| `indexFile(at:source:workspaceDir:)` | Index a file **incrementally** — unchanged content (by hash) returns `.unchanged` and is *not* re-embedded. |
| `sync(files:source:workspaceDir:)` | Index a list of files, then **prune** chunks for any file of that source no longer listed. |

```swift
// Cheap to call on every launch: only changed files are re-embedded,
// deleted files are pruned.
let files = try FileManager.default.contentsOfDirectory(atPath: dir)
    .filter { $0.hasSuffix(".md") }.map { "\(dir)/\($0)" }
let summary = try await store.sync(files: files, source: "docs", workspaceDir: dir)
// summary -> SyncSummary(indexed: 2, unchanged: 40, removed: 1, missing: 0)
```

Text is chunked line-aware (`LineChunker`, ~2000 chars with overlap), and each
chunk keeps its 1-indexed `startLine`/`endLine` — that's what powers citations.

## Searching

```swift
// Pure semantic (vec0 cosine KNN):
let a = try await store.search(text: "deployment rollback steps", topN: 8)

// Pure keyword (full FTS5 syntax — phrases, AND/OR):
let b = try store.keywordSearch("\"error code 42\"", topN: 5)

// Hybrid, tuned toward lexical, scoped to one source:
let c = try await store.hybridSearch(
    text: query, topN: 10, vectorWeight: 0.5, textWeight: 0.5, sources: ["docs"]
)
```

Every result is a `MemoryMatch`:

```swift
public struct MemoryMatch: Equatable, Sendable {
    public let path: String
    public let source: String
    public let startLine: Int         // 0/0 = whole artifact (no line span)
    public let endLine: Int
    public let text: String
    public let score: Double          // higher is better
    public var citation: String       // "source:path:startLine:endLine"
}
```

`score` is cosine for `search`, normalized bm25 for `keywordSearch`, and the
weighted blend for `hybridSearch`. A `0/0` line span means the match covers
the whole artifact (hosted results, where chunking is server-side); the
citation then omits the span (`source:path`).

## Hosted: `OpenAIVectorStore`

The same indexing/search API against an OpenAI hosted vector store — useful
when the corpus should live server-side (shared across machines, queried by
the `file_search` tool, PDFs/docx parsed for you):

```swift
import Providers
import SemanticStore

let client = OpenAI(apiKey: key)
let store = try await OpenAIVectorStore.openOrCreate(named: "my-knowledge", client: client)

try await store.indexText(noteBody, path: "ideas/2026-06.md", source: "notes")
let summary = try await store.sync(files: files, source: "docs", workspaceDir: dir)

let hits = try await store.search(text: "how do I rotate the key?", topN: 5)
for hit in hits {
    print(hit.citation)   // "notes:ideas/2026-06.md" — no line span, chunking is server-side
    print(hit.text)
}

try await store.delete()  // removes the store and its uploaded files
```

Parity notes:

- **Identity.** Every document carries `path` / `source` / content-`hash`
  attributes, so `(path, source)` works exactly like the local store:
  re-indexing replaces, unchanged content is skipped, `sync` prunes.
- **Units.** The hosted service chunks server-side: `indexText` returns 1,
  `count()` counts documents (the local store counts chunks), and matches
  have no line span.
- **Files.** `indexFile`/`sync` upload raw bytes — formats the service can
  parse (Markdown, PDF, docx, code, …) all work, unlike the local store's
  UTF-8-only reader.
- **Cost & latency.** Indexing waits for server-side processing (seconds per
  document); storage and `file_search` usage bill to your OpenAI account.
  Deleting through `delete()`/`sync` also deletes the underlying uploaded
  `File` objects so storage doesn't leak.

## Query rewriting

Both stores can rewrite a query before retrieval; they do it differently.

**Hosted** — one opaque flag. The service rewrites the query server-side
(extra model call per search, billed):

```swift
let store = OpenAIVectorStore(client: client, id: id, rewritesQueries: true)
// or flip it later: store.rewritesQueries = true

let hits = try await store.search(text: "who keeps the lighthouse burning?", topN: 5)
print(store.lastSearchQueries)   // what the rewriter actually executed
```

**Local** — `expandedSearch`, the qmd pipeline, with the moving parts exposed.
A `QueryExpander` rewrites the query into *typed* sub-queries — `lex` (keyword
variant for FTS5), `vec` (semantic rephrasing for the embedding space), `hyde`
(a hypothetical answer passage whose vector lands near real answers) — and the
store fuses the original query (weighted above its expansions) with every
expansion via Reciprocal Rank Fusion. A bm25 strong-signal gate skips the
rewrite entirely when the literal query already has a clear winner, so the
LLM is only consulted when it can help:

```swift
// No LLM at all — template HyDE + raw lex/vec probes:
let hits = try await store.expandedSearch(
    text: "rotate the signing key", using: TemplateQueryExpander(), topN: 8)

// LLM-backed (any chat model; grounding drops off-topic rewrites):
let expander = LLMQueryExpander { prompt in
    let response = try await client.createChatCompletion(
        model: "gpt-5.4-mini", messages: [ChatMessage(role: .user, content: .text(prompt))])
    return response.choices.first?.message.textContent ?? ""
}
let better = try await store.expandedSearch(
    text: "rotate the signing key", using: expander, intent: "security runbooks", topN: 8)
```

Pre-typed queries can skip the expander and feed `fusedSearch` directly —
that's what `qmd query --lex … --vec … --hyde …` does.

The raw endpoints are public on the `OpenAI` client too
(`createVectorStore`, `createVectorStoreFile(vectorStoreId:fileId:attributes:)`,
`searchVectorStore(id:query:maxNumResults:filters:rewriteQuery:)`, …) if you
need the wire-level API directly.

## Notes & caveats

- **On-device embeddings.** With no provider on Apple platforms, the store uses
  `NLContextualEmbedding`. It selects a model per *script*, and different
  scripts have different vector dimensions — so a **single-script corpus works**
  as-is, but mixing scripts (e.g. Latin + CJK) trips the store's
  `dimensionMismatch` guard. Pin one provider/model for mixed-language corpora.
- **Cost.** Indexing embeds every chunk (network/cost with a remote provider);
  `indexFile`/`sync` are incremental, so steady-state only re-embeds changes.
- **Storage.** The database is a single SQLite file — back it up or ship it.
- **Persistence.** Reopening a `.file` store recovers all vectors; no re-embed.
