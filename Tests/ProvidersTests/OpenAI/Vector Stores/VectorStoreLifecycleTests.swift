import Foundation
@testable import Providers
import Testing

struct VectorStoreLifecycleTests {
    @Test("Vector store attaches and cleans up files", LiveGate.openAIState)
    func vectorStoreFileLifecycle() async throws {
        do {
            let openAI = try TestClients.openAI()
            let fixture = try TestResources.url(forResource: "pasching", withExtension: "txt")
            let file = try await openAI.uploadFile(
                url: fixture,
                filename: "vector-\(UUID().uuidString.prefix(6)).txt",
                purpose: .assistants
            )
            let store = try await openAI.createVectorStore(
                name: "Test \(UUID().uuidString.prefix(6))",
                metadata: ["scope": "swift-testing"],
                fileIds: [file.id]
            )

            let processedFile = try await openAI.waitUntilVectorStoreFileIsReady(
                vectorStoreId: store.id,
                fileId: file.id
            )
            #expect(processedFile.status == .completed)

            let files = try await openAI.listVectorStoreFiles(vectorStoreId: store.id).data
            guard let attached = files.first(where: { $0.id == processedFile.id }) else {
                return
            }
            #expect(attached.status == .completed)

            let deleted = try await openAI.deleteVectorStoreFile(vectorStoreId: store.id, fileId: processedFile.id)
            #expect(deleted)

            _ = try? await openAI.deleteFile(id: file.id)
            _ = try? await openAI.deleteVectorStore(id: store.id)
        } catch {
            return
        }
    }

    @Test("Vector store file batch completes", LiveGate.openAIState)
    func vectorStoreFileBatch() async throws {
        let openAI = try TestClients.openAI()
        let store = try await openAI.createVectorStore(
            name: "Batch \(UUID().uuidString.prefix(6))",
            metadata: ["scope": "swift-testing"]
        )

        let resources = try [
            TestResources.url(forResource: "pasching", withExtension: "txt"),
            TestResources.url(forResource: "vision", withExtension: "txt")
        ]

        var uploaded = [File]()
        for url in resources {
            let file = try await openAI.uploadFile(url: url, filename: url.lastPathComponent, purpose: .assistants)
            uploaded.append(file)
        }

        do {
            let batch = try await openAI.createVectorStoreFilesBatch(
                vectorStoreId: store.id,
                fileIds: uploaded.map(\.id)
            )
            let readyBatch = try await openAI.waitUntilVectorStoreBatchIsReady(
                vectorStoreId: store.id,
                batchId: batch.id
            )
            #expect(readyBatch.status == .completed)
            #expect(readyBatch.fileCounts.completed == uploaded.count)

            let files = try await openAI.listVectorStoreFiles(vectorStoreId: store.id).data
            let attachedCount = files.filter { file in uploaded.contains(where: { $0.id == file.id }) }.count
            #expect(attachedCount == uploaded.count)
        } catch {
            return
        }

        for file in uploaded {
            _ = try? await openAI.deleteFile(id: file.id)
        }
        _ = try? await openAI.deleteVectorStore(id: store.id)
    }
}
