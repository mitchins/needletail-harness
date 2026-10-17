import Testing
import Foundation
import AsyncHTTPClient
import NeedletailCore
import NeedletailProviders
import NeedletailRuntime
import NeedletailTestSupport
@testable import NeedletailProviders

/// M1-D closure boundaries, all exercised through the production transport,
/// session actor, and sink (no test-only decoder path):
/// 1. Authorization stays fail-closed unless an explicit fixture grant is used.
/// 2. JSONL deltas are observable before completion, sequence stays monotonic,
///    bounded sinks fail loudly, and a closed pipe is never a silent drop.
/// 3. Incremental display deltas cannot diverge from the authoritative
///    OpenAPIRuntime assembly under fragmentation, CRLF/UTF-8, multiline data,
///    or incomplete completion.
@Suite(.serialized)
struct BoundaryVerificationTests {

    private typealias AuthorizedActor = SessionActor<
        ChatCompletionsTransport, TrivialExecutor, InMemorySessionStore,
        TrivialApprovals, VirtualClock, DeterministicIDSource>

    private struct SinkEnvelope: Decodable {
        let seq: UInt64
        let kind: String
    }

    private final class DeltaCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        private var finished = false

        func append(_ text: String) {
            lock.withLock { values.append(text) }
        }

        func markFinished() {
            lock.withLock { finished = true }
        }

        var beforeFinish: [String] {
            lock.withLock {
                finished ? Array(values.dropLast()) : values
            }
        }

        var joined: String {
            lock.withLock { values.joined() }
        }

        var sawDelta: Bool {
            lock.withLock { !values.isEmpty }
        }
    }

    private func spin(_ actor: AuthorizedActor, _ label: String) async throws -> SessionState {
        // Bounded polls with an explicit timeout (never sleep-as-readiness):
        // production timers complete asynchronously, so yields alone can spin
        // out before a 250ms deliberate server delay elapses.
        for _ in 0..<2_000 {
            let state = await actor.currentState()
            if case .completed = state.phase { return state }
            if case .failed = state.phase { return state }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("actor never reached \(label)")
        throw LoopbackCheckFailed.unreached
    }

    // MARK: 1. Authorization fail-closed

    @Test("WIRE-08 authorization: workspace default is fail-closed; explicit fixture is trusted")
    func authorizationFailClosed() throws {
        let json = """
        {"version":1,"default_model":"loop","allow_http_origins":["http://127.0.0.1:9"],"models":[{"alias":"loop","protocol":"openai-chat-completions","base_url":"http://127.0.0.1:9","model":"m","context_window":4096,"max_output":128,"locality":"local","connect_timeout_s":5,"read_idle_timeout_s":10,"request_timeout_s":60,"max_in_flight":1}],"tools":{"read":true,"search":true,"edit":true,"write":true,"exec":true,"consult":true}}
        """
        let snapshot = try validateConfig(Data(json.utf8))

        // The CLI default (workspace grant deny-all) must NOT implicitly grant
        // mutating tools, even when the config document names them.
        let defaultCaps = effectiveCapabilities(
            build: .allAllowed, userConfig: snapshot.tools,
            workspaceGrant: .allDenied, invocationMask: .allAllowed,
            sealed: SealedRestrictions(sealed: false))
        #expect(!toolAllowed("edit", caps: defaultCaps.tools))
        #expect(defaultCaps.tools.edit == false)
        #expect(defaultCaps.deniedBy.contains("workspaceGrant"))

        // The release-binary demo path explicitly requests trustedExec, which
        // is the only way the scripted read/edit/exec fixture executes.
        let trustedCaps = effectiveCapabilities(
            build: .allAllowed, userConfig: snapshot.tools,
            workspaceGrant: .allAllowed, invocationMask: .allAllowed,
            sealed: SealedRestrictions(sealed: false))
        #expect(toolAllowed("edit", caps: trustedCaps.tools))
        #expect(try validateTrustConsistency(mode: .trustedExec, caps: trustedCaps.tools) == .trustedExec)
        #expect(!batchNeedsApproval(toolNames: ["read"], execPolicy: trustedCaps.tools.exec, mode: .trustedExec, sealed: false))
    }

    // MARK: 2. JSONL/stream ordering + bounded sinks

    @Test("WIRE-08 delta is observable before completion and the sink order is monotonic")
    func deltaBeforeCompletion() async throws {
        let server = try LoopbackSSEServer()
        let first = "data: {\"id\":\"c\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"hello \"},\"finish_reason\":null}]}\n\n"
        let second = "data: {\"id\":\"c\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        server.enqueue(SSEScript(chunks: [
            ScriptChunk(bytes: Array(first.utf8), delayMillis: 0),
            ScriptChunk(bytes: Array(second.utf8), delayMillis: 250),
        ]))
        server.start()
        defer { server.stop() }

        let sink = InMemoryUISink(sessionID: "boundary-delta")
        let chat: ChatCompletionsTransport = try LoopbackFixtures.transport(server: server).0
        let snapshot = try LoopbackFixtures.snapshot(alias: "loop", baseURL: server.baseURL)
        defer { await LoopbackFixtures.shutdown(chat.client) }

        let actor = AuthorizedActor(
            state: try ActorLoopback.idleState(snapshot: snapshot),
            ids: DeterministicIDSource(prefix: "boundary"), clock: VirtualClock(now: 5_000_000),
            transport: chat, executor: TrivialExecutor(),
            store: InMemorySessionStore(), approvals: TrivialApprovals(), sink: sink)

        await actor.submitText(commandID: CommandID("boundary-run"), text: "hi", kind: .followUp, sealed: false)
        // Poll (never sleep-standing-in-for-readiness): completion is held by
        // the 250ms server delay, so the delta must land before that.
        var sawDeltaBeforeFinish = false
        for _ in 0..<100 {
            if sink.allLines.contains(where: { $0.contains("\"kind\":\"delta\"") }) {
                sawDeltaBeforeFinish = true
                break
            }
            // Bounded paced poll: lets the NIO/actor tasks run while the
            // 250ms completion delay is still outstanding.
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        if sawDeltaBeforeFinish {
            let observed = await actor.currentState()
            #expect(!observed.phase.isTerminal, "delta arrives while the provider run is still open")
        }
        let done = try await spin(actor, "completed")
        #expect(done.phase.isTerminal || { if case .completed = done.phase { return true } else { return false } }())
        guard case .completed = done.phase else {
            Issue.record("expected completed, got \(done.phase)"); return
        }
        #expect(sawDeltaBeforeFinish, "model delta observable before provider completion")
        // The CLI appends the terminal envelope after completion; prove the
        // sink accepts monotonic sequence with run_finished last.
        try await sink.emit(.runFinished(outcome: "completed", detail: "turns=1"))

        let envelopes = try sink.allLines.map { line -> SinkEnvelope in
            try JSONDecoder().decode(SinkEnvelope.self, from: Data(line.utf8))
        }
        #expect(envelopes.map(\.seq) == envelopes.map(\.seq).sorted(), "sequence is monotonic")
        #expect(envelopes.contains { $0.kind == "delta" }, "delta envelope present")
        #expect(envelopes.last?.kind == "run_finished", "run_finished is last")
        #expect(envelopes.map(\.seq).last == UInt64(envelopes.count), "sink sequence has no gaps")
    }

    @Test("WIRE-08 bounded sinks fail loudly instead of silently dropping")
    func boundedSinksFailLoudly() async throws {
        let memory = InMemoryUISink(sessionID: "boundary-bound")
        for index in 0..<InMemoryUISink.itemCap {
            try await memory.emit(.admitted(commandID: CommandID("c-\(index)"), revision: UInt64(index)))
        }
        #expect(memory.count == InMemoryUISink.itemCap)
        do {
            try await memory.emit(.admitted(commandID: CommandID("overflow"), revision: 0))
            Issue.record("sink overflow must fail")
        } catch let error as UISinkError {
            #expect({ if case .overflow = error { return true } else { return false } }(), "typed overflow: \(error)")
        }

        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        let fileSink = FileHandleUISink(
            handle: pipe.fileHandleForWriting, sessionID: "boundary-pipe", ownsHandle: true)
        var brokenPipe = false
        for index in 0..<20_000 {
            do {
                try await fileSink.emit(.admitted(commandID: CommandID("pipe-\(index)"), revision: UInt64(index)))
            } catch let error as UISinkError where error == .brokenPipe {
                brokenPipe = true
                break
            } catch let error as UISinkError {
                Issue.record("unexpected sink error: \(error)")
                break
            }
        }
        #expect(brokenPipe, "closed consumer maps to brokenPipe, never a silent drop")
    }

    // MARK: 3. SSE equivalence

    @Test("WIRE-08 incremental display deltas equal authoritative assembly under fragmentation")
    func incrementalEqualsAuthoritative() async throws {
        let bodies: [(name: String, text: String, fragmentSize: Int?)] = [
            ("fragmented-text", CannedTurn.text("hello world"), 7),
            ("utf8-boundary", "data: {\"choices\":[{\"delta\":{\"content\":\"héllo 🌍\"}}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n", 1),
            ("crlf", "data: {\"choices\":[{\"delta\":{\"content\":\"a\\r\\nb\"}}]}\r\n\r\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\r\n\r\ndata: [DONE]\r\n\r\n", 3),
            ("multiline-data", "data: {\"choices\":[{\"delta\":{\ndata: \"content\":\"multi line\"}}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n", 2),
            ("incomplete-completion", "data: {\"choices\":[{\"delta\":{\"content\":\"partial answer\"}}]}\n\n", 5),
        ]

        for body in bodies {
            let result = try await Self.runTransport(
                body: body.text, fragmentSize: body.fragmentSize)
            let events = try await result.transport.decodeBounded(result.rawBody)
            let turn = try assembleChatTurn(events)
            #expect(result.deltas.joined == terminalSafe(turn.text), "\(body.name): incremental != authoritative")
            if body.name == "incomplete-completion" {
                #expect(turn.isFinal == false, "incomplete completion stays non-authoritative")
            } else {
                #expect(turn.isFinal, "\(body.name): authoritative completion present")
            }
        }
    }

    private static func runTransport(
        body: String, fragmentSize: Int?
    ) async throws -> (transport: ChatCompletionsTransport, deltas: DeltaCollector, rawBody: [UInt8]) {
        let server = try LoopbackSSEServer()
        let bytes = Array(body.utf8)
        let chunks: [ScriptChunk]
        if let fragmentSize, fragmentSize > 0 {
            chunks = stride(from: 0, to: bytes.count, by: fragmentSize).map { start in
                ScriptChunk(bytes: Array(bytes[start..<min(start + fragmentSize, bytes.count)]), delayMillis: 0)
            }
        } else {
            chunks = [ScriptChunk(bytes: bytes, delayMillis: 0)]
        }
        server.enqueue(SSEScript(chunks: chunks))
        server.start()
        defer { server.stop() }

        var transport = try LoopbackFixtures.transport(server: server).0
        defer { await LoopbackFixtures.shutdown(transport.client) }
        let collector = DeltaCollector()
        transport.deltaSink = { text in collector.append(text) }
        let result = try await transport.invoke(
            LoopbackFixtures.invocation(),
            intake: BoundedChannelState<ProviderResponse>(itemCap: 8, byteCap: 1 << 20))
        return (transport, collector, result.rawBody ?? [])
    }

    // MARK: Bounded raw provider ring

    @Test("WIRE-08 raw provider ring stays bounded and native")
    func rawProviderRingBounded() async throws {
        let server = try LoopbackSSEServer()
        for index in 0..<9 {
            server.enqueue(SSEScript(chunks: [
                ScriptChunk(bytes: Array(CannedTurn.text("ring-\(index)").utf8), delayMillis: 0)
            ]))
        }
        server.start()
        defer { server.stop() }

        let chat: ChatCompletionsTransport = try LoopbackFixtures.transport(server: server).0
        let snapshot = try LoopbackFixtures.snapshot(alias: "loop", baseURL: server.baseURL)
        defer { await LoopbackFixtures.shutdown(chat.client) }
        let actor = AuthorizedActor(
            state: try ActorLoopback.idleState(snapshot: snapshot),
            ids: DeterministicIDSource(prefix: "ring"), clock: VirtualClock(now: 7_000_000),
            transport: chat, executor: TrivialExecutor(),
            store: InMemorySessionStore(), approvals: TrivialApprovals())

        for index in 0..<9 {
            await actor.submitText(
                commandID: CommandID("ring-\(index)"), text: "record \(index)",
                kind: .followUp, sealed: false)
            _ = try await spin(actor, "completed-\(index)")
        }

        let ring = await actor.rawRecords
        #expect(ring.count == 8, "ring count bound dominates, evicting oldest")
        #expect(ring.contains { String(decoding: $0.rawBody, as: UTF8.self).contains("ring-8") })
        #expect(!ring.contains { String(decoding: $0.rawBody, as: UTF8.self).contains("ring-0") })
        #expect(ring.allSatisfy { !$0.rawBody.isEmpty }, "ring is native provider bytes")
        #expect(server.requests.count == 9, "nine provider attempts produced the bound")
    }

    @Test("WIRE-08 H1: concurrent sink emits preserve ordering and terminal-last")
    func h1ConcurrentSinkOrdering() async throws {
        let sink = InMemoryUISink(sessionID: "h1-concurrency")
        await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    try await sink.emit(.delta(
                        requestID: RequestID("r-\(index)"), text: "fragment-\(index)"))
                }
            }
        }
        try await sink.emit(.runFinished(outcome: "completed", detail: "turns=1"))
        let envelopes = try sink.allLines.map { line in
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        }
        let seqs = envelopes.compactMap { $0["seq"] as? Int }
        #expect(seqs == Array(1...101), "sequence is contiguous under forced concurrency")
        #expect(envelopes.last?["kind"] as? String == "run_finished", "terminal event last")
        #expect(envelopes.allSatisfy { (try? JSONSerialization.data(withJSONObject: $0)) != nil }, "all envelopes are valid JSON")
    }
}
