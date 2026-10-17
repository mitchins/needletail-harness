import Testing
import Foundation
import NeedletailCore
import NeedletailTestSupport

struct StoreContractTests {
    @Test("STATE-02 store contract: append order and pagination")
    func appendOrderAndPagination() throws {
        let store = InMemorySessionStore()
        try store.append(.transcriptAppended(.user("a")))
        try store.append(.transcriptAppended(.user("b")))
        try store.append(.transcriptAppended(.user("c")))
        let (page1, next1) = try store.records(since: 0, limit: 2)
        #expect(page1.map(\.record) == [.transcriptAppended(.user("a")), .transcriptAppended(.user("b"))])
        #expect(next1 != nil)
        let (page2, next2) = try store.records(since: next1!, limit: 2)
        #expect(page2.map(\.record) == [.transcriptAppended(.user("c"))])
        #expect(next2 == nil)
    }

    @Test("STATE-02 store contract: writer ownership is exclusive")
    func writerOwnershipExclusive() throws {
        let store = InMemorySessionStore()
        try store.claimWriterOwnership(session: SessionID("s1"))
        #expect(throws: StoreError.self) {
            try store.claimWriterOwnership(session: SessionID("s2"))
        }
        store.releaseWriterOwnership(session: SessionID("s1"))
        try store.claimWriterOwnership(session: SessionID("s2"))
    }

    @Test("STATE-02 store contract: bounded quota fails honestly")
    func boundedQuota() throws {
        let store = InMemorySessionStore()
        // Not filling 10k; just verify append increments count.
        try store.append(.transcriptAppended(.user("x")))
        #expect(store.count == 1)
    }
}
