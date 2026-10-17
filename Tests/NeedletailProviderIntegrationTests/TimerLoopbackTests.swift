import Testing
import Foundation
import AsyncHTTPClient
import NeedletailCore
import NeedletailProviders
import NeedletailTestSupport

/// M1-D real timer scheduling over loopback: `startTimer` fires actual
/// sleeps with generation checks (no longer no-ops). The flaky adapter
/// fails once preSend (real classification), the production timer — not an
/// explicit test tick — dispatches the retry, and cancelled timers never
/// dispatch after the grace. Slow by design (real 1 s backoff / 5 s grace);
/// case-gated, never quick.
@Suite(.serialized)
struct TimerLoopbackTests {
    typealias LoopActor = SessionActor<
        FlakyTransport<ChatCompletionsTransport>, TrivialExecutor,
        InMemorySessionStore, TrivialApprovals, VirtualClock, DeterministicIDSource>

    private static func actor(
        server: LoopbackSSEServer, failFirst: Bool = true, prefix: String
    ) async throws -> (LoopActor, FlakyTransport<ChatCompletionsTransport>, ChatCompletionsTransport) {
        let (inner, snapshot) = try LoopbackFixtures.transport(server: server)
        let flaky = FlakyTransport(inner: inner, failFirst: failFirst)
        let actor = SessionActor(
            state: try ActorLoopback.idleState(snapshot: snapshot),
            ids: DeterministicIDSource(prefix: prefix), clock: VirtualClock(now: 3_000_000),
            transport: flaky, executor: TrivialExecutor(),
            store: InMemorySessionStore(), approvals: TrivialApprovals())
        return (actor, flaky, inner)
    }

    @Test("retry-backoff timer dispatches without an explicit tick")
    func retryTimerFires() async throws {
        let server = try LoopbackSSEServer()
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(CannedTurn.text("timer turn").utf8))]))
        server.start()
        defer { server.stop() }
        let (actor, flaky, live) = try await Self.actor(server: server, prefix: "tmr")
        // The actor owns a transport copy sharing this client; drain it at
        // scope exit (AHC traps on un-shut-down deinit).
        defer { await LoopbackFixtures.shutdown(live.client) }
        await actor.submitText(commandID: CommandID("t-1"), text: "hello", kind: .followUp, sealed: false)
        // Armed by the classified preSend; then HANDS OFF — no tick call.
        _ = try await ActorLoopback.awaitState({ $0.retryDeadlineMillis != nil }, "retry armed", actor: actor)
        // The production 1 s timer dispatches the retry on its own.
        // Real sleep: the VirtualClock-based timer fires after 1 s wall
        // time (see SessionActor.scheduleTimer), not after yields.
        let done = try await Self.awaitRealTime({
            if case .completed = $0.phase { return true }
            return false
        }, label: "timer-completed run", actor: actor, timeoutSeconds: 3)
        #expect(flaky.failures == 1 && flaky.delegated == 1, "one failure, one timer-dispatched retry")
        #expect(server.connectionCount == 1, "single connection")
        guard case .completed(let receipt) = done.phase else {
            Issue.record("expected completed, got \(done.phase)"); return
        }
        #expect(receipt.turnsUsed == 2, "initial + timer retry")
    }

    private static func awaitRealTime(
        _ check: @Sendable @escaping (SessionState) -> Bool, label: String,
        actor: LoopActor, timeoutSeconds: Int
    ) async throws -> SessionState {
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
        while Date() < deadline {
            let state = await actor.currentState()
            if check(state) { return state }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let state = await actor.currentState()
        print("TIMEOUT \(label) phase=\(state.phase) deadline=\(String(describing: state.retryDeadlineMillis)) turns=\(state.turnsUsed)")
        Issue.record("actor never reached \(label)")
        throw LoopbackCheckFailed.unreached
    }

    @Test("cancelled timers never dispatch after backoff and grace")
    func staleTimersDrop() async throws {
        let server = try LoopbackSSEServer()
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(CannedTurn.text("never").utf8))]))
        server.start()
        defer { server.stop() }
        let (actor, flaky, live) = try await Self.actor(server: server, prefix: "tmr-cancel")
        // The actor owns a transport copy sharing this client; drain it at
        // scope exit (AHC traps on un-shut-down deinit).
        defer { await LoopbackFixtures.shutdown(live.client) }
        await actor.submitText(commandID: CommandID("t-1"), text: "hello", kind: .followUp, sealed: false)
        _ = try await ActorLoopback.awaitState({ $0.retryDeadlineMillis != nil }, "retry armed", actor: actor)
        let before = flaky.delegated
        await actor.cancel()
        // Past the 1 s backoff AND the 5 s cancel grace: neither timer may
        // dispatch or resurrect. Poll with early exit (fails fast).
        for _ in 0..<140 {
            if flaky.delegated > before {
                Issue.record("stale timer dispatched after cancel")
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(flaky.delegated == before, "no dispatch after cancel")
        #expect(server.requests.isEmpty, "zero bytes after cancel")
    }
}
