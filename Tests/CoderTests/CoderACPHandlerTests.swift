@testable import Coder
import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// Drives `CoderACPHandler` through the real ACP client↔server harness over an
/// in-process `LoopbackTransport` — the same shape as SwiftACP's own server
/// tests, but exercising Coder's issue-#32 surface: `session/load` (persistence
/// across a simulated restart), session modes (`session/set_mode`), and the
/// reasoning-effort config option (`session/set_config_option`). None of these
/// paths reach the model, so the suite is deterministic and needs no API key.
struct CoderACPHandlerTests {
    /// A throwaway `~/.coder/acp-sessions`-style directory, unique per handler.
    private func tempStore() -> CoderSessionStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coder-tests-\(UUID().uuidString)", isDirectory: true)
        return CoderSessionStore(directory: dir)
    }

    private func makePair(_ handler: CoderACPHandler)
        async -> (client: ACPAgentConnection, serverTask: Task<Void, Error>) {
        let (clientTransport, serverTransport) = LoopbackTransport.pair()
        let server = ACPAgentServer(handler: handler, transport: serverTransport)
        let serverTask = Task { try await server.run() }
        let client = ACPAgentConnection(
            transport: clientTransport, handlers: .standard(permission: .approveAll)
        )
        await client.start()
        return (client, serverTask)
    }

    @Test func newSessionAdvertisesLoadModesConfigAndModels() async throws {
        let handler = CoderACPHandler(workingDirectory: "/tmp", model: "gpt-5.4", store: tempStore())
        let (client, serverTask) = await makePair(handler)

        let info = try await client.initialize(capabilities: .headlessController, clientInfo: .acpx)
        #expect(info.agentCapabilities?.loadSession == true)

        let session = try await client.newSession(NewSessionRequest(cwd: "/tmp"))

        // Mode menu: code (default) + plan.
        #expect(session.modes?.currentModeId == "code")
        #expect(session.modes?.availableModes.map(\.id) == ["code", "plan"])

        // Config panel: a reasoning-effort select defaulting to "auto".
        let option = session.configOptions?.first
        #expect(option?["id"]?.stringValue == "reasoning_effort")
        #expect(option?["type"]?.stringValue == "select")
        #expect(option?["currentValue"]?.stringValue == "auto")

        // Model menu carries the current model.
        let models = try session.models?.decoded(SessionModelState.self)
        #expect(models?.currentModelId == "gpt-5.4")

        await client.close()
        serverTask.cancel()
    }

    @Test func setModeSwitchesEmitsUpdateAndRejectsUnknown() async throws {
        let handler = CoderACPHandler(workingDirectory: "/tmp", model: "gpt-5.4", store: tempStore())
        let (client, serverTask) = await makePair(handler)
        _ = try await client.initialize(capabilities: .headlessController, clientInfo: .acpx)
        let session = try await client.newSession(NewSessionRequest(cwd: "/tmp"))

        let (subscriptionId, stream) = await client.makeSubscription()
        let modeUpdate = Task { () -> String? in
            for await note in stream where note.sessionId == session.sessionId {
                if case let .currentModeUpdate(modeId) = note.update { return modeId }
            }
            return nil
        }

        try await client.setMode(SetSessionModeRequest(sessionId: session.sessionId, modeId: "plan"))
        #expect(await modeUpdate.value == "plan")
        await client.endSubscription(subscriptionId)

        await #expect(throws: (any Error).self) {
            try await client.setMode(
                SetSessionModeRequest(sessionId: session.sessionId, modeId: "banana")
            )
        }

        await client.close()
        serverTask.cancel()
    }

    @Test func setConfigOptionRoundTripsAndRejectsBad() async throws {
        let handler = CoderACPHandler(workingDirectory: "/tmp", model: "gpt-5.4", store: tempStore())
        let (client, serverTask) = await makePair(handler)
        _ = try await client.initialize(capabilities: .headlessController, clientInfo: .acpx)
        let session = try await client.newSession(NewSessionRequest(cwd: "/tmp"))

        // A valid switch echoes the full option set reflecting the new value.
        let response = try await client.setConfigOption(SetSessionConfigOptionRequest(
            sessionId: session.sessionId, configId: "reasoning_effort", value: "high"
        ))
        #expect(response.configOptions?.first?["currentValue"]?.stringValue == "high")

        // A bad value is rejected.
        await #expect(throws: (any Error).self) {
            _ = try await client.setConfigOption(SetSessionConfigOptionRequest(
                sessionId: session.sessionId, configId: "reasoning_effort", value: "ludicrous"
            ))
        }
        // An unknown option id is rejected.
        await #expect(throws: (any Error).self) {
            _ = try await client.setConfigOption(SetSessionConfigOptionRequest(
                sessionId: session.sessionId, configId: "made_up", value: "x"
            ))
        }

        await client.close()
        serverTask.cancel()
    }

    @Test func modeModelAndConfigPersistAcrossRestart() async throws {
        // One shared on-disk store models the same `~/.coder` across a restart.
        let store = tempStore()

        // First "process": create the session and change mode + config + model.
        let first = CoderACPHandler(workingDirectory: "/tmp", model: "gpt-5.4", store: store)
        let (client1, task1) = await makePair(first)
        _ = try await client1.initialize(capabilities: .headlessController, clientInfo: .acpx)
        let session = try await client1.newSession(NewSessionRequest(cwd: "/work"))
        try await client1.setMode(SetSessionModeRequest(sessionId: session.sessionId, modeId: "plan"))
        _ = try await client1.setConfigOption(SetSessionConfigOptionRequest(
            sessionId: session.sessionId, configId: "reasoning_effort", value: "medium"
        ))
        await client1.close()
        task1.cancel()

        // Second "process": a fresh handler over the same store resumes the session.
        let second = CoderACPHandler(workingDirectory: "/tmp", model: "gpt-5.4", store: store)
        let (client2, task2) = await makePair(second)
        _ = try await client2.initialize(capabilities: .headlessController, clientInfo: .acpx)
        let loaded = try await client2.loadSession(
            LoadSessionRequest(sessionId: session.sessionId, cwd: "/work")
        )

        #expect(loaded.modes?.currentModeId == "plan")
        #expect(loaded.configOptions?.first?["currentValue"]?.stringValue == "medium")

        await client2.close()
        task2.cancel()
    }

    @Test func loadReplaysPersistedTranscript() async throws {
        let store = tempStore()
        // Seed a persisted session with a short transcript (as a completed turn would).
        let seeded = CoderSessionState(
            sessionId: "coder-seeded", cwd: "/work", model: "gpt-5.4", modeId: "code",
            reasoningEffort: "auto", lastResponseId: "resp_123",
            history: [
                .init(role: .user, text: "hello there"),
                .init(role: .assistant, text: "general kenobi")
            ]
        )
        store.save(seeded)

        let handler = CoderACPHandler(workingDirectory: "/tmp", model: "gpt-5.4", store: store)
        let (client, serverTask) = await makePair(handler)
        _ = try await client.initialize(capabilities: .headlessController, clientInfo: .acpx)

        let (subscriptionId, stream) = await client.makeSubscription()
        let replay = Task { () -> (user: String, assistant: String) in
            var user = "", assistant = ""
            for await note in stream where note.sessionId == "coder-seeded" {
                switch note.update {
                    case let .userMessageChunk(block): user += block.text ?? ""
                    case let .agentMessageChunk(block): assistant += block.text ?? ""
                    default: break
                }
                if !user.isEmpty, !assistant.isEmpty { break }
            }
            return (user, assistant)
        }

        _ = try await client.loadSession(LoadSessionRequest(sessionId: "coder-seeded", cwd: "/work"))
        let transcript = await replay.value
        await client.endSubscription(subscriptionId)

        #expect(transcript.user == "hello there")
        #expect(transcript.assistant == "general kenobi")

        await client.close()
        serverTask.cancel()
    }

    @Test func loadUnknownSessionThrows() async throws {
        let handler = CoderACPHandler(workingDirectory: "/tmp", model: "gpt-5.4", store: tempStore())
        let (client, serverTask) = await makePair(handler)
        _ = try await client.initialize(capabilities: .headlessController, clientInfo: .acpx)

        await #expect(throws: (any Error).self) {
            _ = try await client.loadSession(
                LoadSessionRequest(sessionId: "coder-nope", cwd: "/work")
            )
        }

        await client.close()
        serverTask.cancel()
    }

    @Test func planModeRefusesMutationButAllowsReads() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coder-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "hello world".write(to: dir.appendingPathComponent("fix.txt"), atomically: true, encoding: .utf8)

        let plan = CodingAgent(workingDirectory: dir.path, readOnly: true)
        // Reads still work in plan mode.
        #expect(try plan.read(path: "fix.txt").contains("hello"))
        // The apply_patch builtin isn't even offered.
        #expect(plan.tools.isEmpty)
        // Every mutating tool refuses before touching the working tree.
        await #expect(throws: (any Error).self) { _ = try await plan.bash(command: "echo hi") }
        #expect(throws: (any Error).self) { try plan.write(path: "new.txt", content: "x") }
        #expect(throws: (any Error).self) {
            try plan.edit(path: "fix.txt", edits: [Edit(oldText: "hello", newText: "hi")])
        }
        // The refusal left the file untouched.
        #expect(try String(contentsOf: dir.appendingPathComponent("fix.txt"), encoding: .utf8) == "hello world")

        // In code mode the same write goes through.
        let code = CodingAgent(workingDirectory: dir.path, readOnly: false)
        #expect(try code.write(path: "new.txt", content: "ok").contains("Wrote"))
    }

    @Test func sessionStoreRoundTrips() throws {
        let store = tempStore()
        let state = CoderSessionState(
            sessionId: "coder-abc", cwd: "/x", model: "gpt-5.4", modeId: "plan",
            reasoningEffort: "high", lastResponseId: "resp_9",
            history: [.init(role: .user, text: "hi")]
        )
        store.save(state)

        let loaded = try #require(store.load("coder-abc"))
        #expect(loaded.cwd == "/x")
        #expect(loaded.modeId == "plan")
        #expect(loaded.reasoningEffort == "high")
        #expect(loaded.lastResponseId == "resp_9")
        #expect(loaded.history.count == 1)
        #expect(store.load("coder-missing") == nil)
    }
}
