import Testing
import Foundation
import NeedletailCore

/// Shared `SessionStore` contract assertions (M2-A A2: fencing + quotas +
/// STORE-07/09; STORE-06 is fenced here and certified per backend).
///
/// Assertions stay in Swift Testing; nothing here wraps or replaces them.
public enum StoreContractAssertions {

    /// Identity used by the shared assertions for the "current" writer.
    public static let primaryIdentity = WriterIdentity(
        session: SessionID("s-contract"), writer: "contract-primary")

    /// STORE-07 (and every backend): paged resume/list returns the full
    /// history in order across pages, honours `since` cursors, and ends
    /// with a nil cursor. The caller must have CLAIMED the identity's
    /// session on `store` first (fenced appends).
    public static func assertAppendOrderAndPagination(
        _ store: any SessionStore, variant: String,
        identity: WriterIdentity = primaryIdentity
    ) throws {
        let payloads = (0..<7).map { DurableRecord.transcriptAppended(.user("msg-\($0)")) }
        for record in payloads { try store.append(record, as: identity) }
        var pages: [[DurableRecord]] = []
        var cursor: UInt64? = 0
        // Bounded iteration: a store that never advances its cursor must
        // fail, never hang the runner.
        for _ in 0..<10 {
            guard let since = cursor else { break }
            let (page, next) = try store.records(session: identity.session, since: since, limit: 3)
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
        let (tail, tailNext) = try store.records(session: identity.session, since: 4, limit: 10)
        #expect(tail.map(\.record) == Array(payloads[4...]), "[\(variant)] since-cursor must replay the tail")
        #expect(tailNext == nil, "[\(variant)] tail read must end with a nil cursor")
        // Per-session sequences are strictly increasing and dense from 1
        // within the session's OWN log (global identity stays `seq`).
        let (all, _) = try store.records(session: identity.session, since: 0, limit: Int.max)
        #expect(all.map(\.sequence.value) == [1, 2, 3, 4, 5, 6, 7],
                "[\(variant)] per-session sequences must be dense from 1")
    }

    /// STORE-06 — the FENCING contract, run identically by every backend.
    /// `first` and `second` must share backing state (same instance for
    /// in-memory, two handles on the same file for SQLite — genuinely two
    /// live writers).
    ///
    /// Pinned: competing claim fails with BOTH identities; a stale writer's
    /// DURABLE WRITE fails closed (`.notWriter`), not just its claim; only
    /// the CURRENT writer can release (an old writer can never remove a
    /// newer writer's claim); crash-recovery re-claim with the SAME
    /// identity is idempotent; after release the other writer wins cleanly.
    public static func assertWriterFencing(
        first: any SessionStore, second: any SessionStore, variant: String
    ) throws {
        let session = SessionID("s-fenced")
        let writerA = "writer-a"
        let writerB = "writer-b"
        let identityA = WriterIdentity(session: session, writer: writerA)
        let identityB = WriterIdentity(session: session, writer: writerB)

        // A claims; B's competing claim learns BOTH identities.
        try first.claimWriterOwnership(session: session, writer: writerA)
        #expect(throws: StoreError.alreadyOwned(session: session.raw, writer: writerA)) {
            try second.claimWriterOwnership(session: session, writer: writerB)
        }
        // Same-identity reclaim is idempotent (crash-recovery re-acquire).
        try first.claimWriterOwnership(session: session, writer: writerA)

        // FENCED WRITE: B (stale) must fail a durable append.
        #expect(throws: StoreError.notWriter(session: session.raw, writer: writerB)) {
            try second.append(.transcriptAppended(.user("stale-b")), as: identityB)
        }
        // A (current) appends successfully — fencing is not a blanket veto.
        try first.append(.transcriptAppended(.user("live-a")), as: identityA)

        // STALE RELEASE: B can never remove A's claim.
        #expect(throws: StoreError.notWriter(session: session.raw, writer: writerB)) {
            try second.releaseWriterOwnership(session: session, writer: writerB)
        }
        // (Impersonation is unrepresentable at this API: the writer
        // identity IS the credential — `release(writer:)` can only ever
        // address the caller's own claim.)

        // A releases; B claims and writes — clean handover.
        try first.releaseWriterOwnership(session: session, writer: writerA)
        try second.claimWriterOwnership(session: session, writer: writerB)
        try second.append(.transcriptAppended(.user("live-b")), as: identityB)
        // A is now the STALE writer: writes AND release fail closed.
        #expect(throws: StoreError.notWriter(session: session.raw, writer: writerA)) {
            try first.append(.transcriptAppended(.user("stale-a")), as: identityA)
        }
        #expect(throws: StoreError.notWriter(session: session.raw, writer: writerA)) {
            try first.releaseWriterOwnership(session: session, writer: writerA)
        }

        // The log holds exactly the two accepted appends, in order.
        let (all, _) = try second.records(session: session, since: 0, limit: 100)
        #expect(all.map(\.record) == [
            .transcriptAppended(.user("live-a")),
            .transcriptAppended(.user("live-b")),
        ], "[\(variant)] only fenced-in appends persist, got \(all.map(\.record))")
        // Crash-recovery re-acquire: B re-claims its own live claim
        // idempotently, then releases.
        try second.claimWriterOwnership(session: session, writer: writerB)
        try second.releaseWriterOwnership(session: session, writer: writerB)
    }

    /// STORE-09 (in-memory tier): the store fills exactly to `limit`, then
    /// the next append fails honestly with `.quotaExceeded` — evidence is
    /// never silently dropped (R19). Fills from empty; callers pass a
    /// fresh store with a claimed identity.
    public static func assertQuotaBoundary(
        _ store: any SessionStore, limit: Int, variant: String,
        identity: WriterIdentity = primaryIdentity
    ) throws {
        for i in 0..<limit {
            try store.append(.transcriptAppended(.user("fill-\(i % 64)")), as: identity)
        }
        let (all, _) = try store.records(session: identity.session, since: 0, limit: limit + 1)
        #expect(all.count == limit, "[\(variant)] store must hold exactly \(limit) records, got \(all.count)")
        #expect(throws: StoreError.quotaExceeded(limit: limit)) {
            try store.append(.transcriptAppended(.user("overflow")), as: identity)
        }
    }
}
