import Testing
import Foundation
import NeedletailCore
import NeedletailTestSupport

/// M1-D transcript rows (D1): the authoritative ordered conversation lives
/// as DurableRecords paged from the store (ARCH §1) — never duplicated
/// into SessionState. Pure mapping + paging contract, no sockets.
struct TranscriptTests {
    /// Fenced-append convenience for store seeding (A2 contract).
    private static func seed(_ store: InMemorySessionStore, _ identity: WriterIdentity, _ records: [DurableRecord]) throws {
        try store.claimWriterOwnership(session: identity.session, writer: identity.writer)
        for record in records { try store.append(record, as: identity) }
    }


    @Test("transcriptMessages maps the ordered conversation exactly")
    func transcriptMappingExact() throws {
        let records = [
            SequencedRecord(sequence: SequenceNumber(1), record: .transcriptAppended(.user("fix the bug"))),
            SequencedRecord(sequence: SequenceNumber(2), record: .eventAppended(seq: SequenceNumber(2), kind: "x", digest: "y")),
            SequencedRecord(sequence: SequenceNumber(3), record: .transcriptAppended(.assistantText("looking"))),
            SequencedRecord(sequence: SequenceNumber(4), record: .transcriptAppended(.toolCall(NativeToolCall(callID: "call-7", tool: "read", arguments: "{\"path\":\"f\"}")))),
            SequencedRecord(sequence: SequenceNumber(5), record: .transcriptAppended(.toolResponse(callID: "call-7", text: "bytes"))),
        ]
        let messages = try transcriptMessages(records)
        #expect(messages.count == 3, "non-transcript records never leak into the request")
        #expect(messages[0] == ChatMessage(role: .user, text: "fix the bug"))
        // Native shape: assistant text and its tool calls merge into ONE
        // assistant message (tool_calls live on it, not beside it).
        #expect(messages[1] == ChatMessage(
            role: .assistant, text: "looking",
            toolCalls: [NativeToolCall(callID: "call-7", tool: "read", arguments: "{\"path\":\"f\"}")]))
        #expect(messages[2] == ChatMessage(role: .tool, text: "bytes", toolCallID: "call-7"))
    }

    @Test("ToolProposal carries verbatim arguments beside the digest")
    func proposalCarriesArguments() throws {
        let proposal = ToolProposal(callID: "c", tool: "read", argumentsDigest: "abc", arguments: "{\"path\":\"f\"}")
        #expect(proposal.arguments == "{\"path\":\"f\"}", "executor reads this, never the digest")
        #expect(proposal.argumentsDigest == "abc", "digest stays for records")
        // Defaulted: every existing construction site keeps compiling.
        let legacy = ToolProposal(callID: "c", tool: "read", argumentsDigest: "abc")
        #expect(legacy.arguments == nil)
    }

    @Test("transcript pages from the store in seq order")
    func transcriptPagesFromStore() throws {
        let store = InMemorySessionStore()
        let identity = WriterIdentity(session: SessionID("s-t"), writer: "seed")
        try Self.seed(store, identity, [
            .transcriptAppended(.user("one")),
            .queueAdmitted(QueueEntry(
                entryID: "e-1", commandID: CommandID("c-1"), kind: .followUp,
                state: .held, revision: 1, text: "not-transcript",
                targetEpochID: EpochID("epoch-1"), orderKey: 0)),
            .transcriptAppended(.assistantText("two")),
        ])
        let messages = try loadTranscript(from: store, session: identity.session)
        #expect(messages.map(\.text) == ["one", "two"], "seq order, transcript kinds only")
    }

    @Test("over-limit transcript pages fail honest, never truncate")
    func transcriptPageOverflowHonest() throws {
        let store = InMemorySessionStore()
        let identity = WriterIdentity(session: SessionID("s-t"), writer: "seed")
        try Self.seed(store, identity, [
            .transcriptAppended(.user("a")),
            .transcriptAppended(.user("b")),
            .transcriptAppended(.user("c")),
        ])
        do {
            _ = try loadTranscript(from: store, session: identity.session, limit: 2)
            Issue.record("over-limit page must refuse")
        } catch let error as TranscriptError {
            #expect(error == .pageOverflow(limit: 2), "typed: \(error)")
        } catch {
            Issue.record("wrong error class: \(error)")
        }
    }
}
