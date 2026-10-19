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
}
