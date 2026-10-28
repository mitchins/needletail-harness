import Testing
import Foundation
import NeedletailTestSupport
@testable import NeedletailCore

/// M2-C C0 (plan REV12 §7-C0): the two-phase resolution seam through the
/// real actor loop — scripted transport/executor seams, a fake resolver.
/// NO exec child is spawned anywhere in this file.

private struct C0FakeResolver: ExecIdentityResolver, @unchecked Sendable {
    enum Mode: Sendable {
        case ok
        case fail(ExecResolutionError)
    }
    var mode: Mode
    var resolvedPath: String = "/usr/bin/python3.11"
    init(mode: Mode) { self.mode = mode }
    func resolveIdentities(batch: ToolBatch) throws -> [ResolvedExecIdentity] {
        switch mode {
        case .ok:
            return batch.proposals.filter { $0.tool == "exec" }.map {
                ResolvedExecIdentity(
                    callID: $0.callID, requestedPath: "/usr/bin/python3",
                    resolvedPath: resolvedPath, device: 1, inode: 2, size: 3,
                    contentDigest: String(repeating: "a", count: 64),
                    cwdDevice: 4, cwdInode: 5)
            }
        case .fail(let e):
            throw e
        }
    }
}

@Suite(.serialized)
struct C0TwoPhaseActorTests {

    private static let validExec = "{\"executable\":\"/usr/bin/python3\",\"argv\":[\"/usr/bin/python3\",\"-c\",\"print(1)\"]}"

    /// Exec-composed epoch (permissive grant; config exec=ask ⇒ effective
    /// .ask under composition) — the native two-phase path.
    private static func nativeState(execComposed: Bool) throws -> SessionState {
        let snapshot = try validateConfig(Data("""
        {"version":1,"default_model":"local-coder","allow_http_origins":["http://127.0.0.1:11434"],"models":[{"alias":"local-coder","protocol":"openai-chat-completions","base_url":"http://127.0.0.1:11434","model":"qwen","context_window":262144,"max_output":4096,"locality":"local","credential":{"env":"NT_KEY"},"connect_timeout_s":10,"read_idle_timeout_s":300,"request_timeout_s":1800,"max_in_flight":1}],"tools":{"read":true,"search":true,"edit":true,"write":true,"exec":"ask","consult":false}}
        """.utf8))
        let profile = try #require(snapshot.profiles["local-coder"])
        let caps = effectiveCapabilities(
            build: .allAllowed, userConfig: snapshot.tools,
            workspaceGrant: .allAllowed, invocationMask: .allAllowed,
            sealed: SealedRestrictions(sealed: false))
        let route = selectRoute(snapshot: snapshot, requestedAlias: "local-coder", sealed: false)
        let epoch = EpochDescriptor(
            epochID: EpochID("epoch-c0a"), configSnapshot: snapshot, profile: profile,
            effectiveCaps: caps, route: route, execComposed: execComposed)
        return SessionState(sessionID: SessionID("s-c0a"), epoch: epoch, trustMode: .workspace, phase: .idle)
    }

    private static func makeNativeActor(
        resolver: (any ExecIdentityResolver)?,
        approvals: ScriptedApprovals = ScriptedApprovals(),
        execComposed: Bool = true
    ) throws -> (SessionActor<ScriptedTransport, ScriptedExecutor, InMemorySessionStore, ScriptedApprovals, VirtualClock, DeterministicIDSource>, ScriptedTransport) {
        let transport = ScriptedTransport()
        let actor = try SessionActor(
            state: try nativeState(execComposed: execComposed), ids: DeterministicIDSource(prefix: "c0a"),
            clock: VirtualClock(now: 1_000_000),
            transport: transport, executor: ScriptedExecutor(), store: InMemorySessionStore(),
            approvals: approvals, writer: "c0a-writer", execResolver: resolver)
        return (actor, transport)
    }

    private static func submitExec(_ actor: SessionActor<ScriptedTransport, ScriptedExecutor, InMemorySessionStore, ScriptedApprovals, VirtualClock, DeterministicIDSource>, transport: ScriptedTransport, raw: String = Self.validExec) async {
        transport.script = [ProviderResponse(
            requestID: RequestID("s"), generation: Revision(0),
            outcome: .textDeltaComplete(text: "calls", toolProposals: [
                ToolProposal(callID: "c1", tool: "exec", argumentsDigest: "d", arguments: raw),
            ], isFinal: false))]
        await actor.submitText(commandID: CommandID("a-1"), text: "run", kind: .followUp, sealed: false)
    }

    @Test("two-phase: schema-valid exec resolves then asks with bound identities")
    func resolvedAsks() async throws {
        let approvals = ScriptedApprovals()
        let (actor, transport) = try Self.makeNativeActor(resolver: C0FakeResolver(mode: .ok), approvals: approvals)
        await Self.submitExec(actor, transport: transport)
        for _ in 0..<100_000 where approvals.requests.count < 1 { await Task.yield() }
        let pending = await actor.currentState()
        #expect(pending.phase == .authorising, "resolution hops to approval, got \(pending.phase)")
        #expect(approvals.requests.count == 1, "exactly one approval after resolution")
        #expect(pending.pendingResolution == nil, "hop 2 consumed the seed")
        let identities = try #require(pending.pendingApproval?.execIdentities)
        #expect(identities.count == 1)
        #expect(identities[0].callID == "c1")
        #expect(identities[0].resolvedPath == "/usr/bin/python3.11")
        #expect(pending.pendingApproval?.operation.contains("/usr/bin/python3.11") == true, "the approval displays the RESOLVED path")
        #expect(transport.invocations.count == 1, "no provider continuation past approval")
    }

    @Test("two-phase failure: batch-wide intent+result receipts, no approval, no hold")
    func failureReduction() async throws {
        let approvals = ScriptedApprovals()
        approvals.script = [.deny("must never be asked")]
        let (actor, transport) = try Self.makeNativeActor(
            resolver: C0FakeResolver(mode: .fail(.qualification("executable is world-writable"))),
            approvals: approvals)
        transport.script = [
            ProviderResponse(
                requestID: RequestID("s"), generation: Revision(0),
                outcome: .textDeltaComplete(text: "calls", toolProposals: [
                    ToolProposal(callID: "c1", tool: "exec", argumentsDigest: "d", arguments: Self.validExec),
                    ToolProposal(callID: "c2", tool: "read", argumentsDigest: "d", arguments: "{\"path\":\"b\"}"),
                ], isFinal: false)),
            // The continuation after the typed rejection completes cleanly.
            ProviderResponse(
                requestID: RequestID("s2"), generation: Revision(0),
                outcome: .textDeltaComplete(text: "done", toolProposals: [], isFinal: false)),
        ]
        await actor.submitText(commandID: CommandID("a-1"), text: "run", kind: .followUp, sealed: false)
        for _ in 0..<100_000 where transport.invocations.count < 2 { await Task.yield() }
        #expect(approvals.requests.isEmpty, "no approval for a failed resolution")
        #expect(transport.invocations.count == 2, "deterministic provider continuation")
        let final = await actor.currentState()
        #expect(final.unresolvedOperations.isEmpty, "NO holds: every result has a matching intent")
        #expect(final.pendingResolution == nil && final.pendingExecIdentities == nil, "no resolution state leaked")
    }

    @Test("nil resolver: fail-closed typed failure")
    func nilResolverFailsClosed() async throws {
        let approvals = ScriptedApprovals()
        approvals.script = [.deny("must never be asked")]
        let (actor, transport) = try Self.makeNativeActor(resolver: nil, approvals: approvals)
        transport.script = [
            ProviderResponse(
                requestID: RequestID("s"), generation: Revision(0),
                outcome: .textDeltaComplete(text: "calls", toolProposals: [
                    ToolProposal(callID: "c1", tool: "exec", argumentsDigest: "d", arguments: Self.validExec),
                ], isFinal: false)),
            ProviderResponse(
                requestID: RequestID("s2"), generation: Revision(0),
                outcome: .textDeltaComplete(text: "done", toolProposals: [], isFinal: false)),
        ]
        await actor.submitText(commandID: CommandID("a-1"), text: "run", kind: .followUp, sealed: false)
        for _ in 0..<100_000 where transport.invocations.count < 2 { await Task.yield() }
        #expect(approvals.requests.isEmpty, "no approval without a resolver")
        #expect(transport.invocations.count == 2, "typed continuation")
        let final = await actor.currentState()
        #expect(final.unresolvedOperations.isEmpty, "hold-free proven pre-dispatch failure")
    }

    @Test("demo gate: execComposed=false never resolves")
    func demoGateNeverResolves() async throws {
        let approvals = ScriptedApprovals()
        let (actor, transport) = try Self.makeNativeActor(resolver: C0FakeResolver(mode: .ok), approvals: approvals, execComposed: false)
        await Self.submitExec(actor, transport: transport)
        for _ in 0..<100_000 where approvals.requests.count < 1 { await Task.yield() }
        let pending = await actor.currentState()
        #expect(pending.phase == .authorising, "demo single-hop approval reached")
        #expect(pending.pendingApproval?.execIdentities.isEmpty == true, "demo binds no identities")
        #expect(pending.pendingApproval?.operation.contains("unresolved (demo)") == true, "demo display marked unresolved")
    }

    @Test("replayed resolution reply drops as stale (hop-2 consumption)")
    func replayedResolutionDrops() async throws {
        let approvals = ScriptedApprovals()
        let (actor, transport) = try Self.makeNativeActor(resolver: C0FakeResolver(mode: .ok), approvals: approvals)
        await Self.submitExec(actor, transport: transport)
        for _ in 0..<100_000 where approvals.requests.count < 1 { await Task.yield() }
        let before = await actor.currentState()
        let approvalsCount = approvals.requests.count
        // Replay the CONSUMED resolution: checkStale drops it (the seed is
        // gone), never double-applying the approval.
        await actor.applyExternalEvent(.execIdentitiesResolved(
            resolutionID: before.pendingResolution?.resolutionID ?? "consumed",
            runID: before.activeRun?.runID ?? RunID("x"),
            generation: before.activeRun?.revision ?? Revision(0),
            identities: [], atMillis: 1_000_001))
        let after = await actor.currentState()
        #expect(approvals.requests.count == approvalsCount, "replayed resolution event drops as stale")
        #expect(after.pendingApproval?.execIdentities.isEmpty == false, "bound identities unchanged")
        #expect(after.droppedStaleCount >= 1, "the drop is counted")
    }

    @Test("non-exec approval batches never resolve (hasExec gate)")
    func nonExecBatchNeverResolves() async throws {
        let approvals = ScriptedApprovals()
        // Silent gate: authorising is STABLE (an instant deny blows past it).
        let (stream, _) = AsyncStream<ApprovalDecision>.makeStream()
        approvals.gate = stream
        let (actor, transport) = try Self.makeNativeActor(resolver: C0FakeResolver(mode: .ok), approvals: approvals)
        transport.script = [ProviderResponse(
            requestID: RequestID("s"), generation: Revision(0),
            outcome: .textDeltaComplete(text: "calls", toolProposals: [
                ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d",
                             arguments: "{\"path\":\"a\",\"expectedHash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"old_string\":\"hello\",\"new_string\":\"world\"}"),
            ], isFinal: false))]
        await actor.submitText(commandID: CommandID("a-1"), text: "run", kind: .followUp, sealed: false)
        for _ in 0..<100_000 where approvals.requests.count < 1 { await Task.yield() }
        let pending = await actor.currentState()
        #expect(pending.phase == .authorising, "non-exec batch asks directly")
        #expect(pending.pendingResolution == nil, "no resolution seed for a non-exec batch")
        #expect(pending.pendingApproval?.execIdentities.isEmpty == true, "no identities for a non-exec batch")
    }
}
