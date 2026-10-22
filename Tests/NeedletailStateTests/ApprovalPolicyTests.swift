import Testing
import Foundation
import NeedletailCore

/// POLICY-04 pure rows + approval matrix + trust consistency (M1B2-5).
/// The exit-3 mapping is M1-D's; M1-B pins the outcome vocabulary,
/// `ApprovalRequest` shape, and the pending-forever (never auto-decide)
/// rule. Forbidden: hangs, auto-approval/denial, secret bytes in requests.
struct ApprovalPolicyTests {

    private static func permissiveEpoch() throws -> EpochDescriptor {
        try StateFixtures.epoch(permissive: true)
    }

    private static func authorisingState(
        mode: TrustMode, batch: ToolBatch, ids: inout DeterministicIDSource
    ) throws -> (SessionState, RunDescriptor) {
        // Permissive workspace grant (post-`trust` shape): approval tests
        // exercise ask-gating of GRANTED tools; deny-all denial paths are
        // pinned separately below.
        let epoch = try StateFixtures.epoch(permissive: true)
        _ = try validateTrustConsistency(mode: mode, caps: epoch.effectiveCaps.tools)
        var state = SessionState(sessionID: SessionID("s-a"), epoch: epoch, trustMode: mode, phase: .idle)
        state = transition(state, StateFixtures.input("run", id: "a-1"), &ids).state
        state = transition(state, .requestDispatched(requestID: state.activeRun!.requestID, atMillis: 1001), &ids).state
        state = transition(state, .requestStarted(requestID: state.activeRun!.requestID, generation: state.activeRun!.revision, atMillis: 1002), &ids).state
        let run = try #require(state.activeRun)
        let response = ProviderResponse(
            requestID: run.requestID, generation: run.revision,
            outcome: .textDeltaComplete(text: "calls", toolProposals: batch.proposals.map {
                ToolProposal(callID: $0.callID, tool: $0.tool, argumentsDigest: "d")
            }, isFinal: false))
        // Batch arrives pre-validated here; validationCompleted carries it.
        let validating = transition(state, .providerResponse(
            requestID: run.requestID, generation: run.revision, response: response, atMillis: 1003), &ids).state
        guard case .validatingTools = validating.phase else {
            Issue.record("expected validatingTools, got \(validating.phase)")
            throw FixtureFailure.admission
        }
        let authorised = transition(validating, .validationCompleted(
            requestID: run.requestID, generation: run.revision, batch: batch, atMillis: 1004), &ids).state
        return (authorised, run)
    }

    @Test("POLICY-04 approval matrix grants and denies per mode")
    func POLICY_04_approvalMatrix() throws {
        // Workspace mode: mutating batches need approval.
        var ids = StateFixtures.ids()
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"a\"}")])
        let (authorising, _) = try Self.authorisingState(mode: .workspace, batch: batch, ids: &ids)
        #expect(authorising.phase == .authorising, "workspace edit batch must hold for approval")
        #expect(authorising.pendingApproval != nil)
        // TrustedExec: same batch dispatches without approval.
        var ids2 = StateFixtures.ids(prefix: "u")
        let (executing, _) = try Self.authorisingState(mode: .trustedExec, batch: batch, ids: &ids2)
        #expect(executing.phase == .executing, "trustedExec edit batch proceeds, got \(executing.phase)")
        #expect(executing.liveReservations.count == 1, "intent reserved before dispatch")
    }

    @Test("POLICY-04 reads proceed, ask always asks, observe denies upfront")
    func POLICY_04_readsAskObserve() throws {
        var ids = StateFixtures.ids()
        let reads = ToolBatch([ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d", arguments: "{\"path\":\"a\"}")])
        let (workspaceReads, _) = try Self.authorisingState(mode: .workspace, batch: reads, ids: &ids)
        #expect(workspaceReads.phase == .executing, "workspace reads need no approval")
        var ids2 = StateFixtures.ids(prefix: "u")
        let askBatch = ToolBatch([ToolProposal(callID: "c2", tool: "exec", argumentsDigest: "d", arguments: "{}")])
        let (trustedAsk, _) = try Self.authorisingState(mode: .trustedExec, batch: askBatch, ids: &ids2)
        #expect(trustedAsk.phase == .authorising, "exec=ask always asks, even trusted")
        // Observe + exec-allowed caps is a contradictory session: refused at creation.
        let snapshot = try StateFixtures.snapshot()
        do {
            _ = try validateTrustConsistency(mode: .observe, caps: .allAllowed)
            Issue.record("observe with mutating grants must refuse creation")
        } catch let error as ConfigError {
            #expect(error.kind == .contradictoryFlags)
        }
    }

    @Test("POLICY-04 ungranted tools deny without approval")
    func POLICY_04_ungrantedToolsDeny() throws {
        // Deny-all workspace (production default until trust): an edit
        // batch is denied as a typed receipt — no approval asked, no hang.
        var ids = StateFixtures.ids()
        let idle = try StateFixtures.idle()
        var state = transition(idle, StateFixtures.input("run", id: "d-1"), &ids).state
        let run = try #require(state.activeRun)
        state = transition(state, .requestDispatched(requestID: run.requestID, atMillis: 1001), &ids).state
        state = transition(state, .requestStarted(requestID: run.requestID, generation: run.revision, atMillis: 1002), &ids).state
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"a\"}")])
        state = transition(state, .providerResponse(
            requestID: run.requestID, generation: run.revision,
            response: ProviderResponse(requestID: run.requestID, generation: run.revision,
                outcome: .textDeltaComplete(text: "calls", toolProposals: batch.proposals, isFinal: false)),
            atMillis: 1003), &ids).state
        guard case .validatingTools = state.phase else {
            Issue.record("expected validatingTools"); return
        }
        let denied = transition(state, .validationCompleted(
            requestID: run.requestID, generation: run.revision, batch: batch, atMillis: 1004), &ids)
        #expect(denied.state.phase == .requesting, "denied batch returns to requesting, got \(denied.state.phase)")
        #expect(denied.state.pendingApproval == nil, "no approval for ungranted tools")
    }

    @Test("POLICY-04 silent gateway leaves approval pending forever")
    func POLICY_04_silentGatewayPends() throws {
        var ids = StateFixtures.ids()
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"a\"}")])
        let (authorising, run) = try Self.authorisingState(mode: .workspace, batch: batch, ids: &ids)
        // Ticks (the only time source) never decide: still pending, no hang.
        var state = authorising
        for tick in [2000, 3000, 1_000_000] as [UInt64] {
            state = transition(state, .tick(nowMillis: tick), &ids).state
        }
        #expect(state.phase == .authorising, "silence never decides")
        #expect(state.pendingApproval?.requestID == run.requestID)
        // Late denial after silence still works (no hang, no auto-path taken).
        let denied = transition(state, .approvalDeny(
            requestID: run.requestID, generation: run.revision,
            reason: "no", atMillis: 2_000_000), &ids)
        guard case .failed(let failure) = denied.state.phase else {
            Issue.record("deny must stop the run"); return
        }
        guard case .approvalDenied = failure else {
            Issue.record("wrong failure: \(failure)"); return
        }
    }

    @Test("POLICY-04 approval request redacts hostile operation text")
    func POLICY_04_requestRedacted() throws {
        let request = ApprovalRequest(
            requestID: RequestID("r"), runID: RunID("run"), generation: Revision(1),
            operation: "exec \u{1B}[2J /bin/evil", requiredGrant: "exec")
        #expect(!request.operation.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
                "request text renders safe: \(request.operation)")
    }

    @Test("POLICY-03 sealed batches never reach authorising")
    func POLICY_03_sealedNeverAuthorises() throws {
        // A sealed run whose stream somehow proposes tools fails closed at
        // the authorising boundary — never approved, never executed.
        var ids = StateFixtures.ids()
        let idle = try StateFixtures.idle()
        var state = transition(idle, StateFixtures.input("sealed task", id: "s-1", sealed: true), &ids).state
        guard case .admitting = state.phase else {
            Issue.record("sealed plain text still admits"); return
        }
        let run = try #require(state.activeRun)
        state = transition(state, .requestDispatched(requestID: run.requestID, atMillis: 1001), &ids).state
        state = transition(state, .requestStarted(requestID: run.requestID, generation: run.revision, atMillis: 1002), &ids).state
        let response = ProviderResponse(
            requestID: run.requestID, generation: run.revision,
            outcome: .textDeltaComplete(text: "calls", toolProposals: [
                ToolProposal(callID: "evil", tool: "exec", argumentsDigest: "d", arguments: "{}"),
            ], isFinal: false))
        state = transition(state, .providerResponse(
            requestID: run.requestID, generation: run.revision, response: response, atMillis: 1003), &ids).state
        guard case .validatingTools = state.phase else {
            Issue.record("proposals must reach validation, got \(state.phase)"); return
        }
        let batch = try #require(state.pendingBatch)
        let closed = transition(state, .validationCompleted(
            requestID: run.requestID, generation: run.revision, batch: batch, atMillis: 1004), &ids)
        guard case .failed = closed.state.phase else {
            Issue.record("sealed proposals must fail closed, got \(closed.state.phase)"); return
        }
        #expect(closed.effects.allSatisfy {
            if case .requestApproval = $0 { return false }
            return true
        }, "no approval may ever be requested for sealed tools")
    }
}
