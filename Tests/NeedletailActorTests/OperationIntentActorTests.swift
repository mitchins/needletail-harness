import Testing
import Foundation
import NeedletailCore
import NeedletailTestSupport

/// A3-1 actor ordering: intent-before-effect, atomic group commit,
/// result-before-continuation. The scripted executor + a commit-gated
/// store double prove the ordering through the real actor loop.
/// Forbidden: executor dispatch without a committed intent, continuation
/// after an unpersisted result, success asserted on commit failure.
struct OperationIntentActorTests {

    /// Commit-gated store: delegates everything to InMemory except the
    /// batch commit, which throws BEFORE touching the log when the test's
    /// predicate matches — an atomic commit failure, never a partial one.
    /// Single-record `append` is deliberately UNGATED (the legacy
    /// non-atomic path): the actor must commit transition groups via
    /// `appendBatch`, so a regression to a per-record loop persists partial
    /// groups and these tests go RED.
    final class GatedCommitStore: SessionStore, @unchecked Sendable {
        private let inner = InMemorySessionStore()
        var failWhen: (@Sendable ([DurableRecord]) -> Bool)?

        func append(_ record: DurableRecord, as identity: WriterIdentity) throws {
            try inner.append(record, as: identity)
        }

        func appendBatch(_ records: [DurableRecord], as identity: WriterIdentity) throws {
            if let failWhen, failWhen(records) {
                throw StoreError.integrity("injected commit failure")
            }
            try inner.appendBatch(records, as: identity)
        }

        func records(session: SessionID, since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) {
            try inner.records(session: session, since: since, limit: limit)
        }

        func records(since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) {
            try inner.records(since: since, limit: limit)
        }

        func claimWriterOwnership(session: SessionID, writer: String) throws {
            try inner.claimWriterOwnership(session: session, writer: writer)
        }

        func releaseWriterOwnership(session: SessionID, writer: String) throws {
            try inner.releaseWriterOwnership(session: session, writer: writer)
        }

        var log: [DurableRecord] {
            get throws {
                let (page, _) = try inner.records(since: 0, limit: 100_000)
                return page.map(\.record)
            }
        }
    }

    private static func makeGatedActor(
        transport: ScriptedTransport = ScriptedTransport(),
        executor: ScriptedExecutor = ScriptedExecutor(),
        approvals: ScriptedApprovals = ScriptedApprovals()
    ) throws -> (
        SessionActor<ScriptedTransport, ScriptedExecutor, GatedCommitStore, ScriptedApprovals, VirtualClock, DeterministicIDSource>,
        ScriptedTransport, GatedCommitStore, ScriptedExecutor
    ) {
        let store = GatedCommitStore()
        let actor = try SessionActor(
            state: ActorFixtures.idleState(mode: .workspace, permissive: true), ids: DeterministicIDSource(prefix: "a"),
            clock: VirtualClock(now: 1_000_000),
            transport: transport, executor: executor, store: store, approvals: approvals, writer: "gated-writer")
        return (actor, transport, store, executor)
    }

    /// Tool intents only (callID-bearing): the admission intent is a
    /// provider-request marker, not a dispatchable operation.
    private static func intents(in log: [DurableRecord]) -> [OperationRef] {
        log.compactMap {
            if case .operationIntent(let ref) = $0, ref.callID != nil { return ref }
            return nil
        }
    }

    private typealias GatedActor = SessionActor<ScriptedTransport, ScriptedExecutor, GatedCommitStore, ScriptedApprovals, VirtualClock, DeterministicIDSource>

    /// Bounded readiness barrier for the gated actor (mirrors
    /// ActorFixtures.awaitPhase, which is typed to InMemorySessionStore).
    private static func awaitGatedPhase(
        _ actor: GatedActor, _ check: (SessionState) -> Bool, _ label: String
    ) async throws {
        for _ in 0..<20_000 {
            if check(await actor.currentState()) { return }
            await Task.yield()
        }
        Issue.record("actor never reached \(label)")
        throw ScriptedError.outOfScript
    }

    private static func results(in log: [DurableRecord]) -> [(OperationRef, String)] {
        log.compactMap {
            if case .operationResult(let ref, let outcome) = $0 { return (ref, outcome) }
            return nil
        }
    }

    @Test("A3-1 full loop correlates intent and result through the real actor")
    func fullLoopCorrelates() async throws {
        let approvals = ScriptedApprovals()
        approvals.script = [.approve]
        let (actor, transport, store, executor) = try Self.makeGatedActor(approvals: approvals)
        transport.script = [ProviderResponse(
            requestID: RequestID("scripted"), generation: Revision(0),
            outcome: .textDeltaComplete(text: "calls", toolProposals: [
                ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d"),
                ToolProposal(callID: "c2", tool: "read", argumentsDigest: "d"),
            ], isFinal: false))]
        await actor.submitText(commandID: CommandID("a-1"), text: "run", kind: .followUp, sealed: false)
        try await Self.awaitGatedPhase(actor, { $0.phase == .executing }, "dispatch reached executing")
        for _ in 0..<100_000 where executor.calls.isEmpty { await Task.yield() }
        #expect(executor.calls.count == 1, "exactly one executor dispatch, got \(executor.calls.count)")
        try await Self.awaitGatedPhase(actor, {
            $0.phase == .requesting && $0.liveReservations.isEmpty
        }, "completion continued the run")
        let log = try store.log
        let found = Self.intents(in: log)
        #expect(found.count == 2, "one intent per operation, got \(found.count)")
        let completed = Self.results(in: log).filter { $0.0.state == .done }
        #expect(Set(completed.map { $0.0.operationID }) == Set(found.map(\.operationID)),
                "results reuse the intent IDs")
        #expect(found.first(where: { $0.callID == "c1" })?.mutating == true, "edit dispatches mutating")
        #expect(found.first(where: { $0.callID == "c2" })?.mutating == false, "read dispatches non-mutating per-proposal")
        #expect(completed.first(where: { $0.0.callID == "c1" })?.0.mutating == true)
        #expect(completed.first(where: { $0.0.callID == "c2" })?.0.mutating == false)
    }

    @Test("A3-1 intent is committed before the executor can observe it")
    func intentCommittedBeforeExecution() async throws {
        let approvals = ScriptedApprovals()
        approvals.script = [.approve]
        let gateStream: AsyncStream<Void> = {
            let (stream, _) = AsyncStream<Void>.makeStream()
            return stream
        }()
        let executor = ScriptedExecutor()
        executor.gate = gateStream
        let (actor, transport, store, _) = try Self.makeGatedActor(executor: executor, approvals: approvals)
        transport.script = [ProviderResponse(
            requestID: RequestID("scripted"), generation: Revision(0),
            outcome: .textDeltaComplete(text: "calls", toolProposals: [
                ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d"),
            ], isFinal: false))]
        await actor.submitText(commandID: CommandID("a-1"), text: "run", kind: .followUp, sealed: false)
        try await Self.awaitGatedPhase(actor, { $0.phase == .executing }, "dispatch reached executing")
        // The executor is gated (blocked mid-execute): the intent must
        // ALREADY be durable — intent-before-effect through the real loop.
        for _ in 0..<100_000 where executor.calls.isEmpty { await Task.yield() }
        #expect(executor.calls.count == 1, "executor entered with the intent committed")
        #expect(Self.intents(in: try store.log).count == 1, "intent durable while execution still gated")
    }

    @Test("A3-1 failed intent commit dispatches nothing")
    func failedIntentCommitDispatchesNothing() async throws {
        let approvals = ScriptedApprovals()
        approvals.script = [.approve]
        let (actor, transport, store, executor) = try Self.makeGatedActor(approvals: approvals)
        // Fail the dispatch commit (the group carrying TOOL intents —
        // the admission intent is callID-less and must commit).
        store.failWhen = { records in records.contains {
            if case .operationIntent(let ref) = $0 { return ref.callID != nil }; return false
        } }
        transport.script = [ProviderResponse(
            requestID: RequestID("scripted"), generation: Revision(0),
            outcome: .textDeltaComplete(text: "calls", toolProposals: [
                ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d"),
            ], isFinal: false))]
        await actor.submitText(commandID: CommandID("a-1"), text: "run", kind: .followUp, sealed: false)
        try await Self.awaitGatedPhase(actor, {
            if case .failed = $0.phase { return true }; return false
        }, "intent commit failure fails the run")
        // Drain: give any wrongly-spawned execution a chance to appear —
        // the correct implementation never performs after a failed commit,
        // so this stays empty deterministically (not a sleep race).
        for _ in 0..<20_000 where executor.calls.isEmpty { await Task.yield() }
        #expect(executor.calls.isEmpty, "no durable intent means no external side effect")
        #expect(Self.intents(in: try store.log).isEmpty, "failed group left no partial intent")
        #expect(transport.invocations.count == 1, "only the admission request exists")
    }

    @Test("A3-1 failed result commit stops continuation without success")
    func failedResultCommitStopsContinuation() async throws {
        let approvals = ScriptedApprovals()
        approvals.script = [.approve]
        let (actor, transport, store, executor) = try Self.makeGatedActor(approvals: approvals)
        // Fail ONLY the completion commit (groups carrying done results).
        store.failWhen = { records in
            records.contains {
                if case .operationResult(let ref, _) = $0 { return ref.state == .done }
                return false
            }
        }
        transport.script = [ProviderResponse(
            requestID: RequestID("scripted"), generation: Revision(0),
            outcome: .textDeltaComplete(text: "calls", toolProposals: [
                ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d"),
            ], isFinal: false))]
        await actor.submitText(commandID: CommandID("a-1"), text: "run", kind: .followUp, sealed: false)
        try await Self.awaitGatedPhase(actor, {
            if case .failed = $0.phase { return true }; return false
        }, "result commit failure fails the run")
        #expect(executor.calls.count == 1, "the side effect possibly executed — evidence must survive")
        // Drain: any wrongly-continued provider request appears here; the
        // correct implementation performs nothing after the failed commit.
        for _ in 0..<20_000 where transport.invocations.count < 2 { await Task.yield() }
        #expect(transport.invocations.count == 1, "no continuation request after an unpersisted result")
        let log = try store.log
        let intentIDs = Set(Self.intents(in: log).map(\.operationID))
        #expect(intentIDs.count == 1, "the dispatch-time intent stands alone")
        let doneIDs = Set(Self.results(in: log).filter { $0.0.state == .done }.map { $0.0.operationID })
        #expect(doneIDs.isEmpty, "no success result persisted — the unmatched intent reconciles to unknown later")
        let state = await actor.currentState()
        #expect(state.turnsUsed == 1, "admission consumed turn 1; the unpersisted continuation consumed none")
        if case .failed(let failure) = state.phase {
            #expect("\(failure)".contains("unresolved"), "failure names the unresolved outcome, got \(failure)")
        } else {
            Issue.record("expected failed phase")
        }
    }

    @Test("A3-1 unpersisted results become unknown markers that block fresh runs")
    func unpersistedResultsBecomeUnknownMarkers() async throws {
        let approvals = ScriptedApprovals()
        approvals.script = [.approve]
        let (actor, transport, store, executor) = try Self.makeGatedActor(approvals: approvals)
        // Fail ONLY the completion commit (groups carrying done results).
        store.failWhen = { records in
            records.contains {
                if case .operationResult(let ref, _) = $0 { return ref.state == .done }
                return false
            }
        }
        transport.script = [ProviderResponse(
            requestID: RequestID("scripted"), generation: Revision(0),
            outcome: .textDeltaComplete(text: "calls", toolProposals: [
                ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d"),
            ], isFinal: false))]
        await actor.submitText(commandID: CommandID("a-1"), text: "run", kind: .followUp, sealed: false)
        try await Self.awaitGatedPhase(actor, {
            if case .failed = $0.phase { return true }; return false
        }, "result commit failure fails the run")
        // The unpersisted done result is a possible side effect with no
        // durable outcome: it must survive as an unknown marker carrying
        // the result's identity, and the queue must hold.
        let state = await actor.currentState()
        let unknowns = state.unresolvedOperations.filter { $0.state == .unknown }
        #expect(!unknowns.isEmpty, "unpersisted results become unknown markers")
        #expect(unknowns.allSatisfy { $0.callID == "c1" && $0.mutating },
                "markers preserve the result identity (callID, mutating), got \(unknowns)")
        #expect(state.queueHeld, "queue held after unpersisted results")
        // A fresh operator input must NOT dispatch: the failed-phase
        // reset to idle still leaves the markers, so admission holds
        // instead of starting a new provider request.
        let invocations = transport.invocations.count
        await actor.submitText(commandID: CommandID("a-2"), text: "again", kind: .followUp, sealed: false)
        for _ in 0..<20_000 where transport.invocations.count == invocations { await Task.yield() }
        #expect(transport.invocations.count == invocations,
                "held queue admits no new provider request after unpersisted results")
        #expect(executor.calls.count == 1, "no second dispatch after unpersisted results")
    }

    @Test("A3-1 unpersisted non-mutating results take no markers and hold nothing")
    func unpersistedNonMutatingResultsTakeNoMarkers() async throws {
        let approvals = ScriptedApprovals()
        approvals.script = [.approve]
        let (actor, transport, store, _) = try Self.makeGatedActor(approvals: approvals)
        // Fail ONLY the completion commit (groups carrying done results).
        store.failWhen = { records in
            records.contains {
                if case .operationResult(let ref, _) = $0 { return ref.state == .done }
                return false
            }
        }
        // Read-only batch: the done result is non-mutating (no possible
        // side effect), so the failed commit must fail plainly — markers
        // and holds are for unknown side effects, not lost readouts.
        transport.script = [ProviderResponse(
            requestID: RequestID("scripted"), generation: Revision(0),
            outcome: .textDeltaComplete(text: "calls", toolProposals: [
                ToolProposal(callID: "c9", tool: "read", argumentsDigest: "d"),
            ], isFinal: false))]
        await actor.submitText(commandID: CommandID("a-1"), text: "read run", kind: .followUp, sealed: false)
        try await Self.awaitGatedPhase(actor, {
            if case .failed = $0.phase { return true }; return false
        }, "result commit failure fails the run")
        let state = await actor.currentState()
        #expect(state.unresolvedOperations.isEmpty, "non-mutating results take no unknown markers")
        #expect(!state.queueHeld, "no markers means no hold — the run fails plainly")
        if case .failed = state.phase { } else {
            Issue.record("expected failed phase")
        }
    }
}
