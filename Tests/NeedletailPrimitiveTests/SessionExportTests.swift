import Testing
import Foundation
import GRDB
import NeedletailCore
@testable import NeedletailRuntime
import NeedletailTestSupport

/// STORE-08 bounded session export: an explicit allowlist projects each
/// durable record to JSON-safe metadata; free text travels ONLY with
/// --include-content, and credentials, raw provider payloads, epoch
/// snapshots, routes, capability maps and recovery rationale NEVER
/// travel. Two interleaved sessions prove scoping; seeded sentinels
/// prove redaction field-by-field.
struct SessionExportTests {

    // MARK: - Fixtures

    private static func freshDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("needletail-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Epoch whose SOURCE config carries a confidential base URL: the
    /// projection must drop it while keeping identity + profile alias.
    private static func epochWithSentinelBaseURL() throws -> EpochDescriptor {
        let configJSON = """
            {"version":1,"default_model":"local-coder","allow_http_origins":["http://127.0.0.1:11434"],"models":[{"alias":"local-coder","protocol":"openai-chat-completions","base_url":"http://127.0.0.1:11434/x-SECRET-BASE-88","model":"qwen","context_window":262144,"max_output":4096,"locality":"local","credential":{"env":"NT_M2B_KEY"},"connect_timeout_s":10,"read_idle_timeout_s":300,"request_timeout_s":1800,"max_in_flight":1}],"tools":{"read":true,"search":true,"edit":true,"write":true,"exec":"ask","consult":false}}
            """
        let snapshot = try validateConfig(Data(configJSON.utf8))
        let profile = try #require(snapshot.profiles["local-coder"])
        let caps = effectiveCapabilities(
            build: .allAllowed, userConfig: snapshot.tools,
            workspaceGrant: .allAllowed, invocationMask: .allAllowed,
            sealed: SealedRestrictions(sealed: false))
        let route = selectRoute(snapshot: snapshot, requestedAlias: "local-coder", sealed: false)
        return EpochDescriptor(
            epochID: EpochID("epoch-1"), parentEpochID: nil,
            configSnapshot: snapshot, profile: profile,
            effectiveCaps: caps, route: route)
    }

    private static func toolIntent(_ id: String, call: String?, mutating: Bool) -> DurableRecord {
        .operationIntent(OperationRef(
            operationID: OperationID(id), callID: call, state: .intent, mutating: mutating))
    }

    private static func toolResult(
        _ id: String, call: String?, mutating: Bool, state: OperationState, outcome: String
    ) -> DurableRecord {
        .operationResult(OperationRef(
            operationID: OperationID(id), callID: call, state: state, mutating: mutating), outcome: outcome)
    }

    /// Rich two-session ledger through the REAL store. Session A carries
    /// every content-bearing shape with synthetic sentinels; session B is
    /// the cross-session isolation probe.
    private static func seedRichLedger(_ store: GRDBSessionStore) throws -> (SessionID, SessionID) {
        let sessionA = SessionID("s-export-a")
        let sessionB = SessionID("s-export-b")
        try store.claimWriterOwnership(session: sessionA, writer: "w-seed")
        try store.claimWriterOwnership(session: sessionB, writer: "w-seed-b")
        let idA = WriterIdentity(session: sessionA, writer: "w-seed")
        let epoch = try epochWithSentinelBaseURL()
        try store.appendBatch([
            .sessionOpened(session: sessionA, atMillis: 1000),
            .epochOpened(epoch),
            .transcriptAppended(.user("hello ALPHA-111")),
            .transcriptAppended(.assistantText("answer BETA-222")),
            .transcriptAppended(.user("my token is hunter2-CRED-999")),
            .transcriptAppended(.toolCall(NativeToolCall(callID: "c1", tool: "read", arguments: "{\"path\":\"/secret/GAMMA-333\"}"))),
            .transcriptAppended(.toolResponse(callID: "c1", text: "file DELTA-444")),
            Self.toolIntent("e1/c1", call: "c1", mutating: true),
            Self.toolResult("e1/c1", call: "c1", mutating: true, state: .done, outcome: "receipt EPSILON-555"),
            Self.toolIntent("e1/c2", call: "c2", mutating: true),
            Self.toolIntent("e1/c7", call: "c7", mutating: false),
            Self.toolIntent("e1/c8", call: "c8", mutating: true),
            Self.toolResult("e1/c8", call: "c8", mutating: true, state: .unknown, outcome: "unknown"),
            Self.toolResult("ghost/g1", call: "gw", mutating: true, state: .done, outcome: "edited"),
            Self.toolResult("ghost/r1", call: "gr", mutating: false, state: .done, outcome: "read it"),
            .queueAdmitted(QueueEntry(entryID: "q-1", commandID: CommandID("cmd-1"), kind: .followUp,
                                      state: .queued, revision: 3, text: "fix QUEUED-111",
                                      targetEpochID: EpochID("epoch-1"), orderKey: 42, sealed: false)),
            .queueUpdated(QueueEntry(entryID: "q-1", commandID: CommandID("cmd-1"), kind: .followUp,
                                     state: .dispatched, revision: 4, text: "fix QUEUED-111 now",
                                     targetEpochID: EpochID("epoch-1"), orderKey: 42, sealed: false)),
            .eventAppended(seq: SequenceNumber(77), kind: "requesting", digest: "d1e2"),
            .artifactPublished(ArtifactRef(
                digest: String(repeating: "a", count: 64), size: 4, kind: "exec-output",
                operationID: OperationID("e1/c1"))),
            .writerRecovered(WriterRecovery(
                previousWriter: "w-old", newWriter: "w-seed",
                operatorID: "op-9", reference: "ticket-REF-77", reason: "rotation because REASON-888",
                atMillis: 9000,
                unresolvedOperations: [OperationRef(
                    operationID: OperationID("e1/c9"), callID: "c9",
                    state: .unknown, mutating: true)])),
        ], as: idA)
        let idB = WriterIdentity(session: sessionB, writer: "w-seed-b")
        try store.appendBatch([
            .sessionOpened(session: sessionB, atMillis: 2000),
            .transcriptAppended(.user("s-b only CONTENT-000")),
            Self.toolIntent("e9/c1", call: "c1", mutating: true),
            Self.toolResult("e9/c1", call: "c1", mutating: true, state: .done, outcome: "b-ok"),
        ], as: idB)
        return (sessionA, sessionB)
    }

    private static func decodeLines(_ lines: [String]) throws -> [[String: Any]] {
        try lines.map { line in
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                Issue.record("export line is not a JSON object: \(line.prefix(120))")
                throw ExportProbeError.unparseable
            }
            return object
        }
    }

    private static func allKeys(_ value: Any, into set: inout Set<String>) {
        if let dict = value as? [String: Any] {
            for (key, nested) in dict {
                set.insert(key)
                allKeys(nested, into: &set)
            }
        } else if let array = value as? [Any] {
            for nested in array { allKeys(nested, into: &set) }
        }
    }

    // MARK: - Allowlist schema (the confidentiality contract, executable)

    @Test("A5-2 export schema contains only allowlisted keys")
    func exportSchemaIsAllowlisted() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBSessionStore(path: directory.appendingPathComponent("store.sqlite").path)
        defer { try? store.close() }
        let (sessionA, _) = try Self.seedRichLedger(store)
        var seen: Set<String> = []
        for includeContent in [false, true] {
            let lines = try SessionExport.lines(
                dbPath: store.path, session: sessionA, includeContent: includeContent,
                exportedAt: 1_000_000, limits: .default)
            for object in try Self.decodeLines(lines) {
                Self.allKeys(object, into: &seen)
            }
        }
        // Every key the exporter can EVER emit, in one place. Adding a
        // field without updating this set fails the test by design.
        let allowed: Set<String> = [
            "format", "version", "kind", "session", "exportedAt", "content",
            "sensitive", "seq", "atMillis", "epochID", "parentEpochID", "profile",
            "eventSeq", "eventKind", "digest",
            "operationID", "callID", "state", "mutating", "outcome",
            "action", "entryID", "commandID", "queueKind", "revision",
            "targetEpochID", "orderKey", "sealed", "redacted", "text",
            "role", "tool", "arguments",
            "previousWriter", "newWriter", "atMillis", "reason", "operatorID",
            "reference", "unresolved",
            "artifactKind", "size", "relativePath",
            "complete", "recordCount",
            "operations", "completed", "held", "unstarted", "orphaned",
        ]
        #expect(seen.isSubset(of: allowed), "non-allowlisted keys would leak: \(seen.subtracting(allowed).sorted())")
        // Negative control: the dangerous vocabulary never appears, even
        // as a key — credentials, raw payloads, snapshots, routes.
        let forbidden = ["credential", "credentials", "secret", "token", "password",
                         "rawBody", "rawPayload", "raw", "configSnapshot", "snapshot",
                         "route", "endpoint", "baseURL", "base_url", "model",
                         "capabilities", "caps", "effectiveCaps"]
        #expect(seen.isDisjoint(with: Set(forbidden)), "forbidden keys present: \(seen.intersection(forbidden))")
    }

    // MARK: - Redacted default export

    @Test("A5-2 default export omits every confidential sentinel")
    func defaultExportOmitsConfidentialContent() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbPath = directory.appendingPathComponent("store.sqlite").path
        let store = try GRDBSessionStore(path: dbPath)
        defer { try? store.close() }
        let (sessionA, sessionB) = try Self.seedRichLedger(store)
        let lines = try SessionExport.lines(
            dbPath: dbPath, session: sessionA, includeContent: false,
            exportedAt: 1_000_000, limits: .default)
        let blob = lines.joined()
        for sentinel in ["ALPHA-111", "BETA-222", "hunter2-CRED-999", "GAMMA-333",
                         "DELTA-444", "EPSILON-555", "QUEUED-111", "REF-77", "REASON-888",
                         "op-9", "SECRET-BASE-88", "s-b only", "CONTENT-000", "b-ok"] {
            #expect(!blob.contains(sentinel), "default export leaks \(sentinel)")
        }
        // Structure survives redaction: kinds, IDs, states, digests.
        let objects = try Self.decodeLines(lines)
        #expect(objects.first?["format"] as? String == "needletail-session-export")
        #expect(objects.first?["version"] as? Int == 1)
        #expect(objects.first?["content"] as? Bool == false)
        #expect(objects.first?["sensitive"] as? Bool == true)
        let kinds = Set(objects.compactMap { $0["kind"] as? String })
        for expected in ["header", "session", "epoch", "transcript", "tool-call", "tool-response",
                         "intent", "result", "queue", "event", "artifact", "recovery", "trailer"] {
            #expect(kinds.contains(expected), "redacted export keeps the \(expected) shape")
        }
        // Unknown outcomes stay unknown AND held.
        let trailer = try #require(objects.last)
        #expect(trailer["complete"] as? Bool == true, "trailer certifies completeness")
        #expect((trailer["recordCount"] as? Int) == lines.count - 2)
        let operations = try #require(trailer["operations"] as? [String: Any])
        #expect((operations["completed"] as? [String]) == ["e1/c1"])
        let held = Set((operations["held"] as? [String]) ?? [])
        #expect(held == Set(["e1/c2", "e1/c8", "ghost/g1"]),
                "held = intent-only crash + explicit unknown + mutating orphan, got \(held)")
        #expect((operations["unstarted"] as? [String]) == ["e1/c7"],
                "side-effect-free intent reported re-runnable, not held")
        #expect((operations["orphaned"] as? [String])?.sorted() == ["ghost/g1", "ghost/r1"],
                "orphans disclosed without completing anything, got \(String(describing: operations["orphaned"]))")
        // The recovery-audit row preserves its unresolved-operation
        // evidence verbatim (e1/c9) WITHOUT making it a live hold: audit
        // memory is not a new unknown.
        let recoveryRows = objects.filter { ($0["kind"] as? String) == "recovery" }
        #expect(recoveryRows.count == 1, "exactly the recovery audit row")
        let unresolved = (recoveryRows.first?["unresolved"] as? [[String: Any]]) ?? []
        #expect(unresolved.compactMap { $0["operationID"] as? String } == ["e1/c9"],
                "recovery evidence travels intact in both modes")
        // Cross-session isolation: nothing from session B.
        let (pageB, _) = try store.records(session: sessionB, since: 0, limit: 10)
        #expect(!pageB.isEmpty, "session B exists as the isolation probe")
        // Reconcile parity: the trailer mirrors the real contract.
        let report = try store.reconcile(session: sessionA)
        #expect(Set(report.heldOperations.map { $0.operationID.raw }) == held)
        _ = sessionB
    }

    // MARK: - Content-bearing export

    @Test("A5-2 content export permits only documented content")
    func contentExportPermitsOnlyDocumentedContent() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbPath = directory.appendingPathComponent("store.sqlite").path
        let store = try GRDBSessionStore(path: dbPath)
        defer { try? store.close() }
        let (sessionA, _) = try Self.seedRichLedger(store)
        let lines = try SessionExport.lines(
            dbPath: dbPath, session: sessionA, includeContent: true,
            exportedAt: 1_000_000, limits: .default)
        let blob = lines.joined()
        // Permitted content travels verbatim.
        for permitted in ["ALPHA-111", "BETA-222", "GAMMA-333", "DELTA-444",
                          "EPSILON-555", "QUEUED-111", "op-9", "ticket-REF-77"] {
            #expect(blob.contains(permitted), "documented content must travel: \(permitted)")
        }
        // Still excluded even in content mode: epoch/config snapshots and
        // recovery free text never travel, whatever the flag says.
        for excluded in ["SECRET-BASE-88", "REASON-888"] {
            #expect(!blob.contains(excluded), "content mode must still exclude \(excluded)")
        }
        // hunter2-CRED-999 IS user text, so it travels verbatim — but the
        // export makes no claim it is secret-free, and no credential FIELD
        // exists to harvest it into.
        #expect(blob.contains("hunter2-CRED-999"),
                "user text travels verbatim in content mode (no secret-free claim)")
        let objects = try Self.decodeLines(lines)
        #expect(objects.first?["content"] as? Bool == true)
        #expect(objects.first?["sensitive"] as? Bool == true)
        func hasKey(_ key: String) -> Bool {
            var found = false
            func walk(_ value: Any) {
                if let dict = value as? [String: Any] {
                    if dict[key] != nil { found = true }
                    dict.values.forEach(walk)
                } else if let array = value as? [Any] {
                    array.forEach(walk)
                }
            }
            objects.forEach(walk)
            return found
        }
        #expect(!hasKey("credential") && !hasKey("credentials"), "no credential fields")
        #expect(!hasKey("rawBody") && !hasKey("rawPayload"), "no raw provider payload fields")
        #expect(!hasKey("text") == false, "content mode carries text fields")
    }

    // MARK: - Bounds, atomicity, read-only

    @Test("A5-2 export bounds fail closed without partial output")
    func exportBoundsFailClosed() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbPath = directory.appendingPathComponent("store.sqlite").path
        let store = try GRDBSessionStore(path: dbPath)
        defer { try? store.close() }
        let (sessionA, _) = try Self.seedRichLedger(store)
        let target = directory.appendingPathComponent("out.jsonl").path
        // Record bound: fewer than the ledger holds.
        #expect(throws: SessionExport.ExportError.self) {
            let lines = try SessionExport.lines(
                dbPath: dbPath, session: sessionA, includeContent: false,
                exportedAt: 1, limits: SessionExport.Limits(maxRecords: 3, maxBytes: 1 << 30))
            try SessionExport.writeLines(lines, toFileAtPath: target)
        }
        #expect(!FileManager.default.fileExists(atPath: target), "failed export leaves no target file")
        // Byte bound: absurdly small.
        #expect(throws: SessionExport.ExportError.self) {
            let lines = try SessionExport.lines(
                dbPath: dbPath, session: sessionA, includeContent: false,
                exportedAt: 1, limits: SessionExport.Limits(maxRecords: 1_000_000, maxBytes: 10))
            try SessionExport.writeLines(lines, toFileAtPath: target)
        }
        #expect(!FileManager.default.fileExists(atPath: target), "failed export leaves no target file")
        // Tmp debris is cleaned up, not left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".export-") }
        #expect(leftovers.isEmpty, "no tmp debris after failed writes, got \(leftovers)")
    }

    @Test("A5-2 export writes private complete files and refuses overwrite")
    func exportWritesPrivateCompleteFiles() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbPath = directory.appendingPathComponent("store.sqlite").path
        let store = try GRDBSessionStore(path: dbPath)
        defer { try? store.close() }
        let (sessionA, _) = try Self.seedRichLedger(store)
        let target = directory.appendingPathComponent("export.jsonl").path
        let lines = try SessionExport.lines(
            dbPath: dbPath, session: sessionA, includeContent: false,
            exportedAt: 1_000_000, limits: .default)
        try SessionExport.writeLines(lines, toFileAtPath: target)
        #expect(try Self.posixMode(target) == 0o600, "export file is private")
        // The written file self-certifies: trailer present, count matches,
        // every line parses (trailing newline yields no phantom row).
        let text = try String(contentsOfFile: target, encoding: .utf8)
        let fileLines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(fileLines.count == lines.count, "no torn tail rows")
        let objects = try Self.decodeLines(fileLines)
        let trailer = try #require(objects.last)
        #expect(trailer["complete"] as? Bool == true)
        #expect((trailer["recordCount"] as? Int) == lines.count - 2)
        // Refuse to overwrite, including through symlinks.
        try "marker".write(toFile: target, atomically: true, encoding: .utf8)
        #expect(throws: SessionExport.ExportError.self) {
            try SessionExport.writeLines(lines, toFileAtPath: target)
        }
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "marker",
                "refused overwrite leaves the target byte-identical")
        let link = directory.appendingPathComponent("link.jsonl").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        #expect(throws: SessionExport.ExportError.self) {
            try SessionExport.writeLines(lines, toFileAtPath: link)
        }
    }

    @Test("A5-2 export is read-only and preserves holds and claims")
    func exportIsReadOnlyAndPreservesHolds() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbPath = directory.appendingPathComponent("store.sqlite").path
        let sessionA: SessionID
        do {
            let seed = try GRDBSessionStore(path: dbPath)
            defer { try? seed.close() }
            (sessionA, _) = try Self.seedRichLedger(seed)
        }
        // Scrub WAL sidecars left by the (read-write) seeding store, so
        // any sidecar afterwards is provably the export's doing.
        for suffix in ["-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        let beforeHolders = try Self.writerHolders(dbPath: dbPath)
        let beforeCount = try Self.recordCount(dbPath: dbPath)
        let beforeReport: OperationReconciliation = try {
            let probe = try GRDBSessionStore(path: dbPath)
            defer { try? probe.close() }
            return try probe.reconcile(session: sessionA)
        }()
        // Snapshot durable journal state AFTER all read-only
        // pre-measurement. A readonly handle cannot write content, but
        // SQLite may materialize an EMPTY -wal handshake file on open;
        // what matters is that no journal content appears or grows.
        // (-shm is ephemeral wal-index shared memory, never durable, and
        // is not tracked here.)
        func journals() throws -> [String: UInt64] {
            var out: [String: UInt64] = [:]
            for entry in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
                guard entry.hasSuffix("-wal") || entry.hasSuffix("-journal") else { continue }
                let url = directory.appendingPathComponent(entry)
                out[entry] = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? .max
            }
            return out
        }
        let journalsBefore = try journals()
        _ = try SessionExport.lines(
            dbPath: dbPath, session: sessionA, includeContent: true,
            exportedAt: 1, limits: .default)
        // Read-only proof: no rollback journal ever appears, and no WAL
        // file gains frames as a side effect of reading.
        let journalsAfter = try journals()
        for name in journalsAfter.keys where name.hasSuffix("-journal") {
            Issue.record("read-only export created rollback journal \(name)")
        }
        #expect(!journalsAfter.keys.contains { $0.hasSuffix("-journal") }, "no rollback journals from reading")
        for (name, size) in journalsAfter where name.hasSuffix("-wal") {
            #expect(size == (journalsBefore[name] ?? 0),
                    "WAL file \(name) gained content during a read-only export")
        }
        #expect(try Self.recordCount(dbPath: dbPath) == beforeCount, "no rows added, removed, or rewritten")
        let afterReport: OperationReconciliation = try {
            let probe = try GRDBSessionStore(path: dbPath)
            defer { try? probe.close() }
            return try probe.reconcile(session: sessionA)
        }()
        #expect(afterReport.heldOperations == beforeReport.heldOperations, "holds preserved, never cleared")
        #expect(try Self.writerHolders(dbPath: dbPath) == beforeHolders, "no claim or release performed")
    }

    // MARK: - Failure modes

    private static func expectExportError(
        _ expression: @autoclosure () throws -> [String],
        _ expected: SessionExport.ExportError,
        fileID: String = #fileID, filePath: String = #filePath, line: Int = #line, column: Int = #column
    ) {
        do {
            _ = try expression()
            Issue.record("expected \(expected), but no error was thrown",
                         sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column))
        } catch let actual as SessionExport.ExportError {
            if actual != expected {
                Issue.record("expected \(expected), got \(actual)",
                             sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column))
            }
        } catch {
            Issue.record("wrong error type: \(error)",
                         sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column))
        }
    }

    @Test("A5-2 missing future and corrupt stores fail explicitly")
    func missingFutureAndCorruptStoresFailExplicitly() throws {
        let directory = try Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Missing: nothing is created, nothing is read.
        let missing = directory.appendingPathComponent("absent.sqlite").path
        Self.expectExportError(
            try SessionExport.lines(
                dbPath: missing, session: SessionID("s-x"), includeContent: false,
                exportedAt: 1, limits: .default),
            .missingStore(missing))
        #expect(!FileManager.default.fileExists(atPath: missing), "missing store is not created")
        // Unknown session in a valid store.
        let dbPath = directory.appendingPathComponent("store.sqlite").path
        let store = try GRDBSessionStore(path: dbPath)
        try store.close()
        Self.expectExportError(
            try SessionExport.lines(
                dbPath: dbPath, session: SessionID("s-ghost"), includeContent: false,
                exportedAt: 1, limits: .default),
            .unknownSession("s-ghost"))
        // Corrupt bytes: never migrated, never repaired.
        let corrupt = directory.appendingPathComponent("corrupt.sqlite").path
        let garbage = Data("not a database".utf8)
        try garbage.write(to: URL(fileURLWithPath: corrupt))
        do {
            _ = try SessionExport.lines(
                dbPath: corrupt, session: SessionID("s-x"), includeContent: false,
                exportedAt: 1, limits: .default)
            Issue.record("corrupt store must fail")
        } catch let error as SessionExport.ExportError {
            guard case .unreadableStore = error else {
                Issue.record("corrupt store must fail as unreadable, got \(error)"); return
            }
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: corrupt)) == garbage,
                "corrupt source is byte-identical afterwards (no repair attempt)")
        // Future schema: refused without downgrading or migrating. Seeded
        // with a real v2 table set so the ONLY reason to refuse is the
        // version gate itself.
        let future = directory.appendingPathComponent("future.sqlite").path
        do {
            let seed = try GRDBSessionStore(path: future)
            try seed.close()
        }
        let raw = try DatabaseQueue(path: future)
        try raw.write { db in try db.execute(sql: "PRAGMA user_version = 99") }
        try raw.close()
        do {
            _ = try SessionExport.lines(
                dbPath: future, session: SessionID("s-x"), includeContent: false,
                exportedAt: 1, limits: .default)
            Issue.record("future store must fail")
        } catch let error as SessionExport.ExportError {
            guard case .unreadableStore = error else {
                Issue.record("future store must fail as unreadable, got \(error)"); return
            }
        }
        let probe = try DatabaseQueue(path: future)
        let version = try probe.read { db in try Int32.fetchOne(db, sql: "PRAGMA user_version") }
        try probe.close()
        #expect(version == 99, "future store untouched (still version 99)")
        // Legacy schema: refused without migrating.
        let legacy = directory.appendingPathComponent("legacy.sqlite").path
        let rawLegacy = try DatabaseQueue(path: legacy)
        try rawLegacy.write { db in try db.execute(sql: "PRAGMA user_version = 1") }
        try rawLegacy.close()
        do {
            _ = try SessionExport.lines(
                dbPath: legacy, session: SessionID("s-x"), includeContent: false,
                exportedAt: 1, limits: .default)
            Issue.record("legacy store must fail")
        } catch let error as SessionExport.ExportError {
            guard case .unreadableStore = error else {
                Issue.record("legacy store must fail as unreadable, got \(error)"); return
            }
        }
    }

    private static func posixMode(_ path: String) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? -1
    }

    private static func writerHolders(dbPath: String) throws -> [String] {
        let db = try DatabaseQueue(path: dbPath)
        defer { try? db.close() }
        return try db.read { db in
            try String.fetchAll(db, sql: "SELECT writer FROM writer")
        }
    }

    private static func recordCount(dbPath: String) throws -> Int {
        let db = try DatabaseQueue(path: dbPath)
        defer { try? db.close() }
        return try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM records") ?? -1
        }
    }
}

private enum ExportProbeError: Error {
    case unparseable
}
