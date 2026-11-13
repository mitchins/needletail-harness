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
        // Hold the executor gate open: without it `executing` is
        // transient (the canned executor auto-completes in one burst)
        // and the test races the scheduler for the observation window —
        // under load the window is missed and the single-response
        // non-final script then wedges the continuation pump
        // (POLICY-04 CI flake). The gate keeps `executing` observable;
        // `isFinal: true` describes the single complete turn (no phantom
        // continuation for the script to exhaust).
        let trustedApprovals = ScriptedApprovals()
        trustedApprovals.script = [.deny("must never be asked")]
        let tTransport = ScriptedTransport()
        let tExecutor = ScriptedExecutor()
        let (gateStream, releaseGate) = AsyncStream<Void>.makeStream()
        tExecutor.gate = gateStream
        let (tActor, _) = try ActorFixtures.makeActor(mode: .trustedExec, permissive: true, transport: tTransport, executor: tExecutor, approvals: trustedApprovals)
        tTransport.script = [ProviderResponse(
            requestID: RequestID("s"), generation: Revision(0),
            outcome: .textDeltaComplete(text: "calls", toolProposals: [
                ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"a\",\"expectedHash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"old_string\":\"hello\",\"new_string\":\"world\"}"),
            ], isFinal: true))]
        await tActor.submitText(commandID: CommandID("a-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(tActor, { $0.phase == .executing }, "trustedExec executing")
        #expect(trustedApprovals.requests.isEmpty, "no approval asked in trustedExec")
        #expect(tTransport.invocations.count == 1, "single turn, single invocation")
        releaseGate.finish()
    }

    @Test("POLICY-04 observe: mutating proposals deny upfront, never authorise")
    func POLICY_04_observeDeniesUpfront() async throws {
        // Observe mode with VALID caps (read/search only — observe +
        // mutating grants is refused at creation, pinned in
        // ApprovalPolicyTests): a mutating batch is denied by effective
        // capabilities as typed receipts — the run continues with a
        // provider continuation, and NOTHING reaches authorising or the
        // executor. (batchNeedsApproval(.observe) is false, so the
        // caps layer is the only thing standing between a mutating
        // proposal and dispatch — this leg proves it end to end.)
        // The recording executor is the decisive oracle: authorization
        // safety must be DEMONSTRATED (zero executor calls per proposal
        // + denial receipts in the transcript), not inferred from the
        // run completing.
        let approvals = ScriptedApprovals()
        approvals.script = [.deny("must never be asked")]
        let transport = GatedTransport()
        let (gateStream, gateContinuation) = AsyncStream<GatedTransport.TransportGateCommand>.makeStream()
        transport.gate = gateStream
        let recordingExecutor = ScriptedExecutor()
        let (actor, store) = try ActorFixtures.makeActor(mode: .observe, permissive: false, transport: transport, executor: recordingExecutor, approvals: approvals)
        // Drive via the gated transport: respond with the mutating
        // batch, then the denial continuation, then the final.
        await actor.submitText(commandID: CommandID("o-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitInvocations(transport, count: 1)
        let inv1 = transport.invocations[0]
        gateContinuation.yield(.respond(ProviderResponse(
            requestID: inv1.requestID, generation: inv1.generation,
            outcome: .textDeltaComplete(text: "calls", toolProposals: [
                ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"a\",\"expectedHash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"old_string\":\"h\",\"new_string\":\"w\"}"),
                ToolProposal(callID: "c2", tool: "exec", argumentsDigest: "d", arguments: "{\"executable\":\"/usr/bin/pytest\",\"argv\":[\"/usr/bin/pytest\",\"-q\"]}"),
                ToolProposal(callID: "c3", tool: "write", argumentsDigest: "d", arguments: "{\"path\":\"b\",\"content\":\"x\"}"),
            ], isFinal: false))))
        try await ActorFixtures.awaitInvocations(transport, count: 2)
        // The denial continuation is a provider request, never an
        // approval ask and never an execution.
        #expect(approvals.requests.isEmpty, "observe must not ask approval for mutating tools")
        #expect(recordingExecutor.calls.isEmpty, "edit/exec/write proposals must NEVER reach the executor in observe mode")
        // Deliver the final response (the denial continuation).
        let inv2 = transport.invocations[1]
        gateContinuation.yield(.respond(ProviderResponse(
            requestID: inv2.requestID, generation: inv2.generation,
            outcome: .textDeltaComplete(text: "denials delivered", toolProposals: [], isFinal: true))))
        gateContinuation.finish()
        try await ActorFixtures.awaitPhase(actor, {
            if case .completed = $0.phase { return true }
            return false
        }, "completed after typed denials")
        let final = await actor.currentState()
        #expect(final.pendingApproval == nil, "no approval request may linger")
        #expect(recordingExecutor.calls.isEmpty, "executor must still have zero calls after completion")
        // Denial receipts: the transcript carries one tool response per
        // proposal with the typed denial text (I05 — never silently
        // dropped). Records nest DurableRecord → transcript entry.
        let (records, _) = try store.records(session: SessionID("s-actor"), since: 0, limit: 10_000)
        var denialReceipts: [String] = []
        for sequenced in records {
            if case .transcriptAppended(.toolResponse(let callID, let text)) = sequenced.record,
               text.contains("denied by effective capabilities") {
                denialReceipts.append("\(callID): \(text)")
            }
        }
        #expect(denialReceipts.count == 3, "one typed denial receipt per proposal, got \(denialReceipts.count): \(denialReceipts)")
        for callID in ["c1", "c2", "c3"] {
            #expect(denialReceipts.contains { $0.hasPrefix("\(callID):") },
                "denial receipt must name \(callID)")
        }
        gateContinuation.finish()
    }

    @Test("HEAD-03 approval precedence: ask-gated schema-valid exec still asks")
    func HEAD_03_approvalPrecedenceAskGatedExec() async throws {
        // M2-C C0 (plan REV12 §3.2): HEAD-03's required OUTCOME is
        // preserved through the main path — a SCHEMA-VALID exec proposal
        // under an ask gate reaches the operator (authorising, one
        // approval request, no provider continuation), not a synthesized
        // continuation. The demo epoch (no resolver composed) approves
        // through the single-hop path with an `unresolved (demo)` display;
        // the two-phase resolved display is certified in C0ExecContractTests.
        let approvals = ScriptedApprovals()
        let (actor, transport, _, _) = try await Self.authorisingActor(
            approvals: approvals,
            batch: [ToolProposal(callID: "c1", tool: "exec", argumentsDigest: "d",
                                 arguments: "{\"executable\":\"/usr/bin/pytest\",\"argv\":[\"/usr/bin/pytest\",\"-q\"]}")])
        try await ActorFixtures.awaitPhase(actor, { $0.phase == .authorising }, "authorising for ask-gated exec")
        for _ in 0..<100_000 where approvals.requests.count < 1 {
            await Task.yield()
        }
        #expect(approvals.requests.count == 1, "exactly one approval request emitted")
        #expect(transport.invocations.count == 1, "no provider continuation past the gate")
        let pending = await actor.currentState()
        #expect(pending.pendingApproval != nil, "approval request is pending")
        #expect(pending.pendingApproval?.execIdentities.isEmpty == true, "demo path binds no identities (no resolver composed)")
    }

    @Test("HEAD-03 malformed exec is never approved (C0 counterfactual)")
    func HEAD_03_malformedExecNeverApproved() async throws {
        // MUST-FAIL PROBE (plan REV12 §3.2): reintroducing shape-blind
        // approval (the retired compatibility branch) makes this fail — a
        // malformed exec proposal must NEVER reach the operator, never
        // resolve, and never dispatch. Deterministic invalid-arguments
        // continuation only.
        let approvals = ScriptedApprovals()
        approvals.script = [.deny("must never be asked")]
        let transport = ScriptedTransport()
        let (actor, _) = try ActorFixtures.makeActor(mode: .workspace, permissive: true, transport: transport, approvals: approvals)
        transport.script = [ProviderResponse(
            requestID: RequestID("s"), generation: Revision(0),
            outcome: .textDeltaComplete(text: "calls", toolProposals: [
                ToolProposal(callID: "c1", tool: "exec", argumentsDigest: "d", arguments: "{\"command\":\"pytest\"}"),
                ToolProposal(callID: "c2", tool: "exec", argumentsDigest: "d", arguments: "{}"),
                ToolProposal(callID: "c3", tool: "exec", argumentsDigest: "d", arguments: "{\"executable\":\"pytest\",\"argv\":[\"pytest\"]}"),
            ], isFinal: false))]
        await actor.submitText(commandID: CommandID("a-1"), text: "run", kind: .followUp, sealed: false)
        for _ in 0..<100_000 where transport.invocations.count < 2 {
            await Task.yield()
        }
        #expect(approvals.requests.isEmpty, "no approval for malformed exec — validation precedes approval")
        #expect(transport.invocations.count == 2, "deterministic provider continuation after the typed rejection")
        let final = await actor.currentState()
        #expect(final.pendingApproval == nil, "no approval request pending")
        #expect(final.pendingResolution == nil && final.pendingExecIdentities == nil, "no resolution state leaked")
    }

    @Test("Precedence control: non-gated invalid batch still continues")
    func approvalPrecedenceControl() async throws {
        // A validation failure for a batch that needs NO approval keeps
        // the legacy behavior: deterministic provider continuation, no
        // approval request. (read with both artifact aliases is invalid
        // and never approval-gated.)
        let approvals = ScriptedApprovals()
        approvals.script = [.deny("must never be asked")]
        let transport = ScriptedTransport()
        let (actor, _) = try ActorFixtures.makeActor(mode: .workspace, permissive: true, transport: transport, approvals: approvals)
        transport.script = [ProviderResponse(
            requestID: RequestID("s"), generation: Revision(0),
            outcome: .textDeltaComplete(text: "calls", toolProposals: [
                ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d", arguments: "{\"artifactId\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"artifact_id\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}"),
            ], isFinal: false))]
        await actor.submitText(commandID: CommandID("a-1"), text: "run", kind: .followUp, sealed: false)
        for _ in 0..<100_000 where transport.invocations.count < 2 {
            await Task.yield()
        }
        #expect(transport.invocations.count == 2, "invalid non-gated batch synthesizes a provider continuation")
        #expect(approvals.requests.isEmpty, "no approval asked for a non-gated batch")
    }
}
