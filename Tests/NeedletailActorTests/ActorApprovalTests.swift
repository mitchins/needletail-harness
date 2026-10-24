import Testing
import Foundation
import NeedletailCore
import NeedletailTestSupport

/// POLICY-04 integration — approvals through the real actor with scripted
/// gateways. A silent gateway suspends WITHOUT deciding; the test observes
/// the pending state (no hang — the test itself proceeds), then releases.
/// Forbidden: auto-approval/denial, hangs, secret bytes in requests.
struct ActorApprovalTests {

    /// Drives workspace mode to authorising with an edit batch, returning
    /// the actor plus the pending request. The scripted transport returns a
    /// tool-proposing response; validation is inline in the transition.
    static func authorisingActor(
        approvals: ScriptedApprovals,
        executorGate: AsyncStream<Void>? = nil,
        batch: [ToolProposal] = [ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"a\",\"expectedHash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"old_string\":\"hello\",\"new_string\":\"world\"}")]
    ) async throws -> (
        SessionActor<ScriptedTransport, ScriptedExecutor, InMemorySessionStore, ScriptedApprovals, VirtualClock, DeterministicIDSource>,
        ScriptedTransport,
        InMemorySessionStore,
        ScriptedExecutor
    ) {
        let transport = ScriptedTransport()
        let executor = ScriptedExecutor()
        executor.gate = executorGate
        let (actor, store) = try ActorFixtures.makeActor(mode: .workspace, permissive: true, transport: transport, executor: executor, approvals: approvals)
        transport.script = [ProviderResponse(
            requestID: RequestID("scripted"), generation: Revision(0),
            outcome: .textDeltaComplete(text: "calls", toolProposals: batch.map {
                ToolProposal(callID: $0.callID, tool: $0.tool, argumentsDigest: "d", arguments: $0.arguments)
            }, isFinal: false))]
        await actor.submitText(commandID: CommandID("a-1"), text: "run", kind: .followUp, sealed: false)
        return (actor, transport, store, executor)
    }

    @Test("POLICY-04 silent gateway pends; release decides; ticks never decide")
    func POLICY_04_silentGatewayPends() async throws {
        let approvals = ScriptedApprovals()
        let (stream, continuation) = AsyncStream<ApprovalDecision>.makeStream()
        approvals.gate = stream
        let (actor, _, _, _) = try await Self.authorisingActor(approvals: approvals)
        // The closed gate blocks progress, so the authorising barrier is
        // stable here (unlike instant scripted decisions, which blow past).
        try await ActorFixtures.awaitPhase(actor, { $0.phase == .authorising }, "authorising")
        for _ in 0..<100_000 where approvals.requests.count < 1 {
            await Task.yield()
        }
        let request = try #require((await actor.currentState()).pendingApproval)
        #expect(approvals.requests.count == 1, "exactly one approval request emitted")
        // Ticks while suspended: still pending, nothing decided, test moving.
        await actor.tick(at: 9_999_999)
        let pending = await actor.currentState()
        #expect(pending.phase == .authorising)
        #expect(pending.pendingApproval?.requestID == request.requestID)
        // Release with deny: typed stop, receipt kept.
        continuation.yield(.deny("operator says no"))
        continuation.finish()
        try await ActorFixtures.awaitPhase(actor, {
            if case .failed = $0.phase { return true }
            return false
        }, "failed after deny")
        let stopped = await actor.currentState()
        #expect(stopped.pendingApproval == nil, "decision clears the pending request")
    }

    @Test("POLICY-04 scripted grant continues to executing with intent first")
    func POLICY_04_grantContinues() async throws {
        let approvals = ScriptedApprovals()
        approvals.script = [.approve]
        // Hold the executor gate open: M1-D wiring auto-completes effects, so
        // the release gate keeps `executing` observable without sleeps.
        let (gateStream, releaseGate) = AsyncStream<Void>.makeStream()
        let (actor, _, _, executor) = try await Self.authorisingActor(
            approvals: approvals, executorGate: gateStream)
        // Instant decisions blow past the transient authorising phase, so
        // await the STABLE end state: executing + exactly one emitted
        // approval request proves authorising happened with intent first.
        try await ActorFixtures.awaitPhase(actor, { $0.phase == .executing }, "executing after grant")
        // The executing phase is set before the actor's effect task records
        // the call, so bound-poll for the recorded dispatch rather than
        // assuming the scheduler ran the task first.
        for _ in 0..<2_000 where executor.calls.isEmpty {
            await Task.yield()
        }
        let state = await actor.currentState()
        #expect(state.pendingApproval == nil)
        #expect(state.liveReservations.count == 1, "grant reserves before dispatch")
        #expect(executor.calls.count == 1, "grant dispatches exactly one execution")
        #expect(approvals.requests.count == 1, "one approval requested on the way through")
        releaseGate.finish()
    }

    @Test("S2 store order: cause records precede pump consequences")
    func storeOrderCauseBeforeConsequence() async throws {
        // The outer transition's records must append BEFORE the pump-driven
        // validation records — M2 replays this log in order.
        let approvals = ScriptedApprovals()
        approvals.script = [.deny("stop here")]
        let (actor, _, store, _) = try await Self.authorisingActor(approvals: approvals)
        // Instant scripted decisions blow past transient authorising, so
        // await the STABLE end state; the store retains every record for
        // the order assertion below.
        try await ActorFixtures.awaitPhase(actor, {
            if case .failed = $0.phase { return true }
            return false
        }, "failed after deny")
        #expect(approvals.requests.count == 1, "one approval requested on the way through")
        let (entries, _) = try store.records(since: 0, limit: 100)
        let kinds = entries.map { entry -> String in
            if case .eventAppended(_, let kind, _) = entry.record { return kind }
            return "other"
        }
        guard let validating = kinds.firstIndex(of: "validating"),
              let authorising = kinds.firstIndex(of: "authorising") else {
            Issue.record("expected validating then authorising records, got \(kinds)"); return
        }
        #expect(validating < authorising, "cause precedes consequence: \(kinds)")
    }

    @Test("POLICY-04 trustedExec auto-allows; observe denies upfront")
    func POLICY_04_modesEndToEnd() async throws {
        // TrustedExec with an edit batch: no approval request is emitted.
        let trustedApprovals = ScriptedApprovals()
        trustedApprovals.script = [.deny("must never be asked")]
        let tTransport = ScriptedTransport()
        let (tActor, _) = try ActorFixtures.makeActor(mode: .trustedExec, permissive: true, transport: tTransport, executor: ScriptedExecutor(), approvals: trustedApprovals)
        tTransport.script = [ProviderResponse(
            requestID: RequestID("s"), generation: Revision(0),
            outcome: .textDeltaComplete(text: "calls", toolProposals: [
                ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"a\",\"expectedHash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"old_string\":\"hello\",\"new_string\":\"world\"}"),
            ], isFinal: false))]
        await tActor.submitText(commandID: CommandID("a-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(tActor, { $0.phase == .executing }, "trustedExec executing")
        #expect(trustedApprovals.requests.isEmpty, "no approval asked in trustedExec")
    }
}
