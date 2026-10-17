import Foundation
#if canImport(Glibc)
import Glibc
#endif
import NeedletailCore

/// File-handle JSONL sink (M1-D D4). Writes versioned envelopes to a
/// FileHandle (stdout or trace file), write-through with no unbounded spool.
/// Broken pipe (EPIPE) maps to `UISinkError.brokenPipe`. Seq, payload, and
/// per-file write are allocated under one lock so concurrent producers
/// preserve ordering and never interleave bytes (H1).
public final class FileHandleUISink: UISink, @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let sessionID: String
    private var seq: UInt64 = 0
    private let ownsHandle: Bool

    public init(handle: FileHandle, sessionID: String, ownsHandle: Bool = false) {
        self.handle = handle
        self.sessionID = sessionID
        self.ownsHandle = ownsHandle
    }

    deinit {
        if ownsHandle { try? handle.close() }
    }

    public func emit(_ projection: SessionEventProjection) async throws {
        try lock.withLock {
            seq += 1
            let currentSeq = seq
            var payload: Any = projection.detail
            if projection.kind == "delta" {
                let parts = projection.detail
                    .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                    .map(String.init)
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
            var line = data
            line.append(0x0A)
            try Self.writeAll(line, to: handle)
        }
    }

    private static func writeAll(_ data: Data, to handle: FileHandle) throws {
#if canImport(Glibc)
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return write(handle.fileDescriptor, base.advanced(by: offset), data.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written == 0 {
                throw UISinkError.underlying("zero-byte sink write")
            }
            if errno == EINTR { continue }
            if errno == EPIPE { throw UISinkError.brokenPipe }
            throw UISinkError.underlying(String(cString: strerror(errno)))
        }
#else
        do {
            try handle.write(contentsOf: data)
        } catch let error as NSError {
            if let posix = error.userInfo["NSPOSIXErrorDomain"] as? Int, posix == EPIPE {
                throw UISinkError.brokenPipe
            }
            if errno == EPIPE {
                throw UISinkError.brokenPipe
            }
            throw UISinkError.underlying(error.localizedDescription)
        }
#endif
    }
}
