# VectorStore

Two embedding-backed stores for semantic search:

- **`LocalVectorStore`** — in-memory, brute-force cosine. Zero setup, good for
  a few hundred chunks that live only for the session.
- **`SQLiteVectorStore`** — **persistent**, SQLite-backed. Semantic (vec0
  cosine KNN), keyword (FTS5 bm25), and hybrid search over one file, with
  file-level provenance and incremental re-indexing. This is what you want for
  an on-disk knowledge base.

Both reuse the `Providers.EmbeddingProvider` abstraction, so you can embed with
OpenAI, Ollama, or — on Apple platforms — on-device `NLContextualEmbedding`
(no API key, no model download beyond the OS asset).

## Enabling `SQLiteVectorStore`

It's behind an opt-in package trait so the default build stays free of the
SQLite engine. In your `Package.swift`:

```swift
.package(url: "https://github.com/Cocoanetics/SwiftAgents", from: "x.y.z", traits: ["SQLiteVectorStore"]),
// …
.target(name: "MyApp", dependencies: [
    .product(name: "VectorStore", package: "SwiftAgents"),
    .product(name: "Providers", package: "SwiftAgents"),
])
```

`LocalVectorStore` needs no trait. (`SQLiteVectorStore` pulls in SwiftPorts'
`SQLiteKit`; building it requires the `SQLiteVectorStore` trait — locally,
`swift build --traits SQLiteVectorStore`.)

## Quick start

```swift
import Providers
import VectorStore

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
public struct MemoryMatch: Equatable {
    public let path: String
    public let source: String
    public let startLine: Int
    public let endLine: Int
    public let text: String
    public let score: Double          // higher is better
    public var citation: String       // "source:path:startLine:endLine"
}
```

`score` is cosine for `search`, normalized bm25 for `keywordSearch`, and the
weighted blend for `hybridSearch`.

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
