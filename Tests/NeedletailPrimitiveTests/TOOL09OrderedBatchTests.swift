import Testing
import Foundation
import NeedletailCore
@testable import NeedletailRuntime
import NeedletailTestSupport
import Crypto
import SystemPackage
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// B4 ordered partial batches through the REAL stack: production
/// SessionActor + NativeToolExecutor + durable GRDB store + real
/// temporary filesystems. Proves integration failures that isolated
/// tests cannot detect: halt preservation, unknown+hold, unstarted
/// discharge, intent/result ordering, reconcile-after-reopen, and the
/// counterfactuals (aggregate receipts, false holds, auto-retry,
/// reordering, post-dispatch throws, lost successes).
struct TOOL09OrderedBatchTests {

    // MARK: - Local seams (minimal; ActorTests owns the shared scripted seams)

    final class T09Transport: ModelTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _script: [ProviderResponse] = []
        private var _invocations: [ProviderInvocation] = []
        var script: [ProviderResponse] { get { lock.withLock { _script } } set { lock.withLock { _script = newValue } } }
        var invocations: [ProviderInvocation] { lock.withLock { _invocations } }
        func invoke(_ invocation: ProviderInvocation, intake: BoundedChannelState<ProviderResponse>) async throws -> TransportResult {
            lock.withLock { _invocations.append(invocation) }
            guard let next = lock.withLock({ _script.isEmpty ? nil : _script.removeFirst() }) else {
                throw T09Error.outOfScript
            }
            return TransportResult(response: next)
        }
    }

    enum T09Error: Error { case outOfScript, boom }

    final class T09Approvals: ApprovalGateway, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [ApprovalRequest] = []
        var requests: [ApprovalRequest] { lock.withLock { _requests } }
        func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
            lock.withLock { _requests.append(request) }
            return .approve
        }
    }

    /// Counterfactual shim: an aggregate receipt with NO per-call outcomes.
    final class AggregateExecutor: ToolExecutor, @unchecked Sendable {
        func describe(batch: ToolBatch) -> String { "aggregate" }
        func execute(batch: ToolBatch, reservation: EffectReservation) async throws -> ExecutorResult {
            ExecutorResult(receipt: ExecutorReceipt(callID: "agg", status: "success", summary: "all ok"), calls: [])
        }
    }

    /// Counterfactual shim: performs the first write for real, then throws.
    final class ThrowAfterWriteExecutor: ToolExecutor, @unchecked Sendable {
        let inner: NativeToolExecutor
        init(inner: NativeToolExecutor) { self.inner = inner }
        func describe(batch: ToolBatch) -> String { "throw-after-write" }
        func execute(batch: ToolBatch, reservation: EffectReservation) async throws -> ExecutorResult {
            guard let first = batch.proposals.first else { return ExecutorResult(receipt: ExecutorReceipt(callID: "empty", status: "ok", summary: "empty"), calls: []) }
            _ = try await inner.execute(batch: ToolBatch([first]), reservation: reservation)
            throw T09Error.boom
        }
    }

    /// Counterfactual shim: reports per-call outcomes in reverse order.
    final class ShuffledExecutor: ToolExecutor, @unchecked Sendable {
        func describe(batch: ToolBatch) -> String { "shuffled" }
        func execute(batch: ToolBatch, reservation: EffectReservation) async throws -> ExecutorResult {
            let calls = batch.proposals.reversed().map {
                ToolCallOutcome(callID: $0.callID, status: "success", summary: "ok", data: "ok", started: true)
            }
            return ExecutorResult(receipt: ExecutorReceipt(callID: "shuf", status: "ok", summary: "ok"), calls: Array(calls))
        }
    }

    typealias T09Actor<E: ToolExecutor> = SessionActor<T09Transport, E, GRDBSessionStore, T09Approvals, VirtualClock, DeterministicIDSource>

    // MARK: - Harness

    private static func tempDir(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    private static func sha(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func makeEpoch() throws -> EpochDescriptor {
        let cfgJSON = """
        {"version":1,"default_model":"local-coder","allow_http_origins":["http://127.0.0.1:11434"],"models":[{"alias":"local-coder","protocol":"openai-chat-completions","base_url":"http://127.0.0.1:11434","model":"qwen","context_window":262144,"max_output":4096,"locality":"local","connect_timeout_s":10,"read_idle_timeout_s":300,"request_timeout_s":1800,"max_in_flight":1}],"tools":{"read":true,"search":true,"edit":true,"write":true,"exec":"ask","consult":false}}
        """
        let cfg = try validateConfig(Data(cfgJSON.utf8))
        let profile = try #require(cfg.profiles["local-coder"])
        let caps = effectiveCapabilities(build: .allAllowed, userConfig: cfg.tools, workspaceGrant: .allAllowed, invocationMask: .allAllowed, sealed: SealedRestrictions(sealed: false))
        let route = selectRoute(snapshot: cfg, requestedAlias: "local-coder", sealed: false)
        return EpochDescriptor(epochID: EpochID("epoch-1"), configSnapshot: cfg, profile: profile, effectiveCaps: caps, route: route)
    }

    private static func proposalsResponse(_ proposals: [ToolProposal]) -> ProviderResponse {
        ProviderResponse(requestID: RequestID("scripted"), generation: Revision(0),
            outcome: .textDeltaComplete(text: "calls", toolProposals: proposals, isFinal: false))
    }

    private static func finalResponse() -> ProviderResponse {
        ProviderResponse(requestID: RequestID("scripted"), generation: Revision(0),
            outcome: .textDeltaComplete(text: "done", toolProposals: [], isFinal: true))
    }

    private static func writeArgs(_ path: String, _ content: String) -> String {
        let escaped = content.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        return "{\"path\":\"\(path)\",\"content\":\"\(escaped)\"}"
    }

    private static func editArgs(_ path: String, _ hash: String, _ old: String, _ new: String) -> String {
        "{\"path\":\"\(path)\",\"expectedHash\":\"\(hash)\",\"old_string\":\"\(old)\",\"new_string\":\"\(new)\"}"
    }

    private static func readArgs(_ path: String) -> String { "{\"path\":\"\(path)\"}" }

    private static func makeActor<E: ToolExecutor>(ws: URL, executor: E) throws -> (T09Actor<E>, T09Transport, GRDBSessionStore, SessionID, URL) {
        let dbDir = try Self.tempDir(prefix: "tool09-db")
        let store = try GRDBSessionStore(path: dbDir.appendingPathComponent("store.sqlite").path)
        let session = SessionID("s-tool09")
        let transport = T09Transport()
        let approvals = T09Approvals()
        let actor = try SessionActor(state: SessionState(sessionID: session, epoch: try Self.makeEpoch(), trustMode: .workspace, phase: .idle),
            ids: DeterministicIDSource(prefix: "t"), clock: VirtualClock(now: 1_000_000),
            transport: transport, executor: executor, store: store, approvals: approvals, writer: "tool09-w")
        return (actor, transport, store, session, dbDir)
    }

    private static func nativeExecutor(ws: URL, store: GRDBSessionStore, session: SessionID) throws -> NativeToolExecutor {
        let resolver = try WorkspaceResolver(workspace: FilePath(ws.path), readRoots: [])
        return NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: WriterIdentity(session: session, writer: "tool09-w"))
    }

    private static func awaitState<E: ToolExecutor>(_ actor: T09Actor<E>, _ check: (SessionState) -> Bool, _ label: String, timeoutSeconds: Double = 30) async throws {
        // Wall-clock bound (not a yield count: yield throughput varies with
        // machine load, while executor deadlines are real-time). Waiting
        // longer can never produce a false pass — only a genuine hang fails.
        let end = Date().addingTimeInterval(timeoutSeconds)
        while Date() < end {
            if check(await actor.currentState()) { return }
            await Task.yield()
        }
        Issue.record("actor never reached \(label); state=\(await actor.currentState().phase)")
        throw T09Error.outOfScript
    }

    private static func isDone(_ state: SessionState) -> Bool {
        if case .completed = state.phase { return true }
        return false
    }

    private static func allRecords(_ store: GRDBSessionStore, _ session: SessionID) throws -> [DurableRecord] {
        var out: [DurableRecord] = []
        var cursor: UInt64 = 0
        while true {
            let (page, next) = try store.records(session: session, since: cursor, limit: 500)
            out += page.map(\.record)
            guard let advanced = next else { break }
            cursor = advanced
        }
        return out
    }

    private static func intents(_ log: [DurableRecord]) -> [OperationRef] {
        log.compactMap { if case .operationIntent(let r) = $0, r.callID != nil { return r } else { return nil } }
    }

    private static func results(_ log: [DurableRecord]) -> [(OperationRef, String)] {
        log.compactMap { if case .operationResult(let r, let o) = $0 { return (r, o) } else { return nil } }
    }

    private static func toolResponses(_ log: [DurableRecord]) -> [String] {
        log.compactMap { if case .transcriptAppended(.toolResponse(let id, _)) = $0 { return id } else { return nil } }
    }

    /// Small predicates keeping #expect macro bodies trivially checkable
    /// (tuple-element closures inside the macro exceed the type-checker).
    private static func doneWith(_ done: [(OperationRef, String)], _ id: String, _ text: String) -> Bool {
        done.contains(where: { $0.0.callID == id && $0.0.state == .done && $0.1.contains(text) })
    }

    private static func doneOutcome(_ done: [(OperationRef, String)], _ id: String, _ outcome: String) -> Bool {
        done.contains(where: { $0.0.callID == id && $0.0.state == .done && $0.1 == outcome })
    }

    // MARK: - TOOL-09 matrix: second file fails

    @Test("TOOL_09_writeOkEditConflictReadUnstarted")
    func writeOkEditConflictReadUnstarted() async throws {
        let ws = try Self.tempDir(prefix: "tool09-ws")
        defer { try? FileManager.default.removeItem(at: ws) }
        try "hello\n".write(to: ws.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        // Build the actor with a firing pre-call gate: proves intents
        // are durable before ANY filesystem effect (intent-before-effect).
        let dbDir = try Self.tempDir(prefix: "tool09-db")
        defer { try? FileManager.default.removeItem(at: dbDir) }
        let store = try GRDBSessionStore(path: dbDir.appendingPathComponent("store.sqlite").path)
        let session = SessionID("s-tool09")
        let enteredBox = LockedBox()
        let release = AsyncRelease()
        let resolver = try WorkspaceResolver(workspace: FilePath(ws.path), readRoots: [])
        let gated = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: WriterIdentity(session: session, writer: "tool09-w"),
            preCallSuspension: { _ in enteredBox.note(); await release.wait() })
        let transport = T09Transport()
        let batch = [
            ToolProposal(callID: "c1", tool: "write", argumentsDigest: "d", arguments: Self.writeArgs("b.txt", "new file\n")),
            ToolProposal(callID: "c2", tool: "edit", argumentsDigest: "d", arguments: Self.editArgs("a.txt", String(repeating: "f", count: 64), "hello", "world")),
            ToolProposal(callID: "c3", tool: "read", argumentsDigest: "d", arguments: Self.readArgs("a.txt")),
        ]
        transport.script = [Self.proposalsResponse(batch), Self.finalResponse()]
        let actor = try SessionActor(state: SessionState(sessionID: session, epoch: try Self.makeEpoch(), trustMode: .workspace, phase: .idle),
            ids: DeterministicIDSource(prefix: "t"), clock: VirtualClock(now: 1_000_000),
            transport: transport, executor: gated, store: store, approvals: T09Approvals(), writer: "tool09-w")
        await actor.submitText(commandID: CommandID("r-1"), text: "run", kind: .followUp, sealed: false)
        // The executor entered c1 and is gated: intents must already be durable.
        for _ in 0..<40_000 where !enteredBox.value { await Task.yield() }
        #expect(enteredBox.value, "executor must reach the pre-call gate")
        let preLog = try Self.allRecords(store, session)
        let preIntents = Self.intents(preLog)
        #expect(Set(preIntents.map(\.callID)) == ["c1", "c2", "c3"], "all three intents durable before any effect, got \(preIntents)")
        #expect(!FileManager.default.fileExists(atPath: ws.appendingPathComponent("b.txt").path), "no effect before intent commit")
        release.release()
        try await Self.awaitState(actor, { Self.isDone($0) }, "run completed")
        #expect(transport.invocations.count == 2, "continuation proceeded to the provider")

        // Filesystem truth.
        #expect(try String(contentsOf: ws.appendingPathComponent("b.txt"), encoding: .utf8) == "new file\n", "c1 write durable")
        #expect(try String(contentsOf: ws.appendingPathComponent("a.txt"), encoding: .utf8) == "hello\n", "conflicted file untouched")

        let log = try Self.allRecords(store, session)
        let found = Self.intents(log)
        #expect(found.count == 3, "one intent per operation")
        #expect(found.first(where: { $0.callID == "c1" })?.mutating == true)
        #expect(found.first(where: { $0.callID == "c2" })?.mutating == true)
        #expect(found.first(where: { $0.callID == "c3" })?.mutating == false, "per-proposal intent mutating")
        let done = Self.results(log)
        #expect(done.count == 3, "one result per operation, got \(done)")
        #expect(done.contains(where: { $0.0.callID == "c1" && $0.0.state == .done }), "c1 success stands (a lost success would fail here)")
        #expect(Self.doneWith(done, "c2", "hash mismatch"), "c2 deterministic stale-hash conflict")
        #expect(Self.doneOutcome(done, "c3", "cancelled: unstarted"), "c3 proven unstarted")
        #expect(done.map(\.0.callID) == ["c1", "c2", "c3"], "results in proposal order")
        #expect(Self.toolResponses(log) == ["c1", "c2", "c3"], "transcript in proposal order")
        // Intent/result identity agreement per operationID.
        #expect(Set(done.map(\.0.operationID)) == Set(found.map(\.operationID)), "results reuse intent IDs")
        let state = await actor.currentState()
        #expect(state.unresolvedOperations.isEmpty, "no hold: nothing uncertain")

        // Fresh-handle reconciliation after partial execution.
        let path = dbDir.appendingPathComponent("store.sqlite").path
        try store.close()
        let reopened = try GRDBSessionStore(path: path)
        defer { try? reopened.close() }
        let fresh = try Self.allRecords(reopened, session)
        let rec = try reconcileOperations(fresh)
        #expect(rec.completed.count == 3, "reopen completes all three, got \(rec)")
        #expect(rec.heldOperations.isEmpty, "reopen holds nothing")
        #expect(rec.explicitUnknown.isEmpty && rec.unmatchedMutating.isEmpty && rec.orphanResults.isEmpty)
    }

    final class LockedBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        var value: Bool { lock.withLock { _value } }
        func note() { lock.withLock { _value = true } }
    }

    /// Async release gate: never blocks a thread (production seams forbid
    /// synchronous blocking inside the deadline race — a blocked group
    /// child stalls group progress in this toolchain).
    final class AsyncRelease: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var open = false
        func wait() async {
            if lock.withLock({ open }) { return }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let alreadyOpen: Bool = lock.withLock {
                    if open { return true }
                    continuation = c
                    return false
                }
                if alreadyOpen { c.resume() }
            }
        }
        func release() {
            let c: CheckedContinuation<Void, Never>? = lock.withLock {
                open = true
                defer { continuation = nil }
                return continuation
            }
            c?.resume()
        }
    }

    private struct T09Run<E: ToolExecutor> {
        let actor: T09Actor<E>
        let transport: T09Transport
        let store: GRDBSessionStore
        let session: SessionID
        let ws: URL
        let dbDir: URL
    }

    private static func runBatch<E: ToolExecutor>(
        files: [String: String] = [:],
        proposals: [ToolProposal],
        existingWS: URL? = nil,
        makeExecutor: (URL, GRDBSessionStore, SessionID) throws -> E
    ) async throws -> T09Run<E> {
        let ws: URL
        if let existingWS {
            ws = existingWS
        } else {
            ws = try Self.tempDir(prefix: "tool09-ws")
        }
        for (name, content) in files {
            try content.write(to: ws.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let dbDir = try Self.tempDir(prefix: "tool09-db")
        let store = try GRDBSessionStore(path: dbDir.appendingPathComponent("store.sqlite").path)
        let session = SessionID("s-tool09")
        let executor = try makeExecutor(ws, store, session)
        let transport = T09Transport()
        transport.script = [Self.proposalsResponse(proposals), Self.finalResponse()]
        let actor = try SessionActor(state: SessionState(sessionID: session, epoch: try Self.makeEpoch(), trustMode: .workspace, phase: .idle),
            ids: DeterministicIDSource(prefix: "t"), clock: VirtualClock(now: 1_000_000),
            transport: transport, executor: executor, store: store, approvals: T09Approvals(), writer: "tool09-w")
        await actor.submitText(commandID: CommandID("r-\(UUID().uuidString)"), text: "run", kind: .followUp, sealed: false)
        return T09Run(actor: actor, transport: transport, store: store, session: session, ws: ws, dbDir: dbDir)
    }

    private static func plainNative(ws: URL, store: GRDBSessionStore, session: SessionID) throws -> NativeToolExecutor {
        let resolver = try WorkspaceResolver(workspace: FilePath(ws.path), readRoots: [])
        return NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: WriterIdentity(session: session, writer: "tool09-w"))
    }

    private static func cleanup(_ run: T09Run<some ToolExecutor>) {
        try? run.store.close()
        try? FileManager.default.removeItem(at: run.ws)
        try? FileManager.default.removeItem(at: run.dbDir)
    }

    // MARK: - Matrix, continued

    @Test("TOOL_09_editOkWriteReplacementConflictReadUnstarted")
    func editOkWriteReplacementConflictReadUnstarted() async throws {
        let h0 = Self.sha("hello\n")
        let run = try await Self.runBatch(
            files: ["a.txt": "hello\n", "b.txt": "old\n"],
            proposals: [
                ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: Self.editArgs("a.txt", h0, "hello", "world")),
                ToolProposal(callID: "c2", tool: "write", argumentsDigest: "d", arguments: "{\"path\":\"b.txt\",\"expectedHash\":\"\(String(repeating: "0", count: 64))\",\"content\":\"new\"}"),
                ToolProposal(callID: "c3", tool: "read", argumentsDigest: "d", arguments: Self.readArgs("a.txt")),
            ],
            makeExecutor: Self.plainNative)
        defer { Self.cleanup(run) }
        try await Self.awaitState(run.actor, { Self.isDone($0) }, "run completed")
        #expect(run.transport.invocations.count == 2, "continuation proceeded")

        #expect(try String(contentsOf: run.ws.appendingPathComponent("a.txt"), encoding: .utf8) == "world\n", "c1 edit landed")
        #expect(try String(contentsOf: run.ws.appendingPathComponent("b.txt"), encoding: .utf8) == "old\n", "conflicted replacement untouched")

        let log = try Self.allRecords(run.store, run.session)
        let done = Self.results(log)
        #expect(done.count == 3)
        #expect(Self.doneWith(done, "c1", "edited"), "c1 edit success stands")
        #expect(Self.doneWith(done, "c2", "hash mismatch"), "c2 stale-hash conflict")
        #expect(Self.doneOutcome(done, "c3", "cancelled: unstarted"), "c3 unstarted")
        #expect(done.map(\.0.callID) == ["c1", "c2", "c3"], "proposal order preserved")
        #expect((await run.actor.currentState()).unresolvedOperations.isEmpty, "no hold")
    }

    @Test("TOOL_09_readOkWriteLockContentionReadUnstarted")
    func readOkWriteLockContentionReadUnstarted() async throws {
        let ws = try Self.tempDir(prefix: "tool09-ws")
        defer { try? FileManager.default.removeItem(at: ws) }
        try "hello".write(to: ws.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        // Pin the workspace lock in-process: the executor's nonblocking
        // acquisition must fail with contention (no subprocess, no sleep,
        // instant deterministic teardown).
        let pinned = try #require(try WorkspaceResolver(workspace: FilePath(ws.path), readRoots: []).workspaceRoot)
        let tmp = try WorkspaceLock.acquire(workspace: pinned)
        WorkspaceLock.release(tmp)
        let heldFD = try WorkspaceLock.acquire(workspace: pinned)
        defer { WorkspaceLock.release(heldFD) }

        let run = try await Self.runBatch(
            files: [:],
            proposals: [
                ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d", arguments: Self.readArgs("f")),
                ToolProposal(callID: "c2", tool: "write", argumentsDigest: "d", arguments: Self.writeArgs("g.txt", "blocked\n")),
                ToolProposal(callID: "c3", tool: "read", argumentsDigest: "d", arguments: Self.readArgs("f")),
            ],
            existingWS: ws,
            makeExecutor: Self.plainNative)
        defer { Self.cleanup(run) }
        try await Self.awaitState(run.actor, { Self.isDone($0) }, "run completed")
        #expect(run.transport.invocations.count == 2, "continuation proceeded past deterministic lock failure")

        let log = try Self.allRecords(run.store, run.session)
        let done = Self.results(log)
        #expect(done.count == 3, "all three resolve done, got \(done)")
        #expect(done.contains(where: { $0.0.callID == "c1" && $0.0.state == .done }), "c1 read stands")
        let c2lock = done.contains(where: { $0.0.callID == "c2" && $0.0.state == .done && $0.1.contains("lock") })
        #expect(c2lock, "c2 done-failed on lock contention")
        #expect(Self.doneOutcome(done, "c3", "cancelled: unstarted"), "c3 unstarted, no hold")
        #expect((await run.actor.currentState()).unresolvedOperations.isEmpty, "lock contention holds nothing")
        #expect(!FileManager.default.fileExists(atPath: ws.appendingPathComponent("g.txt").path), "failed write left no file")
    }

    @Test("TOOL_09_readOkWriteLockContentionWriteUnstarted")
    func readOkWriteLockContentionWriteUnstarted() async throws {
        // Mutating-unstarted variant: a proven-unstarted WRITE must also
        // discharge done with no hold, and the run must continue. If the
        // reducer wrongly held it unknown, continuation would block and the
        // invocation count below would stay 1 (RED).
        let ws = try Self.tempDir(prefix: "tool09-ws")
        defer { try? FileManager.default.removeItem(at: ws) }
        try "hello".write(to: ws.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        let pinned = try #require(try WorkspaceResolver(workspace: FilePath(ws.path), readRoots: []).workspaceRoot)
        let tmp = try WorkspaceLock.acquire(workspace: pinned)
        WorkspaceLock.release(tmp)
        let heldFD = try WorkspaceLock.acquire(workspace: pinned)
        defer { WorkspaceLock.release(heldFD) }

        let run = try await Self.runBatch(
            files: [:],
            proposals: [
                ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d", arguments: Self.readArgs("f")),
                ToolProposal(callID: "c2", tool: "write", argumentsDigest: "d", arguments: Self.writeArgs("g.txt", "blocked\n")),
                ToolProposal(callID: "c3", tool: "write", argumentsDigest: "d", arguments: Self.writeArgs("h.txt", "later\n")),
            ],
            existingWS: ws,
            makeExecutor: Self.plainNative)
        defer { Self.cleanup(run) }
        try await Self.awaitState(run.actor, { Self.isDone($0) }, "run completed")
        #expect(run.transport.invocations.count == 2, "run continued: unstarted mutating call held nothing")

        let log = try Self.allRecords(run.store, run.session)
        let done = Self.results(log)
        let c3unstarted = done.contains(where: { $0.0.callID == "c3" && $0.0.state == .done && $0.1 == "cancelled: unstarted" })
        #expect(c3unstarted, "mutating c3 proven unstarted")
        #expect((await run.actor.currentState()).unresolvedOperations.isEmpty, "no false unknowability")
        #expect(!FileManager.default.fileExists(atPath: ws.appendingPathComponent("h.txt").path), "unstarted write left no file")
    }

    @Test("TOOL_09_mixedBatchMutatingAgreement")
    func mixedBatchMutatingAgreement() async throws {
        let h0 = Self.sha("hello\n")
        let run = try await Self.runBatch(
            files: ["a.txt": "hello\n"],
            proposals: [
                ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: Self.editArgs("a.txt", h0, "hello", "world")),
                ToolProposal(callID: "c2", tool: "read", argumentsDigest: "d", arguments: Self.readArgs("a.txt")),
            ],
            makeExecutor: Self.plainNative)
        defer { Self.cleanup(run) }
        try await Self.awaitState(run.actor, { Self.isDone($0) }, "run completed")

        let log = try Self.allRecords(run.store, run.session)
        let found = Self.intents(log)
        #expect(found.first(where: { $0.callID == "c1" })?.mutating == true, "edit intent mutating")
        #expect(found.first(where: { $0.callID == "c2" })?.mutating == false, "read intent non-mutating")
        let done = Self.results(log)
        #expect(done.count == 2, "both done")
        #expect(done.first(where: { $0.0.callID == "c1" })?.0.mutating == true, "executor attests edit mutating")
        #expect(done.first(where: { $0.0.callID == "c2" })?.0.mutating == false, "executor attests read non-mutating")

        // Intent/result agreement per call: reopen verifies via reconcile.
        let path = run.dbDir.appendingPathComponent("store.sqlite").path
        try run.store.close()
        let reopened = try GRDBSessionStore(path: path)
        defer { try? reopened.close() }
        let fresh = try Self.allRecords(reopened, run.session)
        let rec = try reconcileOperations(fresh)
        #expect(rec.completed.count == 2, "reopen completes both (agreement holds), got \(rec)")
        #expect(rec.heldOperations.isEmpty, "reopen holds nothing")
    }

    @Test("TOOL_09_preCommitTimeoutUnknownHoldsNoRetry")
    func preCommitTimeoutUnknownHoldsNoRetry() async throws {
        // Pre-commit timeout: the call never reaches the filesystem (the
        // pre-call gate never releases) yet its completion is uncertain →
        // unknown+hold; later calls unstarted; no automatic retry.
        let run = try await Self.runBatch(
            files: ["a.txt": "hello\n"],
            proposals: [
                ToolProposal(callID: "c1", tool: "write", argumentsDigest: "d", arguments: Self.writeArgs("b.txt", "never\n")),
                ToolProposal(callID: "c2", tool: "read", argumentsDigest: "d", arguments: Self.readArgs("a.txt")),
            ],
            makeExecutor: { ws, store, session in
                let resolver = try WorkspaceResolver(workspace: FilePath(ws.path), readRoots: [])
                return NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: WriterIdentity(session: session, writer: "tool09-w"),
                    deadlines: ToolDeadlines(localIO: 0.3, search: 120),
                    preCallSuspension: { _ in try await Task.sleep(nanoseconds: .max) })
            })
        defer { Self.cleanup(run) }
        try await Self.awaitState(run.actor, { $0.queueHeld }, "queue held on timeout")

        #expect(!FileManager.default.fileExists(atPath: run.ws.appendingPathComponent("b.txt").path), "timed-out call never touched the filesystem")
        let log = try Self.allRecords(run.store, run.session)
        let done = Self.results(log)
        let c1unknown = done.contains(where: { $0.0.callID == "c1" && $0.0.state == .unknown && $0.1.contains("timeout") })
        #expect(c1unknown, "c1 unknown on timeout")
        #expect(Self.doneOutcome(done, "c2", "cancelled: unstarted"), "c2 unstarted")
        #expect(done.map(\.0.callID) == ["c1", "c2"], "proposal order")
        let state = await run.actor.currentState()
        #expect(state.unresolvedOperations.map(\.callID) == ["c1"], "only c1 held")

        // Unknown is never automatically retried: a fresh submission is
        // refused (reconcile first) and dispatches nothing new.
        let intentsBefore = Self.intents(log).count
        await run.actor.submitText(commandID: CommandID("r-again"), text: "again", kind: .followUp, sealed: false)
        for _ in 0..<10_000 { await Task.yield() }
        #expect(run.transport.invocations.count == 1, "no continuation and no re-dispatch while held")
        let logAfter = try Self.allRecords(run.store, run.session)
        #expect(Self.intents(logAfter).count == intentsBefore, "no new intents while held")
    }

    @Test("TOOL_09_postCommitTimeoutStaysUnknown")
    func postCommitTimeoutStaysUnknown() async throws {
        // Post-commit timeout: the rename already applied the bytes, but the
        // success receipt never completes → unknown+hold DESPITE the write.
        // Conservative and exact: the filesystem and the ledger agree that
        // the outcome is unresolved. The suspension never releases; group
        // exit on deadline victory cancels it (no leak, no thread blocked).
        let run = try await Self.runBatch(
            files: ["a.txt": "hello\n"],
            proposals: [ToolProposal(callID: "c1", tool: "write", argumentsDigest: "d", arguments: Self.writeArgs("b.txt", "post-commit\n"))],
            makeExecutor: { ws, store, session in
                let resolver = try WorkspaceResolver(workspace: FilePath(ws.path), readRoots: [])
                return NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: WriterIdentity(session: session, writer: "tool09-w"),
                    deadlines: ToolDeadlines(localIO: 0.5, search: 120),
                    postCommitSuspension: { try await Task.sleep(nanoseconds: .max) })
            })
        defer { Self.cleanup(run) }
        try await Self.awaitState(run.actor, { $0.queueHeld }, "queue held on post-commit timeout")

        #expect(try String(contentsOf: run.ws.appendingPathComponent("b.txt"), encoding: .utf8) == "post-commit\n", "the write DID apply before the timeout")
        let log = try Self.allRecords(run.store, run.session)
        let done = Self.results(log)
        #expect(!done.contains(where: { $0.0.callID == "c1" && $0.0.state == .done }), "no false done despite applied bytes")
        #expect(done.contains(where: { $0.0.callID == "c1" && $0.0.state == .unknown }), "post-commit timeout is unknown+hold, got \(done)")
        let state = await run.actor.currentState()
        #expect(state.unresolvedOperations.map(\.callID) == ["c1"], "only c1 held")
        #expect(run.transport.invocations.count == 1, "no continuation past uncertainty")
    }

    @Test("TOOL_09_invalidBatchArgumentsNoDispatch")
    func invalidBatchArgumentsNoDispatch() async throws {
        // Whole-batch head validation throws pre-dispatch: the actor
        // synthesizes per-call done receipts preserving status — all done,
        // no hold, run continues, nothing executed.
        let run = try await Self.runBatch(
            files: ["a.txt": "hello\n"],
            proposals: [ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: #"{"path":"a.txt","old_string":"x","new_string":"y"}"#)],
            makeExecutor: Self.plainNative)
        defer { Self.cleanup(run) }
        try await Self.awaitState(run.actor, { Self.isDone($0) }, "run completed")
        #expect(run.transport.invocations.count == 2, "continuation proceeded")

        let log = try Self.allRecords(run.store, run.session)
        let done = Self.results(log)
        #expect(done.count == 1, "one receipt, got \(done)")
        #expect(done[0].0.callID == "c1" && done[0].0.state == .done && done[0].1.contains("invalid-arguments"), "done-invalid-arguments preserved, got \(done)")
        #expect((await run.actor.currentState()).unresolvedOperations.isEmpty, "no hold on pre-dispatch failure")
        #expect(try String(contentsOf: run.ws.appendingPathComponent("a.txt"), encoding: .utf8) == "hello\n", "nothing executed")
    }

    @Test("TOOL_09_absolutePathHeadRejectedNoDispatch")
    func absolutePathHeadRejectedNoDispatch() async throws {
        // Batch-head validation rejects the absolute path with a typed
        // pre-dispatch throw: the actor synthesizes per-call done receipts
        // for the whole batch (all done, no hold, run continues) and nothing
        // is executed. Per-call protected-path denial (grantable form) is
        // pinned at executor level (B3 combining test, nil-started).
        let run = try await Self.runBatch(
            files: ["a.txt": "hello\n"],
            proposals: [
                ToolProposal(callID: "c1", tool: "write", argumentsDigest: "d", arguments: Self.writeArgs("/definitely-absent-b4/x.txt", "x\n")),
                ToolProposal(callID: "c2", tool: "read", argumentsDigest: "d", arguments: Self.readArgs("a.txt")),
            ],
            makeExecutor: Self.plainNative)
        defer { Self.cleanup(run) }
        try await Self.awaitState(run.actor, { Self.isDone($0) }, "run completed")
        #expect(run.transport.invocations.count == 2, "continuation proceeded")

        let log = try Self.allRecords(run.store, run.session)
        let done = Self.results(log)
        #expect(done.count == 2, "both resolve")
        #expect(Self.doneWith(done, "c1", "absolute path"), "c1 head-rejected")
        #expect(Self.doneWith(done, "c2", "absolute path"), "whole batch rejected pre-dispatch")
        #expect((await run.actor.currentState()).unresolvedOperations.isEmpty, "rejection holds nothing")
    }

    // MARK: - Counterfactuals (each pins a load-bearing safeguard)

    @Test("TOOL_09_aggregateReceiptCannotCompleteCalls")
    func aggregateReceiptCannotCompleteCalls() async throws {
        // An aggregate receipt with no per-call outcomes must NOT complete
        // any call: the mutating intent stays unknown+held (it may have
        // executed with its receipt lost), the read stays transcript-only.
        // If TOOL_09's assertions ran against this shim, every durable
        // assertion would fail — the fan-out is load-bearing.
        let run = try await Self.runBatch(
            files: ["a.txt": "hello\n"],
            proposals: [
                ToolProposal(callID: "c1", tool: "write", argumentsDigest: "d", arguments: Self.writeArgs("b.txt", "x\n")),
                ToolProposal(callID: "c2", tool: "read", argumentsDigest: "d", arguments: Self.readArgs("a.txt")),
            ],
            makeExecutor: { _, _, _ in AggregateExecutor() })
        defer { Self.cleanup(run) }
        try await Self.awaitState(run.actor, { $0.queueHeld }, "queue held on aggregate receipt")

        let log = try Self.allRecords(run.store, run.session)
        let done = Self.results(log)
        #expect(!done.contains(where: { $0.0.callID == "c1" && $0.0.state == .done }), "aggregate success must not complete the write")
        #expect(done.contains(where: { $0.0.callID == "c1" && $0.0.state == .unknown }), "write intent becomes unknown+held")
        #expect(!done.contains(where: { $0.0.callID == "c2" }), "read takes no durable result")
        #expect(!FileManager.default.fileExists(atPath: run.ws.appendingPathComponent("b.txt").path), "nothing executed")
        #expect(run.transport.invocations.count == 1, "no continuation past the gap")
    }

    @Test("TOOL_09_postDispatchThrowNotCertified")
    func postDispatchThrowNotCertified() async throws {
        // The first write REALLY executes, then the executor throws
        // untyped: the actor must synthesize timeout+started for every
        // call — the applied write becomes unknown+held, never a false
        // done. A naive failEffect treatment would certify the batch with
        // a tool-failure receipt and LOSE the success distinction.
        let h0 = Self.sha("hello\n")
        _ = h0
        let run = try await Self.runBatch(
            files: ["a.txt": "hello\n"],
            proposals: [
                ToolProposal(callID: "c1", tool: "write", argumentsDigest: "d", arguments: Self.writeArgs("b.txt", "applied\n")),
                ToolProposal(callID: "c2", tool: "read", argumentsDigest: "d", arguments: Self.readArgs("a.txt")),
            ],
            makeExecutor: { ws, store, session in
                let resolver = try WorkspaceResolver(workspace: FilePath(ws.path), readRoots: [])
                let inner = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: WriterIdentity(session: session, writer: "tool09-w"))
                return ThrowAfterWriteExecutor(inner: inner)
            })
        defer { Self.cleanup(run) }
        try await Self.awaitState(run.actor, { $0.queueHeld }, "queue held after post-dispatch throw")

        #expect(try String(contentsOf: run.ws.appendingPathComponent("b.txt"), encoding: .utf8) == "applied\n", "the write really executed")
        let log = try Self.allRecords(run.store, run.session)
        let done = Self.results(log)
        #expect(!done.contains(where: { $0.0.callID == "c1" && $0.0.state == .done }), "no false done for the executed write")
        #expect(done.contains(where: { $0.0.callID == "c1" && $0.0.state == .unknown }), "executed write is unknown+held")
        #expect(!done.contains(where: { $0.0.callID == "c2" }), "non-mutating throw is transcript-only")
        #expect(run.transport.invocations.count == 1, "no continuation past uncertainty")
    }

    @Test("TOOL_09_shuffledReportsKeptInProposalOrder")
    func shuffledReportsKeptInProposalOrder() async throws {
        // The backend reports c2 before c1: records and transcript MUST
        // still follow proposal order. Reordered evidence is never trusted
        // positionally — the outcome map pairs by callID.
        let run = try await Self.runBatch(
            files: [:],
            proposals: [
                ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d", arguments: Self.readArgs("a.txt")),
                ToolProposal(callID: "c2", tool: "read", argumentsDigest: "d", arguments: Self.readArgs("b.txt")),
            ],
            makeExecutor: { _, _, _ in ShuffledExecutor() })
        defer { Self.cleanup(run) }
        try await Self.awaitState(run.actor, { Self.isDone($0) }, "run completed")

        let log = try Self.allRecords(run.store, run.session)
        #expect(Self.toolResponses(log) == ["c1", "c2"], "transcript follows proposal order, got \(Self.toolResponses(log))")
        #expect(Self.results(log).map(\.0.callID) == ["c1", "c2"], "results follow proposal order")
    }

    @Test("TOOL_09_searchTimeoutTranscriptOnlyThroughActor")
    func searchTimeoutTranscriptOnlyThroughActor() async throws {
        // Non-mutating uncertainty end to end: a hanging search past its
        // injected deadline reports timeout, takes NO durable result and
        // NO hold — the run continues on the transcript alone.
        let ws = try Self.tempDir(prefix: "tool09-ws")
        defer { try? FileManager.default.removeItem(at: ws) }
        try "hello\n".write(to: ws.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        guard let rg = Self.locateRg() else { throw T09Error.outOfScript }
        _ = rg
        let hang = ws.appendingPathComponent("hang.sh")
        let script = "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then\necho 'ripgrep 99.0.0'\nexit 0\nfi\nexec sleep 60\n"
        try script.write(to: hang, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hang.path)
        let run = try await Self.runBatch(
            files: [:],
            proposals: [ToolProposal(callID: "c1", tool: "search", argumentsDigest: "d", arguments: "{\"pattern\":\"hello\"}")],
            existingWS: ws,
            makeExecutor: { ws, store, session in
                let resolver = try WorkspaceResolver(workspace: FilePath(ws.path), readRoots: [])
                return NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: WriterIdentity(session: session, writer: "tool09-w"),
                    rgPath: hang.path, deadlines: ToolDeadlines(localIO: 30, search: 2))
            })
        defer { Self.cleanup(run) }
        try await Self.awaitState(run.actor, { Self.isDone($0) }, "run completed despite timeout")
        #expect(run.transport.invocations.count == 2, "non-mutating timeout continues the run")

        let log = try Self.allRecords(run.store, run.session)
        #expect(!Self.results(log).contains(where: { $0.0.callID == "c1" }), "timed-out search takes no durable result")
        #expect(Self.toolResponses(log) == ["c1"], "timeout is transcript-visible")
        #expect((await run.actor.currentState()).unresolvedOperations.isEmpty, "no hold for non-mutating uncertainty")
    }

    private static func locateRg() -> String? {
        for candidate in ["/usr/bin/rg", "/bin/rg", "/usr/local/bin/rg"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
