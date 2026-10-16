import Foundation

/// M1-D JSONL sink (D4). Bounded, backpressure-aware, terminal-safe.
/// Every `emit` produces ONE newline-delimited JSON envelope:
/// `{format_version, session_id, seq, kind, payload}`. Deltas carry
/// `request_id` in payload. Seq is stamped sink-side, monotonic.
/// Write-through: no unbounded memory; a single write larger than the byte
/// cap fails honest. Broken pipe (EPIPE) surfaces as `UISinkError.brokenPipe`
/// so the CLI can cancel the run and exit 130 per SPEC §12.2.
public protocol UISink: Sendable {
    func emit(_ projection: SessionEventProjection) async throws
}

public enum UISinkError: Error, Sendable, Equatable {
    case overflow(itemCount: Int, byteCount: Int)
    case brokenPipe
    case underlying(String)
}

public final class NoopUISink: UISink, Sendable {
    public init() {}
    public func emit(_ projection: SessionEventProjection) async throws {}
}

/// In-memory sink for tests: bounded by item count and byte size
/// (mirrors `SessionStore.Budget.uiSpoolChannel` 128 / 512 KiB).
/// Thread-safe via lock. Seq, payload, and bounds are allocated under one
/// lock so concurrent emitters preserve ordering (H1).
public final class InMemoryUISink: UISink, @unchecked Sendable {
    public static let itemCap = 128
    public static let byteCap = 512 * 1024

    private let lock = NSLock()
    private var lines: [String] = []
    private var bufferedBytes: Int = 0
    private var seq: UInt64 = 0
    private let sessionID: String

    public init(sessionID: String = "test-session") {
        self.sessionID = sessionID
    }

    public var count: Int { lock.withLock { lines.count } }
    public var allLines: [String] { lock.withLock { lines } }

    public func emit(_ projection: SessionEventProjection) async throws {
        try lock.withLock {
            seq += 1
            let currentSeq = seq
            var payload: Any = projection.detail
            if projection.kind == "delta" {
                let parts = projection.detail.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                if parts.count == 2 {
                    payload = ["request_id": parts[0], "text": parts[1]]
                }
            }
            if projection.kind == "run_finished", let outcome = projection.outcome {
                payload = ["outcome": outcome, "reason": projection.detail]
            }
            let envelope: [String: Any] = [
                "format_version": 1,
                "session_id": sessionID,
                "seq": currentSeq,
                "kind": projection.kind,
                "payload": payload,
            ]
            let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
            guard let line = String(data: data, encoding: .utf8) else {
                throw UISinkError.underlying("utf8 encode failed")
            }
            let full = line + "\n"
            let bytes = full.utf8.count
            if lines.count + 1 > Self.itemCap || bufferedBytes + bytes > Self.byteCap {
                throw UISinkError.overflow(itemCount: lines.count + 1, byteCount: bufferedBytes + bytes)
            }
            lines.append(full)
            bufferedBytes += bytes
        }
    }
}
