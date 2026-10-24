import Testing
import Foundation
import NeedletailCore
import NeedletailTestSupport

/// B5 advertisement round-trip: the tools offered to the model are exactly
/// the capability-gated harness definitions, and a proposal using ONLY an
/// advertised tool reaches the executor through the real actor loop.
/// Execution still validates via ToolValidator (discovery is not
/// authorization): the executor here is scripted, but the proposal path
/// (transport → validation → approval → dispatch → executor) is production.
struct ToolAdvertisementRoundTripTests {

    @Test("advertised tools reach the executor; unadvertised tools are unoffered")
    func roundTrip() async throws {
        // Workspace caps the harness would intersect for a file-task run.
        let caps = ToolCapabilities(read: true, search: true, edit: true, write: true, exec: .ask, consult: false)
        let names = ToolAdvertisement.names(for: caps)
        #expect(names == ["read", "search", "edit", "write"], "harness offers exactly the four file tools, got \(names)")
        #expect(!names.contains("diff"), "diff is an operator command, never a model tool")

        let executor = ScriptedExecutor()
        let transport = ScriptedTransport()
        // Proposals use ONLY advertised names (read + edit).
        transport.script = [ProviderResponse(
            requestID: RequestID("scripted"), generation: Revision(0),
            outcome: .textDeltaComplete(text: "calls", toolProposals: [
                ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d", arguments: "{\"path\":\"a\"}"),
                ToolProposal(callID: "c2", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"a\",\"expectedHash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"old_string\":\"x\",\"new_string\":\"y\"}"),
            ], isFinal: false))]
        let approvals = ScriptedApprovals()
        approvals.script = [.approve]
        let actor = try SessionActor(
            state: ActorFixtures.idleState(mode: .workspace, permissive: true), ids: DeterministicIDSource(prefix: "ad"),
            clock: VirtualClock(now: 1_000_000),
            transport: transport, executor: executor, store: InMemorySessionStore(), approvals: approvals, writer: "ad-writer")
        await actor.submitText(commandID: CommandID("ad-1"), text: "run", kind: .followUp, sealed: false)
        try await ActorFixtures.awaitPhase(actor, { $0.phase == .executing }, "dispatch reached executing")
        for _ in 0..<100_000 where executor.calls.isEmpty { await Task.yield() }
        #expect(executor.calls.count == 1, "exactly one executor dispatch")
        #expect(executor.calls[0].batch.proposals.map(\.tool) == ["read", "edit"], "advertised proposals reach the executor")
        try await ActorFixtures.awaitPhase(actor, {
            $0.phase == .requesting && $0.liveReservations.isEmpty
        }, "completion continued the run")
    }
}
