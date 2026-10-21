import Testing
import Foundation
import NeedletailCore
import NeedletailRuntime
import NeedletailTestSupport

/// A2 isolation regression (review finding A): two sessions sharing one
/// database file must not see each other's records — session-scoped reads
/// and the transcript-loading path must be incapable of returning
/// forbidden cross-session content.
struct SessionIsolationTests {

    @Test("two sessions in one store: forbidden cross-session content never crosses")
    func twoSessionsStayIsolated() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("needletail-iso-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBSessionStore(
            path: directory.appendingPathComponent("store.sqlite").path)

        let identityA = WriterIdentity(session: SessionID("s-alpha"), writer: "w-alpha")
        let identityB = WriterIdentity(session: SessionID("s-beta"), writer: "w-beta")
        for identity in [identityA, identityB] {
            try store.claimWriterOwnership(session: identity.session, writer: identity.writer)
        }
        try store.append(.transcriptAppended(.user("AAA-only")), as: identityA)
        try store.append(.transcriptAppended(.user("BBB-FORBIDDEN")), as: identityB)
        try store.append(.transcriptAppended(.assistantText("alpha-private")), as: identityA)
        try store.append(.transcriptAppended(.user("BBB-FORBIDDEN-2")), as: identityB)

        // Session-scoped read: only alpha's records, in order.
        let (pageA, _) = try store.records(
            session: identityA.session, since: 0, limit: 100)
        #expect(pageA.map(\.record) == [
            DurableRecord.transcriptAppended(.user("AAA-only")),
            DurableRecord.transcriptAppended(.assistantText("alpha-private")),
        ], "session A must see exactly its own records, got \(pageA.map(\.record))")
        for record in pageA {
            if case .transcriptAppended(.user(let text)) = record.record {
                #expect(!text.contains("FORBIDDEN"), "forbidden content leaked into session A read")
            }
        }
        let (pageB, _) = try store.records(
            session: identityB.session, since: 0, limit: 100)
        for record in pageB {
            if case .transcriptAppended(let entry) = record.record,
               entry != TranscriptEntry.user("BBB-FORBIDDEN"),
               entry != TranscriptEntry.user("BBB-FORBIDDEN-2") {
                Issue.record("forbidden cross-session content in session B: \(entry)")
            }
        }

        // The MODEL-REQUEST path (loadTranscript) is equally incapable of
        // returning the other session's conversation.
        let transcriptA = try loadTranscript(
            from: store, session: identityA.session, limit: 100)
        #expect(transcriptA.map(\.text) == ["AAA-only", "alpha-private"],
                "alpha transcript must contain only alpha content, got \(transcriptA.map(\.text))")
        #expect(!transcriptA.contains { $0.text.contains("FORBIDDEN") },
                "forbidden content leaked into alpha's model request")

        // Paging through the scoped cursor never crosses sessions.
        let (page1, cursor1) = try store.records(
            session: identityB.session, since: 0, limit: 1)
        #expect(page1.count == 1)
        let next = try #require(cursor1, "two rows at limit 1 must leave a cursor")
        let (page2, cursor2) = try store.records(
            session: identityB.session, since: next, limit: 100)
        #expect(page2.map(\.record) == [DurableRecord.transcriptAppended(.user("BBB-FORBIDDEN-2"))])
        #expect(cursor2 == nil, "session B's second page ends its own log")
    }
}
