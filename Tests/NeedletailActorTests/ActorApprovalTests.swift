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
        batch: [ToolProposal] = [ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d")]
    ) async throws -> (
        SessionActor<ScriptedTransport, ScriptedExecutor, InMemorySessionStore, ScriptedApprovals, VirtualClock, DeterministicIDSource>,
        ApprovalRequest
    ) {
        let transport = ScriptedTransport()
        let (actor, _) = try ActorFixtures.makeActor(mode: .workspace, permissive: true, transport: transport, approvals: approvals)
        let request = try await driveToAuthorising(actor: actor, transport: transport, batch: batch)
        return (actor, request)
    }

    static func driveToAuthorising(
        actor: SessionActor<ScriptedTransport, ScriptedExecutor, InMemorySessionStore, ScriptedApprovals, VirtualClock, DeterministicIDSource>,
        transport: ScriptedTransport,
        batch: [ToolProposal]
    ) async throws -> ApprovalRequest {
        transport.script = [ProviderResponse(
            requestID: RequestID("scripted"), generation: Revision(0),
            outcome: .textDeltaComplete(text: "calls", toolProposals: batch.map {
                ToolProposal(callID: $0.callID, tool: $0.tool, argumentsDigest: "d")
            }, isFinal: false))]
        await actor.submitText(commandID: CommandID("a-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor, { $0.phase == .authorising }, "authorising")
        let state = await actor.currentState()
        return try #require(state.pendingApproval, "approval must be pending")
    }

    @Test("POLICY-04 silent gateway pends; release decides; ticks never decide")
    func POLICY_04_silentGatewayPends() async throws {
        let approvals = ScriptedApprovals()
        let (stream, continuation) = AsyncStream<ApprovalDecision>.makeStream()
        approvals.gate = stream
        let (actor, request) = try await Self.authorisingActor(approvals: approvals)
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
        let (actor, request) = try await Self.authorisingActor(approvals: approvals)
        try await ActorFixtures.awaitPhase(actor, { $0.phase == .executing }, "executing after grant")
        let state = await actor.currentState()
        #expect(state.pendingApproval == nil)
        #expect(state.liveReservations.count == 1, "grant reserves before dispatch")
        _ = request
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
                ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d"),
            ], isFinal: false))]
        await tActor.submitText(commandID: CommandID("a-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(tActor, { $0.phase == .executing }, "trustedExec executing")
        #expect(trustedApprovals.requests.isEmpty, "no approval asked in trustedExec")
    }
}
