import Testing
import Foundation
import AsyncHTTPClient
import NeedletailCore
import NeedletailProviders
import NeedletailTestSupport

/// NET-05 end to end: the PRODUCTION actor driving the REAL adapter over
/// loopback. Given a transport that fails once preSend, when the actor runs
/// a text turn, then it arms (no inline resend, zero bytes), the explicit
/// tick dispatches exactly one retry, and the delegated real adapter
/// completes the run over a single connection. Forbidden: inline resend,
/// unclassified errors, retries without ticks, merges across attempts.
final class FlakyTransport<Inner: ModelTransport>: ModelTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let inner: Inner
    private let failFirst: Bool
    private var _failures = 0
    private var _delegated = 0

    var failures: Int { lock.withLock { _failures } }
    var delegated: Int { lock.withLock { _delegated } }

    init(inner: Inner, failFirst: Bool = true) {
        self.inner = inner
        self.failFirst = failFirst
    }

    func invoke(_ invocation: ProviderInvocation, intake: BoundedChannelState<ProviderResponse>) async throws -> TransportResult {
        let shouldFail = lock.withLock { () -> Bool in
            if failFirst, _failures == 0 {
                _failures += 1
                return true
            }
            _delegated += 1
            return false
        }
        if shouldFail {
            throw TransportFailure(phase: .preSend, message: "flaky refuse")
        }
        return try await inner.invoke(invocation, intake: intake)
    }
}

struct TrivialExecutor: ToolExecutor {
    func describe(batch: ToolBatch) -> String { "trivial" }
    func execute(batch: ToolBatch, reservation: EffectReservation) async throws -> ExecutorResult {
        ExecutorResult(receipt: ExecutorReceipt(callID: "trivial", status: "ok", summary: "trivial"))
    }
}

struct TrivialApprovals: ApprovalGateway {
    func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
        .unavailable("text turns never request approval")
    }
}

enum ActorLoopback {
    static func idleState(snapshot: ConfigSnapshot) throws -> SessionState {
        let profile = try #require(snapshot.profiles["loop"])
        let caps = effectiveCapabilities(
            build: .allAllowed, userConfig: snapshot.tools,
            workspaceGrant: .allDenied,
            invocationMask: .allAllowed, sealed: SealedRestrictions(sealed: false))
        _ = try validateTrustConsistency(mode: .workspace, caps: caps.tools)
        let route = selectRoute(snapshot: snapshot, requestedAlias: "loop", sealed: false)
        let epoch = EpochDescriptor(
            epochID: EpochID("epoch-loop"), configSnapshot: snapshot, profile: profile,
            effectiveCaps: caps, route: route)
        return SessionState(sessionID: SessionID("s-loop"), epoch: epoch, trustMode: .workspace, phase: .idle)
    }

    static func awaitState(
        _ check: @Sendable @escaping (SessionState) -> Bool, _ label: String,
        actor: SessionActor<FlakyTransport<ChatCompletionsTransport>, TrivialExecutor, InMemorySessionStore, TrivialApprovals, VirtualClock, DeterministicIDSource>
    ) async throws -> SessionState {
        for _ in 0..<200 {
            let state = await actor.currentState()
            if check(state) { return state }
            // Bounded paced poll: yields alone exhaust before the actor's
            // network task runs when the host runs other suites in parallel.
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("actor never reached \(label)")
        throw LoopbackCheckFailed.unreached
    }
}

@Suite(.serialized)
struct ActorLoopbackTests {
    @Test("NET-05 actor arms on preSend, ticks once, completes over loopback")
    func NET_05_actorRetryEndToEnd() async throws {
        let server = try LoopbackSSEServer()
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(CannedTurn.text("actor turn").utf8))]))
        server.start()
        defer { server.stop() }
        let (inner, snapshot) = try LoopbackFixtures.transport(server: server)
        defer { await LoopbackFixtures.shutdown(inner.client) }
        let flaky = FlakyTransport(inner: inner)
        let actor = SessionActor(
            state: try ActorLoopback.idleState(snapshot: snapshot),
            ids: DeterministicIDSource(prefix: "e2e"), clock: VirtualClock(now: 1_000_000),
            transport: flaky, executor: TrivialExecutor(),
            store: InMemorySessionStore(), approvals: TrivialApprovals())

        await actor.submitText(commandID: CommandID("t-1"), text: "hello", kind: .followUp, sealed: false)
        // Arm: the flaky preSend classifies, the actor arms the deadline —
        // no inline resend (delegated stays 0), zero bytes on the wire.
        let armed = try await ActorLoopback.awaitState({ $0.retryDeadlineMillis != nil }, "retry armed", actor: actor)
        #expect(flaky.failures == 1, "exactly one classified failure")
        #expect(flaky.delegated == 0, "no inline resend before the tick")
        #expect(server.requests.isEmpty, "armed means zero bytes sent")
        let deadline = try #require(armed.retryDeadlineMillis)
        // Tick: exactly one retry dispatches through the REAL adapter.
        await actor.tick(at: deadline)
        let done = try await ActorLoopback.awaitState({
            if case .completed = $0.phase { return true }
            return false
        }, "run completed", actor: actor)
        #expect(flaky.delegated == 1, "exactly one retry dispatched")
        #expect(server.connectionCount == 1, "single connection end to end")
        guard case .completed(let receipt) = done.phase else {
            Issue.record("expected completed, got \(done.phase)"); return
        }
        #expect(receipt.turnsUsed == 2, "initial attempt + one tick retry")
        #expect(receipt.toolCallCount == 0, "pure text turn")
    }

    @Test("NET-05 actor never retries a mid-stream abort")
    func NET_05_actorAbortNeverRetries() async throws {
        let server = try LoopbackSSEServer()
        server.enqueue(SSEScript(
            chunks: [
                ScriptChunk(bytes: Array("data: {\"choices\":[{\"delta\":{\"content\":\"part\"}}]}\n\n".utf8)),
                ScriptChunk(bytes: Array("data: {\"choices\":[{\"delta\":{\"content\":\"more\"}}]}\n\n".utf8)),
            ],
            abortAfterChunks: 1))
        server.start()
        defer { server.stop() }
        let (inner, snapshot) = try LoopbackFixtures.transport(server: server)
        defer { await LoopbackFixtures.shutdown(inner.client) }
        // No flakiness: the first (only) attempt streams, then FINs.
        let flaky = FlakyTransport(inner: inner, failFirst: false)
        let actor = SessionActor(
            state: try ActorLoopback.idleState(snapshot: snapshot),
            ids: DeterministicIDSource(prefix: "e2e-abort"), clock: VirtualClock(now: 2_000_000),
            transport: flaky, executor: TrivialExecutor(),
            store: InMemorySessionStore(), approvals: TrivialApprovals())

        await actor.submitText(commandID: CommandID("t-1"), text: "hello", kind: .followUp, sealed: false)
        let done = try await ActorLoopback.awaitState({
            if case .failed = $0.phase { return true }
            return false
        }, "run failed", actor: actor)
        #expect(flaky.delegated == 1, "one attempt, delegated to the real adapter")
        #expect(server.connectionCount == 1, "no resume, no retry after abort")
        guard case .failed = done.phase else {
            Issue.record("expected failed, got \(done.phase)"); return
        }
        // Post-failure ticks stay silent: postContent never arms a retry.
        #expect(done.retryDeadlineMillis == nil, "no deadline armed for postContent")
        await actor.tick(at: 9_000_000)
        let still = await actor.currentState()
        #expect(flaky.delegated == 1, "tick after abort dispatches nothing")
        guard case .failed = still.phase else {
            Issue.record("run must stay failed, got \(still.phase)"); return
        }
    }
}
