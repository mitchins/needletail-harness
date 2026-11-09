import Testing
import Foundation
import NeedletailCore
import NeedletailRuntime
import NeedletailTestSupport
@testable import NeedletailCLI
@testable import NeedletailTerminal
@testable import NeedletailLineEditor

/// M4-D D1 composition tests: the SHARED `ChatCommand.compose` factory
/// (the same root the `chat` binary uses) against the loopback SSE
/// server. No live model traffic, no timing assumptions — all waits
/// are marker-based with loud bounds. Serialized: tests mutate
/// process environment (NEEDLETAIL_STATE_DIR, credential env).
@Suite(.serialized)
struct ChatCompositionTests {
    private static let keyName = ChatLoopback.credentialEnv
    private static let keyValue = ChatLoopback.credentialValue

    private struct Env {
        let stateDir: URL
        let configPath: String
        let server: LoopbackSSEServer
        let written: LockedText
        let oldStateDir: String?
        let oldKey: String?
    }

    final class LockedText: @unchecked Sendable {
        private let lock = NSLock()
        private var parts: [String] = []
        func append(_ s: String) { lock.withLock { parts.append(s) } }
        func joined() -> String { lock.withLock { parts.joined() } }
    }

    private func makeEnv(tools: String, workspace: URL? = nil) throws -> Env {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-comp-\(UUID().uuidString)")
        let stateDir = base.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let server = try LoopbackSSEServer()
        server.start()
        let oldStateDir = getenv("NEEDLETAIL_STATE_DIR").map { String(cString: $0) }
        let oldKey = getenv(Self.keyName).map { String(cString: $0) }
        setenv("NEEDLETAIL_STATE_DIR", stateDir.path, 1)
        setenv(Self.keyName, Self.keyValue, 1)
        let configPath = base.appendingPathComponent("config.json").path
        let template = """
            {"version":1,"default_model":"loop","allow_http_origins":["ORIGIN"],"models":[{"alias":"loop","protocol":"openai-chat-completions","base_url":"BASE","model":"test-model","context_window":4096,"max_output":128,"locality":"local","credential":{"env":"KEY"},"connect_timeout_s":5,"read_idle_timeout_s":300,"request_timeout_s":300,"max_in_flight":1}],"tools":TOOLS}
            """
        let origin = try parseBaseURL(server.baseURL, path: "$").origin
        let text = template
            .replacingOccurrences(of: "ORIGIN", with: origin)
            .replacingOccurrences(of: "BASE", with: server.baseURL)
            .replacingOccurrences(of: "KEY", with: Self.keyName)
            .replacingOccurrences(of: "TOOLS", with: tools)
        try Data(text.utf8).write(to: URL(fileURLWithPath: configPath))
        _ = workspace // threaded by the caller into compose, not the env
        return Env(
            stateDir: stateDir, configPath: configPath, server: server,
            written: LockedText(), oldStateDir: oldStateDir, oldKey: oldKey)
    }

    private func tearDown(_ env: Env) {
        env.server.stop()
        if let old = env.oldStateDir { setenv("NEEDLETAIL_STATE_DIR", old, 1) } else { unsetenv("NEEDLETAIL_STATE_DIR") }
        if let old = env.oldKey { setenv(Self.keyName, old, 1) } else { unsetenv(Self.keyName) }
        try? FileManager.default.removeItem(at: env.stateDir.deletingLastPathComponent())
    }

    private func waitUntil(_ env: Env, _ marker: String, timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if env.written.joined().contains(marker) { return true }
            usleep(10_000)
        }
        return false
    }

    private func finishRun(_ session: ChatCommand.ComposedSession, task: Task<Void, Never>) async {
        session.loop.post(.inputLine(nil))
        await task.value
    }

    /// The loop drops posts before its inbox exists; the first render
    /// (status line) is the deterministic readiness signal.
    private func requireReady(_ env: Env, _ session: ChatCommand.ComposedSession, task: Task<Void, Never>) async -> Bool {
        guard waitUntil(env, "idle") else {
            Issue.record("loop never rendered initial frame; tail: \(env.written.joined().suffix(300))")
            session.loop.post(.inputLine(nil))
            await task.value
            return false
        }
        return true
    }

    private func requireBearer(_ env: Env) {
        if let violation = ChatLoopback.bearerViolation(server: env.server, expected: Self.keyValue) {
            let dump = env.server.requests.map { "\($0.method) \($0.path) headers=\($0.headers)" }.joined(separator: " | ")
            Issue.record("credential composition broken: \(violation) :: \(dump)")
        }
    }

    private func requireStoreClean(_ session: ChatCommand.ComposedSession) async throws {
        let (records, _) = try session.store.records(session: session.sessionID, since: 0, limit: 10_000)
        let report = try session.store.reconcile(session: session.sessionID)
        #expect(report.heldOperations.isEmpty, "store holds operations: \(report.heldOperations.count)")
        #expect(report.unmatchedMutating.isEmpty, "unmatched mutating records")
        #expect(report.explicitUnknown.isEmpty, "explicit unknown outcomes left")
        #expect(!records.isEmpty, "session must have durable records")
    }

    @Test("D1 text turn streams incrementally through the shared factory (scripted backend)")
    func textTurnStreams() async throws {
        let env = try makeEnv(tools: #"{"read":false,"search":false,"edit":false,"write":false,"exec":false,"consult":false}"#)
        defer { tearDown(env) }
        // Gate after the first content chunk: while withheld, the turn
        // must be recognizably IN FLIGHT (provider request open, no
        // committed text) — progress text itself is suppressed in the
        // plain test caps, so in-flight state is the oracle here; the
        // incremental delta delivery itself is proven by
        // actorDeltaReachesTrace against the trace sink.
        env.server.enqueue(ChatLoopback.textTurn("hello world from loopback", splits: 3, gateAfter: 1, gateName: "s1"))
        let session = try await ChatCommand.compose(
            config: env.configPath, trace: nil, alias: nil, maxTurns: 10,
            allowExec: false, workspace: nil, readRoot: [],
            sandboxGrant: nil, acknowledgedDetermination: nil,
            writer: { env.written.append($0) })
        let task = Task { await session.run(scriptedInput: []) }
        guard await requireReady(env, session, task: task) else { return }
        session.loop.post(.inputLine("say hi"))
        #expect(env.server.waitUntilGateArmed("s1", timeout: 20), "gate never armed — stream may have finished before the turn")
        #expect(env.server.requests.count == 1, "provider request must be open while the gate holds")
        #expect(!env.written.joined().contains("hello world from loopback"), "full text must not render before the gate releases")
        env.server.releaseGate("s1")
        #expect(waitUntil(env, "hello world from loopback"), "streamed text never rendered; tail: \(env.written.joined().suffix(400))")
        await finishRun(session, task: task)
        requireBearer(env)
        #expect(env.server.requests.count == 1, "expected exactly one provider request, got \(env.server.requests.count)")
        try await requireStoreClean(session)
    }

    @Test("D1 trusted read fast-path renders receipt without approval (native backend)")
    func trustedReadReceipt() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "workspace file bytes".write(to: base.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        let env = try makeEnv(tools: #"{"read":true,"search":true,"edit":false,"write":false,"exec":false,"consult":false}"#)
        defer { tearDown(env) }
        env.server.enqueue(ChatLoopback.toolTurn(name: "read", arguments: #"{"path":"hello.txt"}"#, prefixText: "reading:"))
        env.server.enqueue(ChatLoopback.textTurn("done"))
        let session = try await ChatCommand.compose(
            config: env.configPath, trace: nil, alias: nil, maxTurns: 10,
            allowExec: false, workspace: base.path, readRoot: [],
            sandboxGrant: nil, acknowledgedDetermination: nil,
            writer: { env.written.append($0) })
        let task = Task { await session.run(scriptedInput: []) }
        guard await requireReady(env, session, task: task) else { return }
        session.loop.post(.inputLine("read the file"))
        // Qualified Core contract: non-mutating reads in workspace mode
        // auto-execute via dispatchTrustedBatch (batchNeedsApproval ==
        // false) — NO approval prompt. D2.4 turn-finished display renders
        // the transcript tool message verbatim in scrollback.
        #expect(waitUntil(env, "tool result"), "tool result never displayed; tail: \(env.written.joined().suffix(500))")
        #expect(env.written.joined().contains("workspace file bytes"), "tool payload missing from display")
        #expect(!env.written.joined().contains("approval required:"), "trusted read must not prompt")
        await finishRun(session, task: task)
        requireBearer(env)
        #expect(env.server.requests.count == 2, "expected tool turn + follow-up, got \(env.server.requests.count)")
        let followup = String(decoding: env.server.requests[1].body, as: UTF8.self)
        #expect(followup.contains("workspace file bytes"), "tool receipt bytes must reach the provider")
        try await requireStoreClean(session)
    }

    @Test("D1 mutating write renders approval with identity; y approves; receipt renders")
    func toolApprovalAndReceipt() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let env = try makeEnv(tools: #"{"read":true,"search":true,"edit":false,"write":true,"exec":false,"consult":false}"#)
        defer { tearDown(env) }
        env.server.enqueue(ChatLoopback.toolTurn(name: "write", arguments: #"{"path":"note.txt","content":"written bytes"}"#, prefixText: "writing:"))
        env.server.enqueue(ChatLoopback.textTurn("done"))
        let session = try await ChatCommand.compose(
            config: env.configPath, trace: nil, alias: nil, maxTurns: 10,
            allowExec: false, workspace: base.path, readRoot: [],
            sandboxGrant: nil, acknowledgedDetermination: nil,
            writer: { env.written.append($0) })
        let task = Task { await session.run(scriptedInput: []) }
        guard await requireReady(env, session, task: task) else { return }
        session.loop.post(.inputLine("write the file"))
        #expect(waitUntil(env, "approval required:"), "approval prompt never rendered; tail: \(env.written.joined().suffix(500))")
        #expect(env.written.joined().contains("note.txt"), "approval must show the requested path")
        session.loop.post(.inputLine("y"))
        // Scrollback receipt display (D2.4): the transcript tool message
        // renders verbatim after the turn finishes. (Oracle keys on the
        // hook's "tool result" prefix: the raw arguments also contain the
        // payload bytes via the approval prompt.)
        #expect(waitUntil(env, "tool result"), "tool result never displayed; tail: \(env.written.joined().suffix(500))")
        #expect(env.written.joined().contains("written bytes"), "tool payload missing from display")
        #expect((try? String(contentsOf: base.appendingPathComponent("note.txt"), encoding: .utf8)) == "written bytes", "native write must land")
        await finishRun(session, task: task)
        requireBearer(env)
        #expect(env.server.requests.count >= 1, "provider must have been invoked")
        try await requireStoreClean(session)
    }

    @Test("D1 busy submit queues the follow-up; gated stream proves mid-stream injection; no auto-send")
    func busySubmitQueues() async throws {
        let env = try makeEnv(tools: #"{"read":false,"search":false,"edit":false,"write":false,"exec":false,"consult":false}"#)
        defer { tearDown(env) }
        // First turn holds at its first content chunk; the second turn
        // is a plain text turn served after release.
        env.server.enqueue(ChatLoopback.textTurn("first-turn-streaming", splits: 2, gateAfter: 0, gateName: "t1"))
        env.server.enqueue(ChatLoopback.textTurn("second-turn-answer", splits: 1))
        let session = try await ChatCommand.compose(
            config: env.configPath, trace: nil, alias: nil, maxTurns: 10,
            allowExec: false, workspace: nil, readRoot: [],
            sandboxGrant: nil, acknowledgedDetermination: nil,
            writer: { env.written.append($0) })
        let task = Task { await session.run(scriptedInput: []) }
        guard await requireReady(env, session, task: task) else { return }
        session.loop.post(.inputLine("first"))
        // Wait until the provider request is in flight AND the server is
        // withholding the gated chunk: anything injected now is
        // provably mid-stream (non-vacuous concurrency proof).
        #expect(env.server.waitUntilGateArmed("t1", timeout: 20), "loopback gate never armed — stream may have finished before injection")
        session.loop.post(.inputLine("second"))
        // The follow-up must queue, never send during the busy turn:
        // only one provider request exists while the gate holds.
        usleep(300_000)
        #expect(env.server.requests.count == 1, "follow-up auto-sent during busy turn: \(env.server.requests.count) requests")
        env.server.releaseGate("t1")
        #expect(waitUntil(env, "second-turn-answer"), "queued follow-up never dispatched; tail: \(env.written.joined().suffix(400))")
        await finishRun(session, task: task)
        requireBearer(env)
        #expect(env.server.requests.count == 2, "expected two provider requests, got \(env.server.requests.count)")
        try await requireStoreClean(session)
    }

    @Test("D2 resubmission: two explicit identical submits mint distinct command IDs and admit twice; same-ID retry replays")
    func identicalTextResubmitsAdmitTwice() async throws {
        let env = try makeEnv(tools: #"{"read":false,"search":false,"edit":false,"write":false,"exec":false,"consult":false}"#)
        defer { tearDown(env) }
        env.server.enqueue(ChatLoopback.textTurn("first identical answer", splits: 1))
        env.server.enqueue(ChatLoopback.textTurn("second identical answer", splits: 1))
        let session = try await ChatCommand.compose(
            config: env.configPath, trace: nil, alias: nil, maxTurns: 10,
            allowExec: false, workspace: nil, readRoot: [],
            sandboxGrant: nil, acknowledgedDetermination: nil,
            writer: { env.written.append($0) })
        let task = Task { await session.run(scriptedInput: []) }
        guard await requireReady(env, session, task: task) else { return }
        // Two EXPLICIT submissions (two Enter events) carrying
        // byte-identical text. The edge must mint a fresh command ID per
        // submission event: reusing the ID makes Core admission
        // idempotency replay the prior admission without dispatching —
        // a silent no-op (M4-D residual).
        session.loop.post(.inputLine("same question twice"))
        #expect(waitUntil(env, "first identical answer"), "first turn never rendered; tail: \(env.written.joined().suffix(400))")
        session.loop.post(.inputLine("same question twice"))
        #expect(waitUntil(env, "second identical answer"), "identical resubmit never dispatched — silent no-op; tail: \(env.written.joined().suffix(400))")
        let admitted = await session.actor.currentState().admittedCommands
        #expect(admitted.count >= 2, "two genuine admissions expected, got \(admitted.count)")
        #expect(Set(admitted.keys).count == admitted.count, "command IDs must be distinct per submission event")
        // Same-ID retry through the same actor replays the recorded ack
        // and dispatches nothing new (Core admission contract, preserved).
        guard let replayID = admitted.keys.first else {
            Issue.record("no admitted command to retry")
            await finishRun(session, task: task)
            return
        }
        let ackBefore = admitted[replayID]
        await session.actor.submitText(commandID: replayID, text: "same question twice", kind: .followUp, sealed: false)
        let admittedAfter = await session.actor.currentState().admittedCommands
        #expect(admittedAfter[replayID] == ackBefore, "retry must replay the identical ack")
        await finishRun(session, task: task)
        requireBearer(env)
        #expect(env.server.requests.count == 2, "expected exactly two provider requests (no drop, no double), got \(env.server.requests.count)")
        let bodies = env.server.requests.map { String(decoding: $0.body, as: UTF8.self) }
        #expect(bodies.allSatisfy { $0.contains("same question twice") }, "both turns must carry the submitted text")
        try await requireStoreClean(session)
    }

    @Test("D1 cancel during a busy turn holds the queue; EOF exits cleanly")
    func cancelHoldsQueue() async throws {        let env = try makeEnv(tools: #"{"read":false,"search":false,"edit":false,"write":false,"exec":false,"consult":false}"#)
        defer { tearDown(env) }
        env.server.enqueue(ChatLoopback.textTurn("slow-first-turn", splits: 2, gateAfter: 0, gateName: "c1"))
        env.server.enqueue(ChatLoopback.textTurn("after-resume", splits: 1))
        env.server.enqueue(ChatLoopback.textTurn("nudge-answer", splits: 1))
        let session = try await ChatCommand.compose(
            config: env.configPath, trace: nil, alias: nil, maxTurns: 10,
            allowExec: false, workspace: nil, readRoot: [],
            sandboxGrant: nil, acknowledgedDetermination: nil,
            writer: { env.written.append($0) })
        let task = Task { await session.run(scriptedInput: []) }
        guard await requireReady(env, session, task: task) else { return }
        session.loop.post(.inputLine("first"))
        #expect(env.server.waitUntilGateArmed("c1", timeout: 20), "gate never armed")
        session.loop.post(.inputLine("queued-while-busy"))
        usleep(300_000)
        // Cancel through the LOOP key path (busy Ctrl+C): exercises the
        // decided-cancel event end to end, not just the actor authority.
        session.loop.post(.key(.ctrlC))
        // Cancel grace is timer-driven (cancelGraceMillis): the run must
        // reach its terminal interrupted phase before resume, else resume
        // is refused/blocked (qualified QUEUE-07 semantics). State-based
        // wait, not a sleep.
        let terminated: Bool = await {
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline {
                let state = await session.actor.currentState()
                if case .interrupted = state.phase { return true }
                usleep(50_000)
            }
            return false
        }()
        #expect(terminated, "cancelled run never reached interrupted")
        // Resume explicitly through the actor authority (the `/queue
        // resume` slash leg is a D2 wiring item; the authority the
        // edge will call is exercised here): resume only UNHOLDS
        // (qualified semantics) — the next submit dispatches the head
        // first (FIFO), never automatically before that.
        await session.actor.resumeQueue()
        env.server.releaseGate("c1")
        session.loop.post(.inputLine("nudge"))
        #expect(waitUntil(env, "after-resume"), "queue never resumed; tail: \(env.written.joined().suffix(400))")
        await finishRun(session, task: task)
        requireBearer(env)
        try await requireStoreClean(session)
    }

    private func withRequestBudget(_ value: String?, _ body: () async throws -> Void) async rethrows {
        let old = getenv("NEEDLETAIL_REQUEST_BUDGET").map { String(cString: $0) }
        if let value { setenv("NEEDLETAIL_REQUEST_BUDGET", value, 1) } else { unsetenv("NEEDLETAIL_REQUEST_BUDGET") }
        defer {
            if let old { setenv("NEEDLETAIL_REQUEST_BUDGET", old, 1) } else { unsetenv("NEEDLETAIL_REQUEST_BUDGET") }
        }
        try await body()
    }

    @Test("D2.6 budget exhaustion refuses new submits and holds the queue; startup line visible")
    func budgetExhaustionRefuses() async throws {
        try await withRequestBudget("1") {
            let env = try makeEnv(tools: #"{"read":false,"search":false,"edit":false,"write":false,"exec":false,"consult":false}"#)
            defer { tearDown(env) }
            env.server.enqueue(ChatLoopback.textTurn("first answer", splits: 1))
            env.server.enqueue(ChatLoopback.textTurn("must never send", splits: 1))
            let session = try await ChatCommand.compose(
                config: env.configPath, trace: nil, alias: nil, maxTurns: 10,
                allowExec: false, workspace: nil, readRoot: [],
                sandboxGrant: nil, acknowledgedDetermination: nil,
                writer: { env.written.append($0) })
            let task = Task { await session.run(scriptedInput: []) }
            guard await requireReady(env, session, task: task) else { return }
            #expect(env.written.joined().contains("limit=1"), "startup budget line must show the configured limit")
            session.loop.post(.inputLine("first"))
            #expect(waitUntil(env, "first answer"), "first turn never completed; tail: \(env.written.joined().suffix(300))")
            // Second submit: translate-level refusal (no consume, no
            // dispatch) with an explicit held-queue notice.
            session.loop.post(.inputLine("second"))
            #expect(waitUntil(env, "budget exhausted"), "refusal notice missing; tail: \(env.written.joined().suffix(300))")
            // The refused turn must never reach the provider.
            usleep(300_000)
            #expect(env.server.requests.count == 1, "exhausted budget sent provider traffic: \(env.server.requests.count)")
            await finishRun(session, task: task)
            requireBearer(env)
            try await requireStoreClean(session)
        }
    }

    @Test("D2.6 budget exhaustion is sticky per state dir across invocations")
    func budgetStickyAcrossSessions() async throws {        try await withRequestBudget("1") {
            let env = try makeEnv(tools: #"{"read":false,"search":false,"edit":false,"write":false,"exec":false,"consult":false}"#)
            defer { tearDown(env) }
            env.server.enqueue(ChatLoopback.textTurn("only answer", splits: 1))
            // Session A consumes the single unit.
            let first = try await ChatCommand.compose(
                config: env.configPath, trace: nil, alias: nil, maxTurns: 10,
                allowExec: false, workspace: nil, readRoot: [],
                sandboxGrant: nil, acknowledgedDetermination: nil,
                writer: { env.written.append($0) })
            let taskA = Task { await first.run(scriptedInput: []) }
            guard await requireReady(env, first, task: taskA) else { return }
            first.loop.post(.inputLine("go"))
            #expect(waitUntil(env, "only answer"), "first session never completed")
            await finishRun(first, task: taskA)
            // Session B shares the state dir: the counter persists, so
            // the very first submit refuses without provider traffic.
            // Fresh output box: readiness must gate on THIS session's
            // frame (the shared box carries session A's stale "idle").
            let writtenB = LockedText()
            let second = try await ChatCommand.compose(
                config: env.configPath, trace: nil, alias: nil, maxTurns: 10,
                allowExec: false, workspace: nil, readRoot: [],
                sandboxGrant: nil, acknowledgedDetermination: nil,
                writer: { writtenB.append($0) })
            let taskB = Task { await second.run(scriptedInput: []) }
            let readyB: Bool = {
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline {
                    if writtenB.joined().contains("idle") { return true }
                    usleep(10_000)
                }
                return false
            }()
            guard readyB else { Issue.record("session B never rendered"); return }
            second.loop.post(.inputLine("go again"))
            let refused: Bool = {
                let deadline = Date().addingTimeInterval(20)
                while Date() < deadline {
                    if writtenB.joined().contains("budget exhausted") { return true }
                    usleep(10_000)
                }
                return false
            }()
            #expect(refused, "sticky exhaustion not refused; tail: \(writtenB.joined().suffix(300))")
            usleep(300_000)
            #expect(env.server.requests.count == 1, "second session sent provider traffic on an exhausted budget")
            await finishRun(second, task: taskB)
            requireBearer(env)
        }
    }

    private func waitForAccept(_ session: ChatCommand.ComposedSession, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if session.loop.acceptSnapshot() != nil { return true }
            usleep(10_000)
        }
        return false
    }

    @Test("D2.1 @-mention Tab-accept captures the file fd-pinned at submit (native backend)")
    func mentionAttachCaptures() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "attach me bytes".write(to: base.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        let env = try makeEnv(tools: #"{"read":true,"search":true,"edit":false,"write":false,"exec":false,"consult":false}"#)
        defer { tearDown(env) }
        // Turn 1 answers the mention submit; turn 2 proves the token
        // cleared (no re-attach).
        env.server.enqueue(ChatLoopback.textTurn("first answer", splits: 1))
        env.server.enqueue(ChatLoopback.textTurn("second answer", splits: 1))
        let session = try await ChatCommand.compose(
            config: env.configPath, trace: nil, alias: nil, maxTurns: 10,
            allowExec: false, workspace: base.path, readRoot: [],
            sandboxGrant: nil, acknowledgedDetermination: nil,
            writer: { env.written.append($0) })
        let task = Task { await session.run(scriptedInput: []) }
        guard await requireReady(env, session, task: task) else { return }
        // Type the query: the edge fetch finds hello.txt in the
        // workspace (suggestion fills via the completions event).
        session.loop.post(.mirror(text: "@he", cursor: 3))
        #expect(waitForAccept(session), "suggestion never filled for @he")
        // Tab-accept through the shared gate, then submit the accepted
        // buffer text (production Enter submits the mirrored buffer).
        guard let accepted = session.loop.acceptSnapshot() else {
            Issue.record("accept gate closed"); session.loop.post(.inputLine(nil)); await task.value; return
        }
        session.loop.post(.tabAccept(base: accepted.base, display: accepted.display, cursor: accepted.cursor))
        session.loop.post(.inputLine(accepted.display))
        #expect(waitUntil(env, "first answer"), "mention turn never completed; tail: \(env.written.joined().suffix(400))")
        // The fd-pinned capture rides the provider request as attachment
        // context (byte-exact excerpt, hash-verified at capture).
        #expect(env.server.requests.count >= 1, "provider never invoked")
        let firstBody = String(decoding: env.server.requests[0].body, as: UTF8.self)
        #expect(firstBody.contains("attach me bytes"), "captured file bytes missing from provider context")
        // Second submit completes (token clearing itself is qualified
        // reducer behavior — M4-B "submit clears tokens"; turn 2's
        // request legitimately carries turn 1's history bytes).
        session.loop.post(.inputLine("plain follow-up"))
        #expect(waitUntil(env, "second answer"), "follow-up never completed")
        await finishRun(session, task: task)
        requireBearer(env)
        #expect(env.server.requests.count == 2, "expected exactly two provider requests")
        try await requireStoreClean(session)
    }

    @Test("D2.1 missing file at submit refuses the turn (fail-closed, no partial admission)")
    func mentionAttachMissingRefuses() async throws {        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "original bytes".write(to: base.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        let env = try makeEnv(tools: #"{"read":true,"search":true,"edit":false,"write":false,"exec":false,"consult":false}"#)
        defer { tearDown(env) }
        env.server.enqueue(ChatLoopback.textTurn("must never send", splits: 1))
        let session = try await ChatCommand.compose(
            config: env.configPath, trace: nil, alias: nil, maxTurns: 10,
            allowExec: false, workspace: base.path, readRoot: [],
            sandboxGrant: nil, acknowledgedDetermination: nil,
            writer: { env.written.append($0) })
        let task = Task { await session.run(scriptedInput: []) }
        guard await requireReady(env, session, task: task) else { return }
        session.loop.post(.mirror(text: "@he", cursor: 3))
        #expect(waitForAccept(session), "suggestion never filled for @he")
        guard let accepted = session.loop.acceptSnapshot() else {
            Issue.record("accept gate closed"); session.loop.post(.inputLine(nil)); await task.value; return
        }
        session.loop.post(.tabAccept(base: accepted.base, display: accepted.display, cursor: accepted.cursor))
        // Delete the file between accept and submit: the fd-pinned
        // capture at submit must refuse (missing reference), withholding
        // the turn — never partial admission, never silent loss.
        try FileManager.default.removeItem(at: base.appendingPathComponent("hello.txt"))
        session.loop.post(.inputLine(accepted.display))
        #expect(waitUntil(env, "attach refused"), "missing file must refuse with a specific notice; tail: \(env.written.joined().suffix(400))")
        usleep(300_000)
        #expect(env.server.requests.isEmpty, "refused submit must never reach the provider")
        await finishRun(session, task: task)
    }
}

extension ChatCompositionTests {
    @Test("D2 undo preview + explicit run restores the file through the native authority")
    func undoPreviewAndRun() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "original bytes".write(to: base.appendingPathComponent("target.txt"), atomically: true, encoding: .utf8)
        let env = try makeEnv(tools: #"{"read":true,"search":true,"edit":true,"write":false,"exec":false,"consult":false}"#)
        defer { tearDown(env) }
        // edit replaces exact bytes under an authorized hash: sha256 of
        // "original bytes" (no trailing newline), precomputed. A hash
        // mismatch fails the edit loudly (no silent write).
        let originalHash = "52c3935626c104b2cbc9031291a1c4d56614c38f52072a361d658a58a9c48698"
        env.server.enqueue(ChatLoopback.toolTurn(name: "edit", arguments: #"{"path":"target.txt","expectedHash":"\#(originalHash)","old_string":"original bytes","new_string":"changed bytes"}"#, prefixText: "editing:"))
        env.server.enqueue(ChatLoopback.textTurn("changed done", splits: 1))
        env.server.enqueue(ChatLoopback.textTurn("undone", splits: 1))
        let session = try await ChatCommand.compose(
            config: env.configPath, trace: nil, alias: nil, maxTurns: 10,
            allowExec: false, workspace: base.path, readRoot: [],
            sandboxGrant: nil, acknowledgedDetermination: nil,
            writer: { env.written.append($0) })
        let task = Task { await session.run(scriptedInput: []) }
        guard await requireReady(env, session, task: task) else { return }
        session.loop.post(.inputLine("change the file"))
        #expect(waitUntil(env, "approval required:"), "approval never rendered")
        session.loop.post(.inputLine("y"))
        #expect(waitUntil(env, "changed done"), "write turn never completed")
        #expect((try? String(contentsOf: base.appendingPathComponent("target.txt"), encoding: .utf8)) == "changed bytes", "native write must land")
        // Resolve the group from the durable ledger (same source as the edge).
        let (stored, _) = try session.store.records(session: session.sessionID, since: 0, limit: 10_000)
        let groups = reconcileChangeGroups(stored.map(\.record))
        #expect(!groups.isEmpty, "write must record a change group")
        guard let gid = groups.last?.groupID else {
            session.loop.post(.inputLine(nil)); await task.value; return
        }
        // Run without preview refuses (read before mutate).
        session.loop.post(.inputLine("/undo run \(gid)"))
        #expect(waitUntil(env, "preview group \(gid) first"), "unpreviewed run must refuse; tail: \(env.written.joined().suffix(300))")
        // Bare `/undo` previews the latest eligible group (read-only;
        // oracle keys on the eligible-preview notice — hashes wrap).
        session.loop.post(.inputLine("/undo"))
        #expect(waitUntil(env, "eligible, no mutation"), "bare /undo must preview the latest group; tail: \(env.written.joined().suffix(400))")
        // Explicit `/undo run <group>` executes through Core approval +
        // verification (idempotent by undo command ID).
        session.loop.post(.inputLine("/undo run \(gid)"))
        #expect(waitUntil(env, "dispatched for group \(gid)"), "run dispatch never acknowledged")
        let restored: Bool = {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if (try? String(contentsOf: base.appendingPathComponent("target.txt"), encoding: .utf8)) == "original bytes" { return true }
                usleep(50_000)
            }
            return false
        }()
        #expect(restored, "undo run must restore the file")
        await finishRun(session, task: task)
        requireBearer(env)
        try await requireStoreClean(session)
    }

    @Test("D2 /preview renders bounded file text; escaping paths refused")
    func previewSlash() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "preview me bytes".write(to: base.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        let env = try makeEnv(tools: #"{"read":false,"search":false,"edit":false,"write":false,"exec":false,"consult":false}"#)
        defer { tearDown(env) }
        let session = try await ChatCommand.compose(
            config: env.configPath, trace: nil, alias: nil, maxTurns: 10,
            allowExec: false, workspace: base.path, readRoot: [],
            sandboxGrant: nil, acknowledgedDetermination: nil,
            writer: { env.written.append($0) })
        let task = Task { await session.run(scriptedInput: []) }
        guard await requireReady(env, session, task: task) else { return }
        session.loop.post(.inputLine("/preview @hello.txt"))
        #expect(waitUntil(env, "preview me bytes"), "/preview must render bounded text; tail: \(env.written.joined().suffix(300))")
        session.loop.post(.inputLine("/preview /etc/hostname"))
        #expect(waitUntil(env, "preview refused: path escapes the pinned roots: /etc/hostname"), "absolute path must refuse")
        session.loop.post(.inputLine("/preview ../outside.txt"))
        #expect(waitUntil(env, "preview refused: path escapes the pinned roots: ../outside.txt"), "dot-dot path must refuse")
        await finishRun(session, task: task)
    }

    @Test("D2 /queue resume slash unholds; next submit dispatches head first (FIFO)")
    func queueResumeSlash() async throws {
        let env = try makeEnv(tools: #"{"read":false,"search":false,"edit":false,"write":false,"exec":false,"consult":false}"#)
        defer { tearDown(env) }
        env.server.enqueue(ChatLoopback.textTurn("slow-first-turn", splits: 2, gateAfter: 0, gateName: "q1"))
        env.server.enqueue(ChatLoopback.textTurn("after-resume", splits: 1))
        env.server.enqueue(ChatLoopback.textTurn("nudge-answer", splits: 1))
        let session = try await ChatCommand.compose(
            config: env.configPath, trace: nil, alias: nil, maxTurns: 10,
            allowExec: false, workspace: nil, readRoot: [],
            sandboxGrant: nil, acknowledgedDetermination: nil,
            writer: { env.written.append($0) })
        let task = Task { await session.run(scriptedInput: []) }
        guard await requireReady(env, session, task: task) else { return }
        session.loop.post(.inputLine("first"))
        #expect(env.server.waitUntilGateArmed("q1", timeout: 20), "gate never armed")
        session.loop.post(.inputLine("queued-while-busy"))
        usleep(300_000)
        await session.cancel()
        let terminated: Bool = await {
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline {
                let state = await session.actor.currentState()
                if case .interrupted = state.phase { return true }
                usleep(50_000)
            }
            return false
        }()
        #expect(terminated, "cancelled run never reached interrupted")
        // Slash-level resume (the D2-wired leg): unholds, then the next
        // submit dispatches the head first — never automatically.
        session.loop.post(.inputLine("/queue resume"))
        env.server.releaseGate("q1")
        session.loop.post(.inputLine("nudge"))
        #expect(waitUntil(env, "after-resume"), "slash resume never dispatched the head; tail: \(env.written.joined().suffix(400))")
        await finishRun(session, task: task)
        requireBearer(env)
        try await requireStoreClean(session)
    }
}

extension ChatCompositionTests {
    @Test("D2 inspect legs render through the qualified frame (no network, no fabrication)")
    func inspectLegs() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-inspect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let env = try makeEnv(tools: #"{"read":false,"search":false,"edit":false,"write":false,"exec":false,"consult":false}"#)
        defer { tearDown(env) }
        let session = try await ChatCommand.compose(
            config: env.configPath, trace: nil, alias: nil, maxTurns: 10,
            allowExec: false, workspace: base.path, readRoot: [],
            sandboxGrant: nil, acknowledgedDetermination: nil,
            writer: { env.written.append($0) })
        let task = Task { await session.run(scriptedInput: []) }
        guard await requireReady(env, session, task: task) else { return }
        // /models: complete from the validated snapshot (alias + kind).
        session.loop.post(.inputLine("/models"))
        #expect(waitUntil(env, "loop [local]"), "/models must list the loopback route; tail: \(env.written.joined().suffix(300))")
        // /sessions: the live session renders with its route.
        session.loop.post(.inputLine("/sessions"))
        #expect(waitUntil(env, session.sessionID.raw), "/sessions must list the live session")
        // /context: estimated totals with unknown cache (never exact).
        session.loop.post(.inputLine("/context"))
        #expect(waitUntil(env, "cache unknown"), "/context must label cache unknown")
        // /epochs: lineage from the durable log.
        session.loop.post(.inputLine("/epochs"))
        #expect(waitUntil(env, "epoch-chat-"), "/epochs must list the live epoch")
        // /compact: dry-run estimate, zero provider calls.
        session.loop.post(.inputLine("/compact"))
        #expect(waitUntil(env, "dry-run only"), "/compact must show the dry-run note")
        await finishRun(session, task: task)
        // All legs are local reads: zero provider traffic expected
        // (offline inspection — the point of the exercise).
        #expect(env.server.requests.isEmpty, "inspect legs must not touch the provider")
    }

    @Test("D2 /diff renders bounded hunks with mixed provenance (no authorship claim)")
    func diffLeg() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        func git(_ args: String...) throws {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            proc.arguments = args
            proc.currentDirectoryURL = base
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { throw TestSkip.gitUnavailable }
        }
        do {
            try git("init", "-q")
            try git("config", "user.email", "t@t.t")
            try git("config", "user.name", "t")
            try "line one\n".write(to: base.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
            try git("add", "f.txt")
            try git("commit", "-qm", "base")
            try "line one\nline two\n".write(to: base.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        } catch {
            Issue.record("git fixture setup failed (git required for the /diff leg): \(error)")
            return
        }
        let env = try makeEnv(tools: #"{"read":false,"search":false,"edit":false,"write":false,"exec":false,"consult":false}"#)
        defer { tearDown(env) }
        let session = try await ChatCommand.compose(
            config: env.configPath, trace: nil, alias: nil, maxTurns: 10,
            allowExec: false, workspace: base.path, readRoot: [],
            sandboxGrant: nil, acknowledgedDetermination: nil,
            writer: { env.written.append($0) })
        let task = Task { await session.run(scriptedInput: []) }
        guard await requireReady(env, session, task: task) else { return }
        session.loop.post(.inputLine("/diff"))
        #expect(waitUntil(env, "line two"), "/diff must render the unstaged hunk; tail: \(env.written.joined().suffix(400))")
        await finishRun(session, task: task)
    }

    enum TestSkip: Error {
        case gitUnavailable
    }
}

extension ChatCompositionTests {
    @Test("D1 actor delta pipeline reaches the trace sink while gated (streaming wiring proof)")
    func actorDeltaReachesTrace() async throws {
        let env = try makeEnv(tools: #"{"read":false,"search":false,"edit":false,"write":false,"exec":false,"consult":false}"#)
        defer { tearDown(env) }
        // Gate AFTER the first content chunk: it flows (firing the
        // actor delta pipeline into the trace) while the rest holds.
        env.server.enqueue(ChatLoopback.textTurn("streamed Chello", splits: 2, gateAfter: 1, gateName: "d1"))
        let traceURL = env.stateDir.appendingPathComponent("trace.jsonl")
        let session = try await ChatCommand.compose(
            config: env.configPath, trace: traceURL.path, alias: nil, maxTurns: 10,
            allowExec: false, workspace: nil, readRoot: [],
            sandboxGrant: nil, acknowledgedDetermination: nil,
            writer: { env.written.append($0) })
        let task = Task { await session.run(scriptedInput: []) }
        guard await requireReady(env, session, task: task) else { return }
        session.loop.post(.inputLine("go"))
        // The actor's DeltaStreamingTransport wiring (through the budget
        // wrapper) delivers streaming deltas to the trace sink while the
        // loopback holds the stream: an opaque wrapper would silently
        // unwire this (M4-D review blocker 1).
        #expect(env.server.waitUntilGateArmed("d1", timeout: 20), "gate never armed")
        let traced: Bool = {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if let text = try? String(contentsOf: traceURL, encoding: .utf8),
                   text.contains("\"kind\":\"delta\"") { return true }
                usleep(50_000)
            }
            return false
        }()
        #expect(traced, "no delta projection reached the trace sink mid-stream")
        env.server.releaseGate("d1")
        #expect(waitUntil(env, "streamed Chello"), "turn never completed")
        await finishRun(session, task: task)
        requireBearer(env)
    }
}

extension ChatCompositionTests {
    @Test("D2 gate refusal preserves the draft and tokens for resubmit (fail-closed, no loss)")
    func gateRefusalPreservesDraft() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "v1 bytes".write(to: base.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        let env = try makeEnv(tools: #"{"read":true,"search":true,"edit":false,"write":false,"exec":false,"consult":false}"#)
        defer { tearDown(env) }
        env.server.enqueue(ChatLoopback.textTurn("gate answer", splits: 1))
        let session = try await ChatCommand.compose(
            config: env.configPath, trace: nil, alias: nil, maxTurns: 10,
            allowExec: false, workspace: base.path, readRoot: [],
            sandboxGrant: nil, acknowledgedDetermination: nil,
            writer: { env.written.append($0) })
        let task = Task { await session.run(scriptedInput: []) }
        guard await requireReady(env, session, task: task) else { return }
        session.loop.post(.mirror(text: "@he", cursor: 3))
        #expect(waitForAccept(session), "suggestion never filled for @he")
        guard let accepted = session.loop.acceptSnapshot() else {
            Issue.record("accept gate closed"); session.loop.post(.inputLine(nil)); await task.value; return
        }
        session.loop.post(.tabAccept(base: accepted.base, display: accepted.display, cursor: accepted.cursor))
        // Remove the file: the submit gate refuses pre-dispatch, so the
        // draft AND tokens survive (no submit dispatch clears them).
        try FileManager.default.removeItem(at: base.appendingPathComponent("hello.txt"))
        session.loop.post(.inputLine(accepted.display))
        #expect(waitUntil(env, "attach refused"), "missing file must refuse; tail: \(env.written.joined().suffix(300))")
        usleep(300_000)
        #expect(env.server.requests.isEmpty, "refused submit must never reach the provider")
        // Recreate and resubmit the SAME line without re-accepting: the
        // preserved tokens attach on the second attempt.
        try "v1 bytes".write(to: base.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        session.loop.post(.inputLine(accepted.display))
        #expect(waitUntil(env, "gate answer"), "resubmit after fix never completed")
        #expect(env.server.requests.count == 1, "expected exactly one provider request")
        let body = String(decoding: env.server.requests[0].body, as: UTF8.self)
        #expect(body.contains("v1 bytes"), "preserved tokens must attach on resubmit")
        await finishRun(session, task: task)
        requireBearer(env)
    }
}

extension ChatCompositionTests {
    @Test("D2 live clear after accept drops the token: next submit carries no attachment (M4-D review)")
    func clearAfterAcceptDropsToken() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-clear-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "secret bytes".write(to: base.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        let env = try makeEnv(tools: #"{"read":true,"search":true,"edit":false,"write":false,"exec":false,"consult":false}"#)
        defer { tearDown(env) }
        env.server.enqueue(ChatLoopback.textTurn("plain answer", splits: 1))
        let session = try await ChatCommand.compose(
            config: env.configPath, trace: nil, alias: nil, maxTurns: 10,
            allowExec: false, workspace: base.path, readRoot: [],
            sandboxGrant: nil, acknowledgedDetermination: nil,
            writer: { env.written.append($0) })
        let task = Task { await session.run(scriptedInput: []) }
        guard await requireReady(env, session, task: task) else { return }
        // Accept a mention, then clear the live buffer (Ctrl+C path):
        // the token must die with the draft — the next submit is plain
        // text with NO attachment (privacy: no stale file sent).
        session.loop.post(.mirror(text: "@he", cursor: 3))
        #expect(waitForAccept(session), "suggestion never filled for @he")
        guard let accepted = session.loop.acceptSnapshot() else {
            Issue.record("accept gate closed"); session.loop.post(.inputLine(nil)); await task.value; return
        }
        session.loop.post(.tabAccept(base: accepted.base, display: accepted.display, cursor: accepted.cursor))
        session.loop.post(.mirror(text: "", cursor: 0))
        session.loop.post(.inputLine("plain text"))
        #expect(waitUntil(env, "plain answer"), "submit never completed")
        #expect(env.server.requests.count == 1, "expected exactly one provider request")
        let body = String(decoding: env.server.requests[0].body, as: UTF8.self)
        #expect(!body.contains("secret bytes"), "cleared token must not attach (stale file sent!)")
        await finishRun(session, task: task)
        requireBearer(env)
        try await requireStoreClean(session)
    }
}

extension ChatCompositionTests {
    @Test("multiline submit preserves newlines end to end")
    func multilineSubmitPreservesNewlines() async throws {
        let env = try makeEnv(tools: #"{"read":false,"search":false,"edit":false,"write":false,"exec":false,"consult":false}"#)
        defer { tearDown(env) }
        env.server.enqueue(ChatLoopback.textTurn("ok", splits: 1))
        let session = try await ChatCommand.compose(
            config: env.configPath, trace: nil, alias: nil, maxTurns: 10,
            allowExec: false, workspace: nil, readRoot: [],
            sandboxGrant: nil, acknowledgedDetermination: nil,
            writer: { env.written.append($0) })
        let task = Task { await session.run(scriptedInput: []) }
        guard await requireReady(env, session, task: task) else { return }
        session.loop.post(.inputLine("line one\nline two"))
        #expect(waitUntil(env, "ok"))
        await finishRun(session, task: task)
        let body = String(decoding: env.server.requests[0].body, as: UTF8.self)
        #expect(body.contains("line one\\nline two"), "newlines must survive submit byte-exact")
        try await requireStoreClean(session)
    }
}

extension ChatCompositionTests {
    @Test("Cf battery neutralizes, ZWJ survives end to end (C5.3 composition leg)")
    func cfBatteryEndToEnd() async throws {
        let env = try makeEnv(tools: #"{"read":false,"search":false,"edit":false,"write":false,"exec":false,"consult":false}"#)
        defer { tearDown(env) }
        let hostile = "Hello \u{1B}]0;pwned\u{7} tail \u{200D} mid \u{200B} end"
        env.server.enqueue(ChatLoopback.textTurn(hostile, splits: 9))
        env.server.enqueue(ChatLoopback.textTurn("second done", splits: 1))
        let session = try await ChatCommand.compose(
            config: env.configPath, trace: nil, alias: nil, maxTurns: 10,
            allowExec: false, workspace: nil, readRoot: [],
            sandboxGrant: nil, acknowledgedDetermination: nil,
            writer: { env.written.append($0) })
        let task = Task { await session.run(scriptedInput: []) }
        guard await requireReady(env, session, task: task) else { return }
        session.loop.post(.inputLine("go"))
        #expect(waitUntil(env, "tail", timeout: 20), "hostile first turn never rendered")
        session.loop.post(.inputLine("next"))
        #expect(waitUntil(env, "second done", timeout: 20), "second turn never completed")
        await finishRun(session, task: task)
        let out = env.written.joined()
        var sawZWJ = false
        var sawLoneCf = false
        var sawFFFD = false
        for scalar in out.unicodeScalars {
            if scalar.value == 0x200D { sawZWJ = true }
            if scalar.value == 0xFFFD { sawFFFD = true }
            if scalar.properties.generalCategory == .format && scalar.value != 0x200D { sawLoneCf = true }
        }
        #expect(sawZWJ, "ZWJ must survive the full pipeline")
        #expect(!sawLoneCf, "no lone Cf may reach the terminal")
        #expect(sawFFFD, "neutralized Cf becomes FFFD")
    }
}




extension ChatCompositionTests {
    @Test("D4 inspect mid-stream does not retire the turn: commit still renders")
    func inspectDuringStreamCommits() async throws {
        let env = try makeEnv(tools: #"{"read":false,"search":false,"edit":false,"write":false,"exec":false,"consult":false}"#)
        defer { tearDown(env) }
        // Gate the only content chunk: the turn is provably in flight
        // while the inspect line is entered (no sleeps-as-oracles).
        env.server.enqueue(ChatLoopback.textTurn("streamed-and-committed", splits: 3, gateAfter: 1, gateName: "i1"))
        let session = try await ChatCommand.compose(
            config: env.configPath, trace: nil, alias: nil, maxTurns: 10,
            allowExec: false, workspace: nil, readRoot: [],
            sandboxGrant: nil, acknowledgedDetermination: nil,
            writer: { env.written.append($0) })
        let task = Task { await session.run(scriptedInput: []) }
        guard await requireReady(env, session, task: task) else { return }
        session.loop.post(.inputLine("first"))
        #expect(env.server.waitUntilGateArmed("i1", timeout: 20), "gate never armed — stream finished before the inspect")
        // Inspect DURING the stream: retire-liveness must survive
        // (D7 review B4) — the turn still commits after release.
        session.loop.post(.inputLine("/context"))
        #expect(waitUntil(env, "tokens estimated"), "inspect must render mid-stream; tail: \(env.written.joined().suffix(300))")
        env.server.releaseGate("i1")
        #expect(waitUntil(env, "streamed-and-committed"), "mid-stream inspect dropped the commit; tail: \(env.written.joined().suffix(400))")
        await finishRun(session, task: task)
        requireBearer(env)
        #expect(env.server.requests.count == 1, "inspect must not send provider traffic, got \(env.server.requests.count)")
        try await requireStoreClean(session)
    }
}

extension ChatCompositionTests {
    @Test("D3 stale Tab accept drops, suppresses the echo, Enter reconciles")
    func staleTabAcceptDropsCleanly() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-stale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "completion file bytes".write(to: base.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        let env = try makeEnv(tools: #"{"read":true,"search":true,"edit":false,"write":false,"exec":false,"consult":false}"#)
        defer { tearDown(env) }
        env.server.enqueue(ChatLoopback.textTurn("stale submit done", splits: 1))
        let session = try await ChatCommand.compose(
            config: env.configPath, trace: nil, alias: nil, maxTurns: 10,
            allowExec: false, workspace: base.path, readRoot: [],
            sandboxGrant: nil, acknowledgedDetermination: nil,
            writer: { env.written.append($0) })
        let task = Task { await session.run(scriptedInput: []) }
        guard await requireReady(env, session, task: task) else { return }
        // Live suggestion for "@he"; capture the published snapshot,
        // then advance the draft past it (the scripted analogue of a
        // fast Tab racing unprocessed keystrokes, D7 review B3).
        session.loop.post(.mirror(text: "@he", cursor: 3))
        #expect(waitForAccept(session), "suggestion never filled for @he")
        guard let snap = session.loop.acceptSnapshot() else {
            Issue.record("accept gate closed"); await finishRun(session, task: task); return
        }
        session.loop.post(.mirror(text: "@hex", cursor: 4))
        // Force the stale accept the input thread would have sent had
        // its live check not caught up: base "@he", previewed display.
        session.loop.post(.tabAccept(base: snap.base, display: snap.display, cursor: snap.cursor))
        // The trampoline's trailing echo of the stale display. FIFO
        // inbox order is the determinism argument here (no barrier
        // needed — and a slash-command barrier would clear the draft
        // by design): the accept is processed before the echo, and
        // the echo before the submit.
        session.loop.post(.mirror(text: snap.display, cursor: snap.cursor))
        // Submit the stale display plus new typing: the reconcile must
        // submit the CURRENT draft plus only the newer input — never
        // the unaccepted preview.
        session.loop.post(.inputLine(snap.display + " plus"))
        #expect(waitUntil(env, "stale submit done"), "reconciled submit never completed")
        await finishRun(session, task: task)
        requireBearer(env)
        #expect(env.server.requests.count == 1, "expected exactly one provider request, got \(env.server.requests.count)")
        let body = String(decoding: env.server.requests[0].body, as: UTF8.self)
        #expect(body.contains("@hex plus"), "submit must carry the reconciled draft, got: \(body.suffix(300))")
        #expect(!body.contains(snap.display + " plus"), "stale preview must never submit as text")
        try await requireStoreClean(session)
    }
}
