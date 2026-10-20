import Foundation
import GRDB
import NeedletailCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A5-2 STORE-08 bounded session export (SPEC §9.1–9.2): a read-only,
/// session-scoped VIEW of durable records as versioned JSONL. An export
/// is never written back, never re-ingested, never authoritative.
///
/// CONFIDENTIALITY MODEL (explicit allowlist, never denylist+regex):
/// the default export carries structural metadata and redacted event
/// summaries only — event kinds, IDs, states, flags and digests travel;
/// every free-text payload (authored messages, tool arguments/results,
/// run receipts, recovery reasons) is replaced by `"[redacted]"` or
/// omitted, with an explicit `"redacted": true` marker so redaction is
/// distinguishable from absence. Epoch/config snapshots, routes and
/// capability maps are NEVER serialized (only epoch/parent IDs and the
/// profile alias travel). `--include-content` additionally carries the
/// operator/model/tool text fields listed in `projectRecord`, marks the
/// export `sensitive` AND `content-bearing`, and still excludes:
/// credentials (no credential values exist in the ledger and none are
/// harvested), native raw provider payloads (never persisted — the
/// actor's raw ring is not a DurableRecord and is unreadable here),
/// epoch/config snapshots, and recovery free-text rationale.
///
/// Unknown outcomes stay unknown: operation states travel verbatim
/// (`.unknown` is preserved, never resolved), and the trailer lists
/// completed vs held vs unstarted operation IDs so support can
/// identify incomplete work without seeing private contents.
public enum SessionExport {

    /// Explicit, finite bounds: a ledger beyond either bound fails
    /// closed instead of silently truncating. `maxRecords` caps the
    /// record count; `maxBytes` caps ALL materialized bytes — output
    /// lines AND decoded source rows (a redacted export of huge
    /// confidential fields retains the full source in memory while
    /// emitting almost nothing, so output bytes alone do not bound
    /// retention). Production defaults are safety rails, not quotas;
    /// tests inject small limits through the same code path.
    public struct Limits: Sendable {
        public var maxRecords: Int
        public var maxBytes: Int

        public init(maxRecords: Int, maxBytes: Int) {
            self.maxRecords = maxRecords
            self.maxBytes = maxBytes
        }

        public static let `default` = Limits(maxRecords: 250_000, maxBytes: 256 * 1024 * 1024)
    }

    public enum ExportError: Error, Equatable {
        /// No database file at the path (nothing to read, nothing created).
        case missingStore(String)
        /// Not a store, foreign schema, future version, or a schema that
        /// would require migration (exports never migrate).
        case unreadableStore(String)
        /// The session has no records in this store.
        case unknownSession(String)
        case recordLimitExceeded(limit: Int)
        case byteLimitExceeded(limit: Int)
        /// The target path already exists (any kind, including symlinks) —
        /// exports never overwrite.
        case targetExists(String)
        case outputUnwritable(String)
    }

    /// Redaction marker: content withheld by policy, not absent data.
    public static let redacted = "[redacted]"

    /// Writer identity, hashed — never the raw token. Writer IDs are bearer
    /// authority inside the store's fencing (whoever presents the pair may
    /// write), so an export must not carry them verbatim, in EITHER mode:
    /// equality is preserved (same writer → same hash, correlatable across
    /// exports) while the token itself stays out of support artifacts.
    /// Operators with legitimate DB access can recompute the hash to
    /// identify a holder.
    private static func writerTokenHash(_ writer: String) -> String {
        String(artifactSHA256Hex(Data(writer.utf8)).prefix(16))
    }

    /// Allowlisted projection of one sequenced record. ONLY the keys
    /// constructed here may appear in export output; every free-text
    /// payload is either omitted (with `"redacted": true`) or, with
    /// `includeContent`, carried verbatim under its documented key.
    /// A schema test pins the full key vocabulary, so a new field fails
    /// loudly instead of leaking silently.
    public static func project(_ sequenced: SequencedRecord, includeContent: Bool) -> [String: Any] {
        let seq = sequenced.sequence.value
        switch sequenced.record {
        case .sessionOpened(let session, let atMillis):
            return ["seq": seq, "kind": "session",
                    "session": session.raw, "atMillis": atMillis]
        case .epochOpened(let epoch):
            // Epoch/config snapshots, routes and capability maps NEVER
            // travel — only the epoch identity and the profile alias.
            var row: [String: Any] = ["seq": seq, "kind": "epoch",
                                      "epochID": epoch.epochID.raw,
                                      "profile": epoch.profile.alias]
            if let parent = epoch.parentEpochID {
                row["parentEpochID"] = parent.raw
            }
            return row
        case .eventAppended(let eventSeq, let kind, let digest):
            return ["seq": seq, "kind": "event",
                    "eventSeq": eventSeq.value, "eventKind": kind, "digest": digest]
        case .operationIntent(let ref):
            return ["seq": seq, "kind": "intent",
                    "operationID": ref.operationID.raw,
                    "callID": ref.callID as Any,
                    "state": "intent", "mutating": ref.mutating]
        case .operationResult(let ref, let outcome):
            // State travels verbatim (unknown stays unknown); the receipt
            // text is free-form tool output.
            let state: String
            switch ref.state {
            case .intent: state = "intent"
            case .unknown: state = "unknown"
            case .done: state = "done"
            }
            return ["seq": seq, "kind": "result",
                    "operationID": ref.operationID.raw,
                    "callID": ref.callID as Any,
                    "state": state, "mutating": ref.mutating,
                    "outcome": includeContent ? outcome : redacted]
        case .queueAdmitted(let entry):
            return queueRow(seq: seq, action: "admitted", entry: entry, includeContent: includeContent)
        case .queueUpdated(let entry):
            return queueRow(seq: seq, action: "updated", entry: entry, includeContent: includeContent)
        case .checkpointCommitted(let epoch):
            var row: [String: Any] = ["seq": seq, "kind": "checkpoint",
                                      "epochID": epoch.epochID.raw,
                                      "profile": epoch.profile.alias]
            if let parent = epoch.parentEpochID {
                row["parentEpochID"] = parent.raw
            }
            return row
        case .transcriptAppended(let entry):
            return transcriptRow(seq: seq, entry: entry, includeContent: includeContent)
        case .writerRecovered(let recovery):
            // Structural audit facts travel; free-text rationale never
            // does (not even with --include-content): reasons are operator
            // prose that may incidentally quote sensitive context. Writer
            // identities travel ONLY as truncated hashes (session fencing
            // treats the raw pair as bearer authority, so the token itself
            // never enters a support artifact). The authorizing identity
            // and reference travel only with --include-content.
            var unresolved: [[String: Any]] = []
            for ref in recovery.unresolvedOperations {
                let state: String
                switch ref.state {
                case .intent: state = "intent"
                case .unknown: state = "unknown"
                case .done: state = "done"
                }
                unresolved.append(["operationID": ref.operationID.raw,
                                   "callID": ref.callID as Any,
                                   "state": state, "mutating": ref.mutating])
            }
            var row: [String: Any] = ["seq": seq, "kind": "recovery",
                                      "previousWriterHash": writerTokenHash(recovery.previousWriter),
                                      "newWriterHash": writerTokenHash(recovery.newWriter),
                                      "atMillis": recovery.atMillis,
                                      "unresolved": unresolved,
                                      "reason": redacted]
            if includeContent {
                row["operatorID"] = recovery.operatorID
                row["reference"] = recovery.reference
            } else {
                row["operatorID"] = redacted
                row["reference"] = redacted
            }
            return row
        case .artifactPublished(let ref):
            // The reference only — bytes never enter export output (they
            // are not in the database to begin with).
            var row: [String: Any] = ["seq": seq, "kind": "artifact",
                                      "digest": ref.digest, "size": ref.size,
                                      "artifactKind": ref.kind,
                                      "relativePath": ref.relativePath]
            if let operation = ref.operationID {
                row["operationID"] = operation.raw
            }
            return row
        }
    }

    private static func queueRow(seq: UInt64, action: String, entry: QueueEntry, includeContent: Bool) -> [String: Any] {
        var row: [String: Any] = ["seq": seq, "kind": "queue", "action": action,
                                  "entryID": entry.entryID,
                                  "commandID": entry.commandID.raw,
                                  "queueKind": entry.kind.rawValue,
                                  "state": entry.state.rawValue,
                                  "revision": entry.revision,
                                  "targetEpochID": entry.targetEpochID.raw,
                                  "orderKey": entry.orderKey,
                                  "sealed": entry.sealed]
        if includeContent {
            row["text"] = entry.text
            row["redacted"] = false
        } else {
            row["redacted"] = true
        }
        return row
    }

    private static func transcriptRow(seq: UInt64, entry: TranscriptEntry, includeContent: Bool) -> [String: Any] {
        switch entry {
        case .user(let text):
            var row: [String: Any] = ["seq": seq, "kind": "transcript", "role": "user"]
            if includeContent {
                row["text"] = text
                row["redacted"] = false
            } else {
                row["redacted"] = true
            }
            return row
        case .assistantText(let text):
            var row: [String: Any] = ["seq": seq, "kind": "transcript", "role": "assistant"]
            if includeContent {
                row["text"] = text
                row["redacted"] = false
            } else {
                row["redacted"] = true
            }
            return row
        case .toolCall(let call):
            // The tool name is structural; arguments are free text.
            var row: [String: Any] = ["seq": seq, "kind": "tool-call",
                                      "callID": call.callID, "tool": call.tool]
            if includeContent {
                row["arguments"] = call.arguments
                row["redacted"] = false
            } else {
                row["redacted"] = true
            }
            return row
        case .toolResponse(let callID, let text):
            var row: [String: Any] = ["seq": seq, "kind": "tool-response", "callID": callID]
            if includeContent {
                row["text"] = text
                row["redacted"] = false
            } else {
                row["redacted"] = true
            }
            return row
        }
    }

    // MARK: - Session stream export (read-only)

    /// Reads a session's whole durable stream through a READ-ONLY handle
    /// and returns versioned JSONL lines: a header, one line per record in
    /// global-sequence order, and a closing trailer. Read-only is
    /// structural (SQLite enforces it) — no claim, no release, no
    /// migration, no row is ever written. A corrupt/foreign/future/legacy
    /// schema fails closed here, before any output exists.
    ///
    /// The trailer carries an operation summary computed with the real
    /// `reconcileOperations` contract (completed vs held vs unstarted
    /// operation IDs only — no contents), so support can identify
    /// incomplete or unresolved work. An invalid ledger fails the whole
    /// export: support diagnostics never certify a corrupt session.
    public static func lines(
        dbPath: String, session: SessionID, includeContent: Bool, exportedAt: UInt64,
        limits: Limits = .default
    ) throws -> [String] {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw ExportError.missingStore(dbPath)
        }
        var configuration = Configuration()
        configuration.readonly = true
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: dbPath, configuration: configuration)
        } catch {
            throw ExportError.unreadableStore("cannot open \(dbPath) read-only: \(error)")
        }
        defer { try? queue.close() }
        let version: Int32
        do {
            version = try queue.read { db in
                try Int32.fetchOne(db, sql: "PRAGMA user_version") ?? -1
            }
        } catch {
            throw ExportError.unreadableStore("cannot inspect \(dbPath): \(error)")
        }
        guard version == GRDBSessionStore.schemaVersion else {
            throw ExportError.unreadableStore(
                "\(dbPath) has schema version \(version), this build reads \(GRDBSessionStore.schemaVersion) read-only; open it with needletail run to migrate first")
        }
        // Declared-shape check (same contract as the production opener —
        // a same-versioned foreign or tampered store fails here, before
        // any record is read): exact columns, types and primary keys.
        do {
            try queue.read { db in
                try GRDBSessionStore.assertSchemaShape(db)
            }
        } catch let error as StoreError {
            throw ExportError.unreadableStore("schema mismatch in \(dbPath): \(error)")
        } catch {
            throw ExportError.unreadableStore("cannot inspect \(dbPath): \(error)")
        }
        // Count first: an over-limit ledger fails before any output
        // exists, and the trailer count is authoritative.
        let total: Int
        do {
            total = try queue.read { db in
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM records WHERE session = ?",
                    arguments: [session.raw]) ?? 0
            }
        } catch {
            throw ExportError.unreadableStore("cannot page \(dbPath): \(error)")
        }
        guard total > 0 else {
            throw ExportError.unknownSession(session.raw)
        }
        guard total <= limits.maxRecords else {
            throw ExportError.recordLimitExceeded(limit: limits.maxRecords)
        }
        var lines: [String] = []
        var bytes = 0
        func emit(_ object: [String: Any]) throws {
            let data = try JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            guard var line = String(data: data, encoding: .utf8) else {
                throw ExportError.unreadableStore("unencodable export row")
            }
            line += "\n"
            bytes += line.utf8.count
            guard bytes <= limits.maxBytes else {
                throw ExportError.byteLimitExceeded(limit: limits.maxBytes)
            }
            lines.append(line)
        }
        try emit(["format": "needletail-session-export", "version": 1,
                  "kind": "header", "session": session.raw,
                  "exportedAt": exportedAt, "content": includeContent,
                  "sensitive": true])
        var stream: [DurableRecord] = []
        var sourceBytes = 0
        var cursor: UInt64 = 0
        while true {
            let rows: [Row]
            do {
                rows = try queue.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT seq, payload FROM records
                        WHERE session = ? AND seq > ? ORDER BY seq LIMIT 500
                        """, arguments: [session.raw, cursor])
                }
            } catch {
                throw ExportError.unreadableStore("cannot page \(dbPath): \(error)")
            }
            if rows.isEmpty { break }
            for row in rows {
                guard let seq: Int64 = row["seq"], seq >= 0,
                      let payload: String = row["payload"],
                      let data = payload.data(using: .utf8) else {
                    throw ExportError.unreadableStore("corrupt record row")
                }
                let record: DurableRecord
                do {
                    record = try RecordCodec.decode(data)
                } catch {
                    throw ExportError.unreadableStore("undecodable record row: \(error)")
                }
                // Source bytes count against the same budget as output
                // bytes: decoded rows accumulate in `stream` for the
                // end-of-stream reconcile, so unbounded source payloads
                // would otherwise bypass the byte limit entirely.
                sourceBytes += data.count
                guard sourceBytes <= limits.maxBytes else {
                    throw ExportError.byteLimitExceeded(limit: limits.maxBytes)
                }
                stream.append(record)
                try emit(project(SequencedRecord(
                    sequence: SequenceNumber(UInt64(seq)), record: record), includeContent: includeContent))
                cursor = UInt64(seq)
                guard stream.count <= limits.maxRecords else {
                    throw ExportError.recordLimitExceeded(limit: limits.maxRecords)
                }
            }
            if rows.count < 500 { break }
        }
        let report: OperationReconciliation
        do {
            report = try reconcileOperations(stream)
        } catch {
            throw ExportError.unreadableStore("session ledger fails reconciliation: \(error)")
        }
        // Completeness is asserted, not assumed: fewer streamed records
        // than counted means rows vanished mid-export (or a tampered
        // sequence) — never certify a partial stream as complete.
        guard stream.count >= total else {
            throw ExportError.unreadableStore("exported \(stream.count) of \(total) records; refusing partial output")
        }
        try emit(["kind": "trailer", "complete": true, "recordCount": stream.count,
                  "operations": ["completed": report.completed.map(\.raw),
                                 "held": report.heldOperations.map { $0.operationID.raw },
                                 "unstarted": report.unmatchedNonMutating.map(\.raw),
                                 "orphaned": report.orphanResults.map { $0.operationID.raw }]])
        return lines
    }

    /// Reads only the final line of a file (bounded 1 MiB tail window,
    /// O(1) memory regardless of export size): used to verify the export
    /// trailer without re-materializing the whole export. A trailer that
    /// does not fit the window fails verification (fail-closed).
    private static func readLastLine(ofFileAtPath path: String) throws -> String {
        let handle: FileHandle
        do {
            guard let opened = FileHandle(forReadingAtPath: path) else {
                throw ExportError.outputUnwritable("cannot verify \(path)")
            }
            handle = opened
        }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = min(end, 1 << 20)
        let start = end >= window ? end - window : 0
        try handle.seek(toOffset: start)
        guard let chunk = try handle.readToEnd(), !chunk.isEmpty else {
            throw ExportError.outputUnwritable("cannot verify \(path)")
        }
        let text = String(decoding: chunk, as: UTF8.self)
        // The file ends with "\n", so the last non-empty line is the
        // complete final line, unless the file was torn, in which case
        // the trailer check below fails closed.
        guard let last = text.split(separator: "\n", omittingEmptySubsequences: true).last else {
            throw ExportError.outputUnwritable("cannot verify \(path)")
        }
        return String(last)
    }

    /// Writes exported lines atomically and privately: a uniquely-named
    /// tmp file in the target directory (fsync, verified by re-reading
    /// the trailer), then an atomic link into place (link() fails if the
    /// target exists — never overwritten, never followed if it is a
    /// symlink), then directory sync. Any failure removes the tmp file;
    /// the target path never holds a partial export. A failed directory
    /// sync removes the just-linked target too: without a durable
    /// directory entry the export must not be mistaken for complete.
    public static func writeLines(_ lines: [String], toFileAtPath target: String) throws {
        var parent = (target as NSString).deletingLastPathComponent
        if parent.isEmpty {
            // Bare filenames ("out.jsonl") land in the working directory.
            parent = "."
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent, isDirectory: &isDir), isDir.boolValue else {
            throw ExportError.outputUnwritable("parent directory missing or not a directory: \(parent)")
        }
        if FileManager.default.fileExists(atPath: target)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: target)) != nil {
            throw ExportError.targetExists(target)
        }
        let tmp = parent + "/.export-" + UUID().uuidString + ".tmp"
        do {
            guard FileManager.default.createFile(
                atPath: tmp, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw ExportError.outputUnwritable("cannot create tmp file in \(parent)")
            }
            guard let handle = FileHandle(forWritingAtPath: tmp) else {
                try? FileManager.default.removeItem(atPath: tmp)
                throw ExportError.outputUnwritable("cannot open tmp file \(tmp)")
            }
            do {
                for line in lines {
                    try handle.write(contentsOf: Data(line.utf8))
                }
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(atPath: tmp)
                throw ExportError.outputUnwritable("cannot write \(target): \(error)")
            }
            // Verify before publishing: the trailer must be present and
            // claim completeness, or this file never becomes the export.
            // Only the tail is read (bounded, O(1) regardless of export
            // size): a truncation anywhere upstream necessarily corrupts
            // or removes the final complete trailer line.
            guard let trailerLine = try? Self.readLastLine(ofFileAtPath: tmp),
                  let trailerData = trailerLine.data(using: .utf8),
                  let trailer = try? JSONSerialization.jsonObject(with: trailerData) as? [String: Any],
                  (trailer["complete"] as? Bool) == true,
                  (trailer["recordCount"] as? Int) == lines.count - 2 else {
                try? FileManager.default.removeItem(atPath: tmp)
                throw ExportError.outputUnwritable("export verification failed for \(target)")
            }
            // Atomic commit: hard-link into place. Only EEXIST means
            // "target appeared"; any other errno is an output failure.
            let linked: Int32 = tmp.withCString { tmpC in
                target.withCString { targetC in
                    link(tmpC, targetC)
                }
            }
            guard linked == 0 else {
                let err = errno
                try? FileManager.default.removeItem(atPath: tmp)
                if err == EEXIST {
                    throw ExportError.targetExists(target)
                }
                throw ExportError.outputUnwritable("cannot link export into place \(target): errno \(err)")
            }
            try? FileManager.default.removeItem(atPath: tmp)
            do {
                try syncArtifactDirectory(atPath: parent)
            } catch {
                // Durability uncertain: remove the just-linked target
                // rather than leave an export that may not survive.
                try? FileManager.default.removeItem(atPath: target)
                throw ExportError.outputUnwritable("cannot sync export directory \(parent): \(error)")
            }
        }
    }
}
