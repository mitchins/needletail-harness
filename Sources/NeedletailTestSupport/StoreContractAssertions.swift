import Testing
import Foundation
import NeedletailCore

/// Shared `SessionStore` contract assertions (M2-0, STORE-06/07/09).
///
/// One definition, executed against every backing implementation (in-memory
/// in `NeedletailStateTests`, SQLite in `NeedletailPrimitiveTests`), so a
/// semantic drift in any backend fails the same assertion. Assertions stay
/// in Swift Testing; nothing here wraps or replaces them. `variant` labels
/// which backend produced the result for reconciliation.
public enum StoreContractAssertions {

    /// STORE-07: paged resume/list returns the full history in order across
    /// pages, honours `since` cursors, and ends with a nil cursor.
    public static func assertAppendOrderAndPagination(
        _ store: any SessionStore, variant: String
    ) throws {
        let payloads = (0..<7).map { DurableRecord.transcriptAppended(.user("msg-\($0)")) }
        for record in payloads { try store.append(record) }
        var pages: [[DurableRecord]] = []
        var cursor: UInt64? = 0
        // Bounded iteration: a store that never advances its cursor must
        // fail, never hang the runner.
        for _ in 0..<10 {
            guard let since = cursor else { break }
            let (page, next) = try store.records(since: since, limit: 3)
            pages.append(page.map(\.record))
            cursor = next
        }
        #expect(cursor == nil, "[\(variant)] pagination must terminate")
        // Every page except possibly the last is non-empty; an exact
        // multiple of the limit may end with an empty terminal page, which
        // contributes nothing to the resumed history.
        for page in pages.dropLast() {
            #expect(!page.isEmpty, "[\(variant)] non-terminal page must not be empty")
        }
        let resumed = pages.flatMap { $0 }
        #expect(resumed == payloads, "[\(variant)] resumed history must equal append order")
        // Resume from the middle replays only the tail.
        let (tail, tailNext) = try store.records(since: 4, limit: 10)
        #expect(tail.map(\.record) == Array(payloads[4...]), "[\(variant)] since-cursor must replay the tail")
        #expect(tailNext == nil, "[\(variant)] tail read must end with a nil cursor")
        // Sequences are strictly increasing and dense from 1.
        let (all, _) = try store.records(since: 0, limit: Int.max)
        #expect(all.map(\.sequence.value) == [1, 2, 3, 4, 5, 6, 7],
                "[\(variant)] sequences must be dense from 1")
    }

    /// STORE-06: two writers on the same session conflict; the loser learns
    /// the exact owner. `second` must share backing state with `first`
    /// (same instance for in-memory, second handle on the same file for
    /// SQLite) — otherwise the test proves nothing.
    public static func assertWriterOwnershipExclusive(
        first: any SessionStore, second: any SessionStore, variant: String
    ) throws {
        try first.claimWriterOwnership(session: SessionID("s1"))
        // A second writer loses while s1 holds the lock and learns the
        // exact owner. (Re-claiming the same session is an idempotent
        // no-op, not a conflict — only a DIFFERENT session contends.)
        #expect(throws: StoreError.alreadyOwned(session: "s1")) {
            try second.claimWriterOwnership(session: SessionID("s2"))
        }
        first.releaseWriterOwnership(session: SessionID("s1"))
        try second.claimWriterOwnership(session: SessionID("s2"))
    }

    /// STORE-09: the store fills exactly to `limit`, then the next append
    /// fails honestly with `.quotaExceeded` — evidence is never silently
    /// dropped (R19). Fills from empty; callers pass a fresh store.
    public static func assertQuotaBoundary(_ store: any SessionStore, limit: Int, variant: String) throws {
        for i in 0..<limit {
            try store.append(.transcriptAppended(.user("fill-\(i % 64)")))
        }
        let (all, _) = try store.records(since: 0, limit: limit + 1)
        #expect(all.count == limit, "[\(variant)] store must hold exactly \(limit) records, got \(all.count)")
        #expect(throws: StoreError.quotaExceeded(limit: limit)) {
            try store.append(.transcriptAppended(.user("overflow")))
        }
    }
}
