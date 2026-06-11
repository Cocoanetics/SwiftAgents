//
//  OpenAIVectorStore.swift
//  SwiftAgents
//
//  ``SemanticStore`` over an OpenAI hosted vector store — the same
//  index/sync/search API as the local `SQLiteVectorStore`, but chunking,
//  embedding, and retrieval run server-side (the stores behind the
//  Responses/Assistants `file_search` tool).
//
//  Identity and incrementality mirror the local store: every document
//  carries `path` / `source` / content-`hash` attributes, so re-indexing
//  skips unchanged content, re-uploads replace the prior document, and
//  `sync` prunes documents whose file disappeared. Spans are 0/0 — the
//  service chunks server-side, so there is no line provenance — which
//  `MemoryMatch.citation` renders as `source:path`.
//
//  Not trait-gated: unlike `SQLiteVectorStore` there is no SQLite engine to
//  pull in, only `Providers`' OpenAI client.
//

import Foundation
import Providers

/// Errors thrown by ``OpenAIVectorStore``.
public enum OpenAIVectorStoreError: Error, CustomStringConvertible {
    /// The service finished processing a document with a failure.
    case processingFailed(path: String, message: String?)

    public var description: String {
        switch self {
            case let .processingFailed(path, message):
                return "vector store processing failed for \(path): \(message ?? "unknown error")"
        }
    }
}

/// Indexes documents into an OpenAI hosted vector store and searches them —
/// a drop-in ``SemanticStore`` next to the local `SQLiteVectorStore`.
public final class OpenAIVectorStore {
    /// The attribute keys this class stamps on every document it attaches.
    /// Plain lowercase on purpose — see ``VectorStoreAttribute``.
    private enum AttributeKey {
        static let path = "path"
        static let source = "source"
        static let hash = "hash"
    }

    /// The OpenAI client used for every call.
    public let client: OpenAI

    /// The hosted vector store id (`vs_…`).
    public let id: String

    /// Seconds between polls while waiting for server-side processing.
    private let pollInterval: TimeInterval

    /// When true, every ``search(text:topN:sources:)`` asks the service to
    /// rewrite the query before retrieval — the hosted analogue of the local
    /// store's `expandedSearch`. Off by default: it adds a model call's
    /// latency and cost to each search.
    public var rewritesQueries: Bool

    /// The query (or queries) the service actually executed in the most
    /// recent ``search(text:topN:sources:)`` — with ``rewritesQueries`` on,
    /// this shows what the rewriter produced. (Same pattern as the API
    /// client's `rateLimit`: a side channel beside the protocol method.)
    public private(set) var lastSearchQueries: [String] = []

    /// Wraps an existing hosted vector store.
    public init(client: OpenAI, id: String, pollInterval: TimeInterval = 1, rewritesQueries: Bool = false) {
        self.client = client
        self.id = id
        self.pollInterval = pollInterval
        self.rewritesQueries = rewritesQueries
    }

    /// Creates a new hosted vector store and returns a handle to it.
    public static func create(
        named name: String,
        client: OpenAI,
        expiresAfterDays days: Int? = nil
    ) async throws -> OpenAIVectorStore {
        let store = try await client.createVectorStore(
            name: name,
            expiresAfter: days.map { ExpirationPolicy(days: $0) }
        )
        return OpenAIVectorStore(client: client, id: store.id)
    }

    /// A handle to the first hosted vector store named `name`, created when
    /// none exists — the hosted analogue of opening a store file.
    public static func openOrCreate(named name: String, client: OpenAI) async throws -> OpenAIVectorStore {
        for try await store in client.listVectorStoresStream() where store.name == name {
            return OpenAIVectorStore(client: client, id: store.id)
        }
        return try await create(named: name, client: client)
    }

    /// Deletes the hosted vector store. Detached `File` objects belong to the
    /// account, not the store, so by default the documents' uploads are
    /// deleted too; pass `false` to keep them.
    public func delete(includingFiles: Bool = true) async throws {
        if includingFiles {
            for document in try await inventory().values {
                _ = try? await client.deleteFile(id: document.fileID)
            }
        }
        try await client.deleteVectorStore(id: id)
    }

    // MARK: - Indexing

    /// Indexes `text` under (`path`, `source`), replacing whatever the store
    /// held for that identity; unchanged text (by hash) is not re-uploaded.
    /// Returns 1 — the service chunks server-side, so the unit is the document.
    @discardableResult
    public func indexText(_ text: String, path: String, source: String = "memory") async throws -> Int {
        let hash = fnv1aHash(text.utf8)
        let existing = try await inventory()[Self.key(path: path, source: source)]
        if existing?.hash == hash { return 1 }
        try await upsert(Data(text.utf8), path: path, source: source, hash: hash, replacing: existing)
        return 1
    }

    /// Indexes a file on disk, skipping it when its content hash is unchanged
    /// since the last index. Binary formats the service can parse (PDF, docx,
    /// …) work as well as text. `workspaceDir`, if given, is stripped from
    /// the stored `path` so citations stay relative.
    @discardableResult
    public func indexFile(
        at filePath: String,
        source: String = "memory",
        workspaceDir: String? = nil
    ) async throws -> IndexOutcome {
        try await indexFile(
            at: filePath, source: source, workspaceDir: workspaceDir,
            inventory: try await inventory()
        )
    }

    /// Indexes every file in `files` (incrementally), then prunes documents
    /// of this `source` whose file is no longer listed — the same
    /// directory-sync flow as the local store.
    @discardableResult
    public func sync(
        files: [String],
        source: String = "memory",
        workspaceDir: String? = nil
    ) async throws -> SyncSummary {
        let inventory = try await inventory()
        var summary = SyncSummary()
        var seen = Set<String>()
        for file in files {
            switch try await indexFile(at: file, source: source, workspaceDir: workspaceDir, inventory: inventory) {
                case .indexed:
                    summary.indexed += 1
                    seen.insert(relativePath(file, to: workspaceDir))
                case .unchanged:
                    summary.unchanged += 1
                    seen.insert(relativePath(file, to: workspaceDir))
                case .missing:
                    summary.missing += 1
            }
        }
        for document in inventory.values where document.source == source && !seen.contains(document.path) {
            try await remove(document)
            summary.removed += 1
        }
        return summary
    }

    /// The number of fully processed documents. The hosted analogue counts
    /// documents, not chunks — chunking happens server-side.
    public func count() async throws -> Int {
        try await client.retrieveVectorStore(id: id).fileCounts.completed
    }

    // MARK: - Search

    /// The `topN` chunks most relevant to `text` (server-side semantic
    /// ranking), optionally restricted to the given `sources` via an
    /// attribute filter. With ``rewritesQueries`` on, the service rewrites
    /// the query first.
    public func search(text: String, topN: Int, sources: [String]? = nil) async throws -> [MemoryMatch] {
        guard topN > 0 else { return [] }
        var filter: VectorStoreFilter?
        if let sources, !sources.isEmpty {
            let legs = sources.map { VectorStoreFilter.eq(AttributeKey.source, .string($0)) }
            filter = legs.count == 1 ? legs[0] : .or(legs)
        }
        let page = try await client.searchVectorStore(
            id: id,
            query: text,
            maxNumResults: min(topN, 50),   // the endpoint's documented ceiling
            filters: filter,
            rewriteQuery: rewritesQueries ? true : nil
        )
        lastSearchQueries = page.searchQuery
        return page.data.map(Self.match(from:))
    }

    /// Maps one hosted search hit onto the shared ``MemoryMatch`` shape: the
    /// identity comes from the indexing attributes (falling back to the raw
    /// filename for files attached outside this class), the span is 0/0.
    static func match(from result: VectorStoreSearchResult) -> MemoryMatch {
        MemoryMatch(
            path: result.attributes?[AttributeKey.path]?.stringValue ?? result.filename,
            source: result.attributes?[AttributeKey.source]?.stringValue ?? "",
            startLine: 0, endLine: 0,
            text: result.text,
            score: result.score
        )
    }

    // MARK: - Remote bookkeeping

    /// What the store holds for one (`path`, `source`) identity — the hosted
    /// twin of the local `files` table row.
    struct RemoteDocument {
        let fileID: String
        let path: String
        let source: String
        let hash: String?
    }

    private static func key(path: String, source: String) -> String {
        source + "\u{0}" + path
    }

    /// Every document in the store, keyed by (`path`, `source`). Files
    /// attached outside this class carry no identity attributes and key by
    /// their file id under the empty source.
    private func inventory() async throws -> [String: RemoteDocument] {
        var result: [String: RemoteDocument] = [:]
        var after: String?
        repeat {
            let page = try await client.listVectorStoreFiles(vectorStoreId: id, limit: 100, after: after)
            for file in page.data {
                let path = file.attributes?[AttributeKey.path]?.stringValue ?? file.id
                let source = file.attributes?[AttributeKey.source]?.stringValue ?? ""
                result[Self.key(path: path, source: source)] = RemoteDocument(
                    fileID: file.id, path: path, source: source,
                    hash: file.attributes?[AttributeKey.hash]?.stringValue
                )
            }
            after = page.hasMore ? page.lastId : nil
        } while after != nil
        return result
    }

    private func indexFile(
        at filePath: String,
        source: String,
        workspaceDir: String?,
        inventory: [String: RemoteDocument]
    ) async throws -> IndexOutcome {
        guard let data = FileManager.default.contents(atPath: filePath) else { return .missing }
        let hash = fnv1aHash(data)
        let storedPath = relativePath(filePath, to: workspaceDir)
        let existing = inventory[Self.key(path: storedPath, source: source)]
        if existing?.hash == hash { return .unchanged }
        try await upsert(data, path: storedPath, source: source, hash: hash, replacing: existing)
        return .indexed(chunks: 1)
    }

    /// Uploads `data` as the document for (`path`, `source`) — stamped with
    /// the identity attributes — replacing `existing`, and waits until the
    /// service has finished processing it so a subsequent search sees it.
    private func upsert(
        _ data: Data,
        path: String,
        source: String,
        hash: String,
        replacing existing: RemoteDocument?
    ) async throws {
        if let existing {
            try await remove(existing)
        }
        let file = try await client.uploadFile(
            data: data,
            filename: Self.filename(for: path),
            mimeType: "application/octet-stream",
            purpose: .assistants
        )
        _ = try await client.createVectorStoreFile(
            vectorStoreId: id,
            fileId: file.id,
            attributes: [
                AttributeKey.path: .string(path),
                AttributeKey.source: .string(source),
                AttributeKey.hash: .string(hash)
            ]
        )
        let processed = try await client.waitUntilVectorStoreFileIsReady(
            vectorStoreId: id, fileId: file.id, interval: pollInterval
        )
        guard processed.status == .completed else {
            throw OpenAIVectorStoreError.processingFailed(path: path, message: processed.lastError?.message)
        }
    }

    /// Detaches a document from the store and deletes its uploaded `File`
    /// (detaching alone would leave the upload billed to the account).
    private func remove(_ document: RemoteDocument) async throws {
        try await client.deleteVectorStoreFile(vectorStoreId: id, fileId: document.fileID)
        _ = try? await client.deleteFile(id: document.fileID)
    }

    /// The upload filename for a logical path: its last component, given a
    /// `.txt` extension when it has none — the service infers the parser
    /// from the extension. The full path travels in the attributes.
    static func filename(for path: String) -> String {
        let base = path.split(separator: "/").last.map(String.init) ?? path
        return base.contains(".") ? base : base + ".txt"
    }
}

extension OpenAIVectorStore: SemanticStore {}
