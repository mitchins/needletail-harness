import Testing
import Foundation
import NeedletailCore
import NeedletailTestSupport

/// M1-D transcript emission rows (D1): transitions append the ordered
/// conversation (user → assistant text/calls → tool responses) as
/// DurableRecords. Deterministic: same events, same records. Replayed
/// through a real store, the records must map to the exact wire messages.
struct TranscriptEmissionTests {

    @Test("full text-plus-tool turn emits the ordered transcript")
    func fullTurnEmitsTranscript() throws {
        var ids = StateFixtures.ids()
        let epoch = try StateFixtures.epoch(permissive: true)
        var state = SessionState(sessionID: SessionID("s-t"), epoch: epoch, trustMode: .trustedExec, phase: .idle)
        var emitted: [DurableRecord] = []
        func step(_ event: SessionEvent) {
            let out = transition(state, event, &ids)
            state = out.state
            emitted += out.records
        }
        // Dispatch: operator text opens the transcript.
        step(StateFixtures.input("read the file", id: "a-1"))
        step(.requestDispatched(requestID: state.activeRun!.requestID, atMillis: 1001))
        step(.requestStarted(requestID: state.activeRun!.requestID, generation: state.activeRun!.revision, atMillis: 1002))
        let run = try #require(state.activeRun)
        // Provider turn: assistant text + one verbatim call.
        step(.providerResponse(
            requestID: run.requestID, generation: run.revision,
            response: ProviderResponse(
                requestID: run.requestID, generation: run.revision,
                outcome: .textDeltaComplete(
                    text: "reading now",
                    toolProposals: [ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d", arguments: "{\"path\":\"f\"}")],
                    isFinal: false)),
            atMillis: 1003))
        guard case .validatingTools = state.phase else {
            Issue.record("expected validatingTools, got \(state.phase)"); return
        }
        // Authorise + dispatch (trustedExec read proceeds), then complete.
        step(.validationCompleted(
            requestID: run.requestID, generation: run.revision,
            batch: ToolBatch([ToolProposal(callID: "c1", tool: "read", argumentsDigest: "d", arguments: "{\"path\":\"f\"}")]),
            atMillis: 1004))
        guard case .executing = state.phase else {
            Issue.record("expected executing, got \(state.phase)"); return
        }
        let reservation = try #require(state.liveReservations.first(where: { !$0.batch.proposals.isEmpty }))
        step(.effectCompleted(
            effectID: reservation.effectID, runID: run.runID, generation: run.revision,
            expectedRevision: run.revision, mutating: false,
            outcome: .success("file-bytes"), atMillis: 1005))
        guard case .requesting = state.phase else {
            Issue.record("expected requesting after completion, got \(state.phase)"); return
        }
        // Replay through a real store: order + verbatim arguments survive.
        let store = InMemorySessionStore()
        let identity = WriterIdentity(session: SessionID("s-e"), writer: "emit")
        try store.claimWriterOwnership(session: identity.session, writer: identity.writer)
        for record in emitted { try store.append(record, as: identity) }
        let messages = try loadTranscript(from: store, session: identity.session)
        #expect(messages.count == 3, "user + assistant-with-call + tool response: \(messages)")
        #expect(messages[0] == ChatMessage(role: .user, text: "read the file"))
        #expect(messages[1] == ChatMessage(
            role: .assistant, text: "reading now",
            toolCalls: [NativeToolCall(callID: "c1", tool: "read", arguments: "{\"path\":\"f\"}")]))
        #expect(messages[2] == ChatMessage(role: .tool, text: "file-bytes", toolCallID: "c1"))
    }

    @Test("denied proposals join the transcript as refusals")
    func deniedProposalsRecorded() throws {
        var ids = StateFixtures.ids()
        // Workspace + deny-all: every tool denies upfront.
        let epoch = try StateFixtures.epoch(permissive: false)
        _ = try validateTrustConsistency(mode: .workspace, caps: epoch.effectiveCaps.tools)
        var state = SessionState(sessionID: SessionID("s-d"), epoch: epoch, trustMode: .workspace, phase: .idle)
        state = transition(state, StateFixtures.input("edit it", id: "a-1"), &ids).state
        state = transition(state, .requestDispatched(requestID: state.activeRun!.requestID, atMillis: 1001), &ids).state
        state = transition(state, .requestStarted(requestID: state.activeRun!.requestID, generation: state.activeRun!.revision, atMillis: 1002), &ids).state
        let run = try #require(state.activeRun)
        let response = ProviderResponse(
            requestID: run.requestID, generation: run.revision,
            outcome: .textDeltaComplete(
                text: "",
                toolProposals: [ToolProposal(callID: "c9", tool: "edit", argumentsDigest: "d", arguments: "{}")],
                isFinal: false))
        let out = transition(state, .providerResponse(
            requestID: run.requestID, generation: run.revision, response: response, atMillis: 1003), &ids)
        guard case .validatingTools = out.state.phase else {
            Issue.record("expected validatingTools, got \(out.state.phase)"); return
        }
        let authorised = transition(out.state, .validationCompleted(
            requestID: run.requestID, generation: run.revision,
            batch: ToolBatch([ToolProposal(callID: "c9", tool: "edit", argumentsDigest: "d", arguments: "{}")]),
            atMillis: 1004), &ids)
        guard case .requesting = authorised.state.phase else {
            Issue.record("denied batch must return to requesting, got \(authorised.state.phase)"); return
        }
        let entries = authorised.records.compactMap { record -> TranscriptEntry? in
            if case .transcriptAppended(let entry) = record { return entry }
            return nil
        }
        #expect(entries.contains(where: {
            if case .toolResponse(let id, let text) = $0 {
                return id == "c9" && text.contains("denied")
            }
            return false
        }), "denial must reach the transcript or the model loops: \(entries)")
    }
}
