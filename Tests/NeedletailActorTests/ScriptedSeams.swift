import Testing
import Foundation
import NeedletailCore
import NeedletailTestSupport

/// Scripted test seams (TESTING §5: tiny, explicit, no sleeps). Fakes never
/// auto-complete: the test driver releases every suspension explicitly, so
/// cancel-vs-completion orderings are deterministic driver choices, not
/// timing accidents.

enum ScriptedError: Error {
    case outOfScript
}

/// Immediate canned FIFO transport. Records every invocation.
final class ScriptedTransport: ModelTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _script: [ProviderResponse] = []
    private var _invocations: [ProviderInvocation] = []

    var script: [ProviderResponse] {
        get { lock.withLock { _script } }
        set { lock.withLock { _script = newValue } }
    }

    var invocations: [ProviderInvocation] {
        lock.withLock { _invocations }
    }

    func invoke(_ invocation: ProviderInvocation, intake: BoundedChannelState<ProviderResponse>) async throws -> TransportResult {
        lock.withLock { _invocations.append(invocation) }
        guard let next = lock.withLock({ _script.isEmpty ? nil : _script.removeFirst() }) else {
            throw ScriptedError.outOfScript
        }
        _ = intake
        return TransportResult(response: next)
    }
}

/// Manually released transport: suspends until the test releases it with a
/// result (or error). Proves suspension, cancellation and late-drop without
/// a single sleep.
final class GatedTransport: ModelTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _invocations: [ProviderInvocation] = []
    var gate: AsyncStream<TransportGateCommand>?

    var invocations: [ProviderInvocation] {
        lock.withLock { _invocations }
    }

    func invoke(_ invocation: ProviderInvocation, intake: BoundedChannelState<ProviderResponse>) async throws -> TransportResult {
        lock.withLock { _invocations.append(invocation) }
        _ = intake
        guard let gate = lock.withLock({ gate }) else {
            throw ScriptedError.outOfScript
        }
        for await command in gate {
            switch command {
            case .respond(let response):
                return TransportResult(response: response)
            case .fail:
                throw ScriptedError.outOfScript
            }
        }
        throw CancellationError()
    }

    enum TransportGateCommand: Sendable {
        case respond(ProviderResponse)
        case fail(String)
    }
}

/// Scripted approvals: FIFO decisions + request log. A missing script entry
/// suspends on the test-owned gate (never auto-decides).
final class ScriptedApprovals: ApprovalGateway, @unchecked Sendable {
    private let lock = NSLock()
    private var _script: [ApprovalDecision] = []
    private var _requests: [ApprovalRequest] = []

    var script: [ApprovalDecision] {
        get { lock.withLock { _script } }
        set { lock.withLock { _script = newValue } }
    }
    var gate: AsyncStream<ApprovalDecision>?

    var requests: [ApprovalRequest] {
        lock.withLock { _requests }
    }

    func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
        lock.withLock { _requests.append(request) }
        if let next = lock.withLock({ _script.isEmpty ? nil : _script.removeFirst() }) {
            return next
        }
        guard let gate = lock.withLock({ gate }) else {
            return .unavailable("no scripted decision and no gate")
        }
        for await decision in gate {
            return decision
        }
        return .unavailable("gate closed")
    }
}

/// Scripted executor: describes canned text; `execute` records and returns
/// a canned receipt. M1-D wires production execution through the actor, so
/// the executor auto-completes unless a test installs an explicit release
/// gate to hold the `executing` phase observable.
final class ScriptedExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(batch: ToolBatch, reservation: EffectReservation)] = []
    private var _gate: AsyncStream<Void>? = nil

    var calls: [(batch: ToolBatch, reservation: EffectReservation)] {
        lock.withLock { _calls }
    }

    var gate: AsyncStream<Void>? {
        get { lock.withLock { _gate } }
        set { lock.withLock { _gate = newValue } }
    }

    func describe(batch: ToolBatch) -> String {
        "scripted batch: \(batch.proposals.map(\.tool).joined(separator: ","))"
    }

    func execute(batch: ToolBatch, reservation: EffectReservation) async throws -> ExecutorResult {
        lock.withLock { _calls.append((batch, reservation)) }
        if let gate = lock.withLock({ _gate }) {
            for await _ in gate { break }
            // A closed gate releases execution exactly once; the loop exits.
        }
        return ExecutorResult(receipt: ExecutorReceipt(callID: "scripted", status: "ok", summary: "scripted"))
    }
}

/// Test-actor factory: deterministic IDs + frozen clock + in-memory store.
enum ActorFixtures {
    static func idleState(mode: TrustMode = .workspace, permissive: Bool = false) throws -> SessionState {
        let snapshot = try StateFixturesLike.snapshot()
        let profile = try #require(snapshot.profiles["local-coder"])
        let caps = effectiveCapabilities(
            build: .allAllowed, userConfig: snapshot.tools,
            workspaceGrant: (permissive || mode == .trustedExec) ? .allAllowed : .allDenied,
            invocationMask: .allAllowed, sealed: SealedRestrictions(sealed: false))
        _ = try validateTrustConsistency(mode: mode, caps: caps.tools)
        let route = selectRoute(snapshot: snapshot, requestedAlias: "local-coder", sealed: false)
        let epoch = EpochDescriptor(
            epochID: EpochID("epoch-1"), configSnapshot: snapshot, profile: profile,
            effectiveCaps: caps, route: route)
        return SessionState(sessionID: SessionID("s-actor"), epoch: epoch, trustMode: mode, phase: .idle)
    }

    static func makeActor(
        mode: TrustMode = .workspace, permissive: Bool = false,
        executor: ScriptedExecutor = ScriptedExecutor(),
        approvals: ScriptedApprovals = ScriptedApprovals()
    ) throws -> (
        SessionActor<ScriptedTransport, ScriptedExecutor, InMemorySessionStore, ScriptedApprovals, VirtualClock, DeterministicIDSource>,
        InMemorySessionStore
    ) {
        try makeActor(mode: mode, permissive: permissive, transport: ScriptedTransport(), executor: executor, approvals: approvals)
    }

    static func makeActor<T: ModelTransport>(
        mode: TrustMode = .workspace, permissive: Bool = false,
        transport: T,
        executor: ScriptedExecutor = ScriptedExecutor(),
        approvals: ScriptedApprovals = ScriptedApprovals()
    ) throws -> (
        SessionActor<T, ScriptedExecutor, InMemorySessionStore, ScriptedApprovals, VirtualClock, DeterministicIDSource>,
        InMemorySessionStore
    ) {
        let store = InMemorySessionStore()
        let actor = try SessionActor(
            state: try idleState(mode: mode, permissive: permissive), ids: DeterministicIDSource(prefix: "a"),
            clock: VirtualClock(now: 1_000_000),
            transport: transport, executor: executor, store: store, approvals: approvals, writer: "scripted-writer")
        return (actor, store)
    }

    /// Bounded invocation barrier (fails loudly, never sleeps): yields until
    /// the gated transport has recorded `count` invocations.
    static func awaitInvocations(_ transport: GatedTransport, count: Int) async throws {
        for _ in 0..<10_000 {
            if transport.invocations.count >= count { return }
            await Task.yield()
        }
        Issue.record("transport never reached \(count) invocations")
        throw ScriptedError.outOfScript
    }

    /// Bounded readiness barrier (fails loudly, never sleeps): yields until
    /// the actor state satisfies the check or the bound exhausts.
    static func awaitPhase<T: ModelTransport>(
        _ actor: SessionActor<T, ScriptedExecutor, InMemorySessionStore, ScriptedApprovals, VirtualClock, DeterministicIDSource>,
        _ check: (SessionState) -> Bool,
        _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<20_000 {
            if check(await actor.currentState()) { return }
            await Task.yield()
        }
        Issue.record("actor never reached \(label)", sourceLocation: sourceLocation)
        throw ScriptedError.outOfScript
    }

    static func finalResponse(requestID: RequestID, generation: Revision, text: String = "done") -> ProviderResponse {
        ProviderResponse(
            requestID: requestID, generation: generation,
            outcome: .textDeltaComplete(text: text, toolProposals: [], isFinal: true))
    }
}

/// M1-A snapshot builder, duplicated (not imported) so actor suites do not
/// depend on state-test internals.
enum StateFixturesLike {
    static let configJSON = """
        {"version":1,"default_model":"local-coder","allow_http_origins":["http://127.0.0.1:11434"],"models":[{"alias":"local-coder","protocol":"openai-chat-completions","base_url":"http://127.0.0.1:11434","model":"qwen","context_window":262144,"max_output":4096,"locality":"local","connect_timeout_s":10,"read_idle_timeout_s":300,"request_timeout_s":1800,"max_in_flight":1}],"tools":{"read":true,"search":true,"edit":true,"write":true,"exec":"ask","consult":false}}
        """

    static func snapshot() throws -> ConfigSnapshot {
        try validateConfig(Data(configJSON.utf8))
    }
}
