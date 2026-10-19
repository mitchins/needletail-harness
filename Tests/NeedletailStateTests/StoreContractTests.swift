import Testing
import Foundation
import NeedletailCore
import NeedletailTestSupport

/// Global writer slot + STORE-07/09 over the in-memory backend (variant
/// `in-memory`). The fencing assertion here is the SAME STORE-06 contract
/// the SQLite production store certifies.
struct StoreContractTests {

    private static let identity = WriterIdentity(
        session: SessionID("s-contract"), writer: "in-memory-1")

    @Test("STORE-07 in-memory transcript resume and list preserves order across pages")
    func STORE_07_inMemoryResumeListsInOrder() throws {
        let store = InMemorySessionStore()
        try store.claimWriterOwnership(session: Self.identity.session, writer: Self.identity.writer)
        try StoreContractAssertions.assertAppendOrderAndPagination(
            store, variant: "in-memory", identity: Self.identity)
    }

    @Test("STORE-06 fencing contract holds on the in-memory backend")
    func STORE_06_inMemoryFencingContract() throws {
        let store = InMemorySessionStore()
        try StoreContractAssertions.assertWriterFencing(
            first: store, second: store, variant: "in-memory")
    }

    @Test("STORE-09 in-memory store fills to quota then fails honestly")
    func STORE_09_inMemoryQuotaBoundary() throws {
        let store = InMemorySessionStore()
        try store.claimWriterOwnership(session: Self.identity.session, writer: Self.identity.writer)
        try StoreContractAssertions.assertQuotaBoundary(
            store, limit: InMemorySessionStore.recordCap, variant: "in-memory",
            identity: Self.identity)
    }

    @Test("A3-1 batch commit is all-or-nothing at the quota boundary")
    func batchCommitIsAtomicAtQuotaBoundary() throws {
        // Fill to 3 below the cap, then commit a 5-record group: the whole
        // group must fail and the log must be byte-identical to before —
        // a per-record loop would leave 3 partial rows.
        let store = InMemorySessionStore()
        try store.claimWriterOwnership(session: Self.identity.session, writer: Self.identity.writer)
        let fill = (0..<(InMemorySessionStore.recordCap - 3)).map { DurableRecord.transcriptAppended(.user("fill-\($0)")) }
        try store.appendBatch(fill, as: Self.identity)
        #expect(store.count == InMemorySessionStore.recordCap - 3)
        let group = (0..<5).map { DurableRecord.transcriptAppended(.user("group-\($0)")) }
        #expect(throws: StoreError.quotaExceeded(limit: InMemorySessionStore.recordCap)) {
            try store.appendBatch(group, as: Self.identity)
        }
        #expect(store.count == InMemorySessionStore.recordCap - 3, "failed group left no partial rows")
        let (page, _) = try store.records(session: Self.identity.session, since: UInt64(InMemorySessionStore.recordCap - 4), limit: 10)
        #expect(page.allSatisfy {
            if case .transcriptAppended(.user(let text)) = $0.record { return text.hasPrefix("fill-") }
            return false
        }, "tail of the log is all fill rows, no group rows")
    }
}
