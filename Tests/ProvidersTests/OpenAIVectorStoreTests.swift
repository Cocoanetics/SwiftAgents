//
//  OpenAIVectorStoreTests.swift
//  SwiftAgents
//
//  Offline coverage for the hosted vector store wire types (attribute
//  values, filters, the search page) and `OpenAIVectorStore`'s mapping
//  onto the shared `SemanticStore` shapes — plus a live round-trip
//  (index → search → incremental skip → sync prune → delete) gated on
//  `OPENAI_API_KEY`:
//      swift test --filter OpenAIVectorStore
//

import Foundation
@testable import Providers
import Testing
@testable import SemanticStore

struct OpenAIVectorStoreTests {
    // MARK: - Wire types (offline)

    @Test("attribute filters round-trip through the OpenAI coder")
    func filterRoundTrip() throws {
        let client = OpenAI(apiKey: "test")
        let filter = VectorStoreFilter.or([
            .eq("source", "wiki"),
            .and([.ne("source", "memory"), .comparison(key: "rank", operation: .gte, value: 3)])
        ])

        let data = try client.encoder.encode(filter)
        let decoded = try client.decoder.decode(VectorStoreFilter.self, from: data)
        #expect(decoded == filter)

        // Spot-check the wire shape: lowercase single-word keys survive the
        // snake_case key strategy untouched.
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["type"] as? String == "or")
        let legs = object?["filters"] as? [[String: Any]]
        #expect(legs?.first?["key"] as? String == "source")
        #expect(legs?.first?["value"] as? String == "wiki")
    }

    @Test("search page decodes snake_case JSON with mixed-type attributes")
    func searchPageDecoding() throws {
        let json = """
        {
          "object": "vector_store.search_results.page",
          "search_query": ["stormy dragon"],
          "data": [
            {
              "file_id": "file-abc",
              "filename": "Stormy.md",
              "score": 0.92,
              "attributes": {
                "path": "Characters/Stormy.md",
                "source": "wiki",
                "hash": "deadbeef",
                "pinned": true,
                "rank": 3
              },
              "content": [
                {"type": "text", "text": "# Stormy"},
                {"type": "text", "text": "She relights the beacon."}
              ]
            }
          ],
          "has_more": false,
          "next_page": null
        }
        """
        let page = try OpenAI(apiKey: "test").decoder
            .decode(VectorStoreSearchResultsPage.self, from: Data(json.utf8))

        #expect(page.hasMore == false)
        #expect(page.searchQuery == ["stormy dragon"])
        let result = try #require(page.data.first)
        #expect(result.fileId == "file-abc")
        #expect(result.score == 0.92)
        #expect(result.attributes?["pinned"] == .bool(true))
        #expect(result.attributes?["rank"] == .number(3))
        #expect(result.text == "# Stormy\nShe relights the beacon.")
    }

    @Test("search_query decodes from both wire forms, and absence")
    func searchQueryWireForms() throws {
        let decoder = OpenAI(apiKey: "test").decoder
        func page(_ fragment: String) throws -> VectorStoreSearchResultsPage {
            try decoder.decode(VectorStoreSearchResultsPage.self, from: Data("""
            {"object": "vector_store.search_results.page", \(fragment) "data": [], "has_more": false, "next_page": null}
            """.utf8))
        }
        #expect(try page(#""search_query": ["a", "b"],"#).searchQuery == ["a", "b"])
        #expect(try page(#""search_query": "plain","#).searchQuery == ["plain"])
        #expect(try page("").searchQuery.isEmpty)
    }

    @Test("vector store file status decodes the failure states")
    func fileStatusFailureStates() throws {
        let statuses = try JSONDecoder().decode(
            [FileStatus].self,
            from: Data(#"["failed", "cancelled", "in_progress"]"#.utf8)
        )
        #expect(statuses == [.failed, .cancelled, .inProgress])
    }

    // MARK: - SemanticStore mapping (offline)

    @Test("search hits map identity from attributes, falling back to the filename")
    func matchMapping() throws {
        let attributed = VectorStoreSearchResult(
            fileId: "file-abc", filename: "Stormy.md", score: 0.9,
            attributes: ["path": .string("Characters/Stormy.md"), "source": .string("wiki")],
            content: [.init(type: "text", text: "She relights the beacon.")]
        )
        let match = OpenAIVectorStore.match(from: attributed)
        #expect(match.path == "Characters/Stormy.md")
        #expect(match.source == "wiki")
        #expect(match.text == "She relights the beacon.")
        #expect(match.startLine == 0 && match.endLine == 0)
        #expect(match.citation == "wiki:Characters/Stormy.md")

        let foreign = VectorStoreSearchResult(
            fileId: "file-xyz", filename: "upload.pdf", score: 0.5,
            attributes: nil,
            content: []
        )
        #expect(OpenAIVectorStore.match(from: foreign).path == "upload.pdf")
        #expect(OpenAIVectorStore.match(from: foreign).source.isEmpty)
    }

    @Test("citations carry the line span only when one exists")
    func citationSpan() {
        let spanned = MemoryMatch(path: "a.md", source: "wiki", startLine: 3, endLine: 7, text: "", score: 1)
        #expect(spanned.citation == "wiki:a.md:3:7")
        let whole = MemoryMatch(path: "cat.jpg", source: "images", startLine: 0, endLine: 0, text: "", score: 1)
        #expect(whole.citation == "images:cat.jpg")
    }

    @Test("upload filenames keep their extension and gain .txt when missing")
    func uploadFilenames() {
        #expect(OpenAIVectorStore.filename(for: "Characters/Stormy.md") == "Stormy.md")
        #expect(OpenAIVectorStore.filename(for: "memory/note") == "note.txt")
        #expect(OpenAIVectorStore.filename(for: "note") == "note.txt")
    }

    @Test("the unchanged fast path needs a single, completed, hash-matching document")
    func unchangedFastPath() {
        func doc(_ hash: String, _ status: FileStatus) -> OpenAIVectorStore.RemoteDocument {
            .init(fileID: "file-1", path: "a.md", source: "wiki", hash: hash, status: status)
        }
        #expect(OpenAIVectorStore.isCurrent([doc("abc", .completed)], hash: "abc"))
        // A failed or in-flight upload is not searchable — it must re-index,
        // not satisfy the skip (it would silently poison the identity).
        #expect(!OpenAIVectorStore.isCurrent([doc("abc", .failed)], hash: "abc"))
        #expect(!OpenAIVectorStore.isCurrent([doc("abc", .cancelled)], hash: "abc"))
        #expect(!OpenAIVectorStore.isCurrent([doc("abc", .inProgress)], hash: "abc"))
        // Changed content, nothing indexed yet, or stale duplicates from an
        // interrupted replacement all re-index too.
        #expect(!OpenAIVectorStore.isCurrent([doc("old", .completed)], hash: "abc"))
        #expect(!OpenAIVectorStore.isCurrent([], hash: "abc"))
        #expect(!OpenAIVectorStore.isCurrent([doc("abc", .completed), doc("abc", .failed)], hash: "abc"))
    }

    @Test("the shared FNV-1a hash is stable and byte-based")
    func contentHashStability() {
        // Reference value for FNV-1a 64-bit of "hello" — the local and the
        // hosted store must keep producing identical hashes for identical
        // bytes, or every persisted index would re-embed on upgrade.
        #expect(fnv1aHash("hello".utf8) == "a430d84680aabd0b")
        #expect(fnv1aHash(Data("hello".utf8)) == fnv1aHash("hello".utf8))
    }

    // MARK: - Live round-trip

    @Test(
        "hosted store round-trip: index, search, incremental skip, sync prune",
        .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY")
    )
    func hostedLifecycle() async throws {
        let client = try TestClients.openAI()
        let store = try await OpenAIVectorStore.create(
            named: "swiftagents-tests-\(UUID().uuidString.prefix(8))",
            client: client,
            expiresAfterDays: 1   // safety net should teardown not run
        )

        do {
            let stormy = "Stormy is a brave little dragon who relights the lighthouse beacon for the fishing crews."
            try await store.indexText(stormy, path: "Characters/Stormy.md", source: "wiki")
            try await store.indexText(
                "Saltmere is a harbor town built on stilts over the tide flats.",
                path: "Places/Saltmere.md", source: "wiki"
            )
            #expect(try await store.count() == 2)

            let hits = try await store.search(text: "who keeps the lighthouse burning?", topN: 2)
            #expect(hits.contains { $0.path == "Characters/Stormy.md" })
            #expect(hits.allSatisfy { $0.source == "wiki" && $0.startLine == 0 })

            // Server-side query rewriting: the executed (rewritten) query
            // comes back on the page and is exposed per search.
            store.rewritesQueries = true
            _ = try await store.search(text: "who keeps the lighthouse burning?", topN: 2)
            #expect(!store.lastSearchQueries.isEmpty)
            store.rewritesQueries = false

            // Same text, same hash — the incremental skip must not re-upload.
            try await store.indexText(stormy, path: "Characters/Stormy.md", source: "wiki")
            #expect(try await store.count() == 2)

            // Sync a temp directory in its own source, then prune it empty.
            let dir = NSTemporaryDirectory() + "qmd-vs-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            try "Nimbus is a cloud spirit who gathers rain.".write(
                toFile: dir + "/Nimbus.md", atomically: true, encoding: .utf8)

            let first = try await store.sync(files: [dir + "/Nimbus.md"], source: "files", workspaceDir: dir)
            #expect(first.indexed == 1)

            let wikiOnly = try await store.search(text: "rain spirit", topN: 5, sources: ["wiki"])
            #expect(!wikiOnly.contains { $0.path == "Nimbus.md" })

            let pruned = try await store.sync(files: [], source: "files", workspaceDir: dir)
            #expect(pruned.removed == 1)

            // `fileCounts` converges asynchronously after a deletion.
            var total = try await store.count()
            for _ in 0 ..< 10 where total != 2 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                total = try await store.count()
            }
            #expect(total == 2)

            try await store.delete()
        } catch {
            try? await store.delete()
            throw error
        }
    }
}
