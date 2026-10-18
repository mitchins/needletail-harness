import Testing
import Foundation
import NeedletailCore
import NeedletailTestSupport

/// Global writer slot + STORE-07/09 over the in-memory backend (variant
/// `in-memory`).
/// Native durability is proven by the SQLite executions of the same shared
/// assertions in `NeedletailPrimitiveTests`; this file pins the semantics
/// every backend must share.
struct StoreContractTests {

    @Test("STORE-07 in-memory transcript resume and list preserves order across pages")
    func STORE_07_inMemoryResumeListsInOrder() throws {
        try StoreContractAssertions.assertAppendOrderAndPagination(
            InMemorySessionStore(), variant: "in-memory")
    }

    @Test("global writer slot: a competing session's claim fails with the exact owner (in-memory)")
    func SingleWriterSlot_inMemoryCompetingSessionLearnsOwner() throws {
        let store = InMemorySessionStore()
        try StoreContractAssertions.assertWriterOwnershipExclusive(
            first: store, second: store, variant: "in-memory")
    }

    @Test("STORE-09 in-memory store fills to quota then fails honestly")
    func STORE_09_inMemoryQuotaBoundary() throws {
        try StoreContractAssertions.assertQuotaBoundary(
            InMemorySessionStore(), limit: InMemorySessionStore.recordCap, variant: "in-memory")
    }
}
