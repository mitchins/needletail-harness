import Testing
import GRDB
import Foundation
import NeedletailCore
@testable import NeedletailRuntime
import NeedletailTestSupport
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A4-2 production SIGKILL matrix (SPEC §9.1) + PORT-04 native leg.
///
/// Every test spawns a REAL separate process (this same test binary,
/// filtered to `crashStagingChild`), which performs staged operations
/// against the REAL `GRDBSessionStore` using ONLY production APIs (plus
/// raw GRDB in the child for the one held-transaction stage — test code,
/// never a shipping fault switch). The child acknowledges each staged
/// point by writing a readiness file, then parks; the parent verifies it
/// is still parked, delivers a real SIGKILL, verifies signal termination
/// via waitpid, and reopens through a FRESH handle. No guessed sleeps
/// position any crash: the kill always lands on an explicitly
/// acknowledged barrier, and every wait is deadline-bounded.
///
/// The external side effect is a file sentinel (`sentinel`, exactly one
/// `effect-1` line, fsynced): its absence/presence/count proves whether
/// execution happened and whether any replay duplicated it. Real native
/// edit/exec tools belong to M2-B/C; the sentinel is the owned,
/// deterministic stand-in the contract calls for.
///
/// Durability scope: process-kill (application-crash) consistency, which
/// is SQLite's own WAL guarantee. Nothing here claims disk-controller
/// or power-failure resilience.
struct CrashMatrixTests {

    // MARK: - Child staging (runs ONLY when spawned with crash env)

    @Test("crash staging child (spawned by matrix tests; inert without env)")
    func crashStagingChild() throws {
        guard let directory = ProcessInfo.processInfo.environment["NT_CRASH_DIR"],
              let stage = ProcessInfo.processInfo.environment["NT_CRASH_STAGE"]
        else {
            // Normal suite run: inert, unlabeled support (no case prefix).
            return
        }
        let dirURL = URL(fileURLWithPath: directory, isDirectory: true)
        let dbPath = dirURL.appendingPathComponent("store.sqlite").path
        let session = SessionID("s-crash")
        let identity = WriterIdentity(session: Self.session, writer: "crash-writer")
        let readyURL = dirURL.appendingPathComponent("ready")
        let sentinelURL = dirURL.appendingPathComponent("sentinel")

        func writeReady(_ marker: String) throws {
            try Data(marker.utf8).write(to: readyURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: readyURL.path)
        }
        func appendSentinel() throws {
            let sentinelPath = sentinelURL.path
            let handle: FileHandle
            if FileManager.default.fileExists(atPath: sentinelPath) {
                guard let open = FileHandle(forWritingAtPath: sentinelPath) else {
                    throw CrashSetupError.sentinelUnwritable
                }
                handle = open
                try handle.seekToEnd()
            } else {
                guard FileManager.default.createFile(atPath: sentinelPath, contents: nil,
                                                     attributes: [.posixPermissions: 0o600]) else {
                    throw CrashSetupError.sentinelUnwritable
                }
                guard let open = FileHandle(forWritingAtPath: sentinelPath) else {
                    throw CrashSetupError.sentinelUnwritable
                }
                handle = open
            }
            defer { try? handle.close() }
            try handle.write(contentsOf: Data("effect-1\n".utf8))
            try handle.synchronize()
        }
        func intent() -> DurableRecord {
            .operationIntent(OperationRef(
                operationID: OperationID("e1/c1"), callID: "c1", state: .intent, mutating: true))
        }
        func parkForever() -> Never {
            while true { Thread.sleep(forTimeInterval: 60) }
        }

        switch stage {
        case "s1":
            // Before intent commit: a live claim + one conversation row,
            // no operation records at all.
            let store = try GRDBSessionStore(path: dbPath)
            try store.claimWriterOwnership(session: Self.session, writer: "crash-writer")
            try store.append(.transcriptAppended(.user("s1 alive")), as: identity)
            try writeReady("s1")
            parkForever()
        case "s2":
            // After intent commit, before effect: intent durable, sentinel
            // NEVER written.
            let store = try GRDBSessionStore(path: dbPath)
            try store.claimWriterOwnership(session: Self.session, writer: "crash-writer")
            try store.append(intent(), as: identity)
            try writeReady("s2")
            parkForever()
        case "s3", "s5", "port04":
            // Intent, then the external side effect, then (s5/port04) the
            // committed result. s3 parks before ANY result commit.
            let store = try GRDBSessionStore(path: dbPath)
            try store.claimWriterOwnership(session: Self.session, writer: "crash-writer")
            try store.append(intent(), as: identity)
            try appendSentinel()
            if stage != "s3" {
                try store.append(.operationResult(OperationRef(
                    operationID: OperationID("e1/c1"), callID: "c1",
                    state: .done, mutating: true), outcome: "ok"), as: identity)
            }
            try writeReady(stage)
            parkForever()
        case "s4":
            // Result transaction initiated but uncommitted: the intent and
            // sentinel go through production APIs; the result row is
            // staged in a HELD raw transaction (test code, production row
            // shape via the production codec) that never commits — the
            // kill lands with the WAL frames uncommitted.
            let store = try GRDBSessionStore(path: dbPath)
            try store.claimWriterOwnership(session: Self.session, writer: "crash-writer")
            try store.append(intent(), as: identity)
            try appendSentinel()
            let result = DurableRecord.operationResult(OperationRef(
                operationID: OperationID("e1/c1"), callID: "c1",
                state: .done, mutating: true), outcome: "ok")
            let payload = try RecordCodec.encode(result)
            let raw = try DatabaseQueue(path: dbPath)
            try raw.write { db in
                let last = try Int64.fetchOne(
                    db, sql: "SELECT MAX(seq) FROM records") ?? 0
                try db.execute(
                    sql: "INSERT INTO records (seq, session, payload) VALUES (?, ?, ?)",
                    arguments: [last + 1, session.raw,
                                String(decoding: payload, as: UTF8.self)])
                try writeReady("s4")
                parkForever()
            }
        case "s6":
            // Artifact tmp stage: a private tmp file is written and synced
            // in the managed root, but never renamed and never referenced.
            let store = try GRDBSessionStore(path: dbPath)
            try store.claimWriterOwnership(session: Self.session, writer: "crash-writer")
            let root = GRDBSessionStore.artifactsRoot(for: dbPath)
            try FileManager.default.createDirectory(
                atPath: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let tmp = root + "/" + artifactTmpPrefix + UUID().uuidString
            guard FileManager.default.createFile(
                atPath: tmp, contents: Data("partial-bytes".utf8),
                attributes: [.posixPermissions: 0o600]) else {
                throw CrashSetupError.sentinelUnwritable
            }
            if let handle = FileHandle(forWritingAtPath: tmp) {
                try handle.synchronize()
                try handle.close()
            }
            try writeReady("s6")
            parkForever()
        case "s7":
            // Artifact renamed but unreferenced: intent committed, bytes
            // durable at the final content-addressed name, NO reference
            // row (simulating a crash between rename and the txn commit).
            let store = try GRDBSessionStore(path: dbPath)
            try store.claimWriterOwnership(session: Self.session, writer: "crash-writer")
            try store.append(intent(), as: identity)
            let bytes = Data("orphaned-artifact-bytes".utf8)
            let digest = artifactSHA256Hex(bytes)
            let root = GRDBSessionStore.artifactsRoot(for: dbPath)
            try FileManager.default.createDirectory(
                atPath: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let tmp = root + "/" + artifactTmpPrefix + UUID().uuidString
            guard FileManager.default.createFile(
                atPath: tmp, contents: bytes,
                attributes: [.posixPermissions: 0o600]) else {
                throw CrashSetupError.sentinelUnwritable
            }
            if let handle = FileHandle(forWritingAtPath: tmp) {
                try handle.synchronize()
                try handle.close()
            }
            try FileManager.default.moveItem(
                atPath: tmp, toPath: root + "/" + digest)
            try syncArtifactDirectory(atPath: root)
            try writeReady("s7")
            parkForever()
        case "s8":
            // Fully committed artifact publication via the production API.
            let store = try GRDBSessionStore(path: dbPath)
            try store.claimWriterOwnership(session: Self.session, writer: "crash-writer")
            _ = try store.publishArtifact(
                session: Self.session, as: identity, kind: "exec-output",
                operationID: OperationID("e1/c1"), bytes: Data("committed-bytes".utf8))
            try writeReady("s8")
            parkForever()
        default:
            throw CrashSetupError.unknownStage(stage)
        }
    }

    // MARK: - Parent harness

    private enum CrashSetupError: Error {
        case sentinelUnwritable
        case unknownStage(String)
        case binaryUnusable(String)
        case childDied(String)
        case notSignaled(String)
        case readinessTimeout(String)
    }

    /// A live crash child: owns the PID and guarantees bounded teardown —
    /// a still-running child is SIGKILLed and reaped on `ensureReaped`,
    /// so no fixture failure leaves an orphan behind.
    private final class CrashChild {
        let directory: URL
        let process: Process

        init(directory: URL, process: Process) {
            self.directory = directory
            self.process = process
        }

        var dbPath: String {
            directory.appendingPathComponent("store.sqlite").path
        }

        static func spawn(stage: String) throws -> CrashChild {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("needletail-kill-\(UUID().uuidString)", isDirectory: true)
            // Private fixture root (0700): UUIDs prevent accidental
            // collisions; mode bits prevent other local users from
            // reading or tampering with the staged DB/sentinel/markers.
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            var argv0 = CommandLine.arguments[0]
            if !argv0.hasPrefix("/") {
                argv0 = FileManager.default.currentDirectoryPath + "/" + argv0
            }
            guard FileManager.default.isExecutableFile(atPath: argv0) else {
                throw CrashSetupError.binaryUnusable(argv0)
            }
            let child = Process()
            child.executableURL = URL(fileURLWithPath: argv0)
            child.arguments = ["--filter", "StagingChild", "--testing-library", "swift-testing"]
            var env = ProcessInfo.processInfo.environment
            env["NT_CRASH_DIR"] = directory.path
            env["NT_CRASH_STAGE"] = stage
            child.environment = env
            let outURL = directory.appendingPathComponent("child-out.log")
            let errURL = directory.appendingPathComponent("child-err.log")
            guard FileManager.default.createFile(atPath: outURL.path, contents: nil,
                                                     attributes: [.posixPermissions: 0o600]),
                  FileManager.default.createFile(atPath: errURL.path, contents: nil,
                                                     attributes: [.posixPermissions: 0o600]),
                  let outHandle = FileHandle(forWritingAtPath: outURL.path),
                  let errHandle = FileHandle(forWritingAtPath: errURL.path) else {
                throw CrashSetupError.binaryUnusable("cannot create child logs")
            }
            child.standardOutput = outHandle
            child.standardError = errHandle
            try child.run()
            return CrashChild(directory: directory, process: child)
        }

        /// Bounded readiness poll (explicit acknowledgement, never a
        /// guessed sleep): the child writes `<dir>/ready` AFTER the staged
        /// work is complete and BEFORE parking.
        func awaitReady(marker: String, deadline: TimeInterval = 30) throws {
            let readyURL = directory.appendingPathComponent("ready")
            let stop = Date().addingTimeInterval(deadline)
            while Date() < stop {
                if let data = try? Data(contentsOf: readyURL),
                   String(data: data, encoding: .utf8) == marker {
                    return
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            throw CrashSetupError.readinessTimeout(
                "child never acknowledged stage \(marker); running=\(process.isRunning)")
        }

        /// Bounded raw reap: WNOHANG poll loop with a deadline. Returns the
        /// raw wait status if this call reaped the child; nil on timeout
        /// or when someone else already reaped (ECHILD). NEVER blocks:
        /// callers fail loudly on timeout instead of hanging, and never
        /// signal a possibly-recycled PID afterwards.
        func reapBounded(pid: Int32, deadline: TimeInterval) -> Int32? {
            let stop = Date().addingTimeInterval(deadline)
            var status: Int32 = 0
            while Date() < stop {
                let waited = waitpid(pid, &status, WNOHANG)
                if waited == pid { return status }
                if waited < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    return nil
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return nil
        }

        /// Deliver SIGKILL and verify signal termination. Bounded
        /// throughout: the kill return is checked, the reap has a
        /// deadline, and `waitUntilExit` is only ever reached when the
        /// child is certainly dead (reaped by us, or reaped elsewhere and
        /// therefore gone). A live child past the deadline fails loudly —
        /// never hangs the run.
        func killAndVerifySIGKILL(deadline: TimeInterval = 10) throws -> Int32 {
            let pid = process.processIdentifier
            guard process.isRunning else {
                throw CrashSetupError.childDied("child exited before the kill landed")
            }
            guard kill(pid, SIGKILL) == 0 else {
                throw CrashSetupError.childDied(
                    "SIGKILL delivery failed (errno \(errno)); cannot verify the crash point")
            }
            if let status = reapBounded(pid: pid, deadline: deadline) {
                // Manual POSIX decode (no macro imports): low 7 bits hold
                // the outcome — 0 means clean exit, 0x7f means stopped,
                // anything else is the terminating signal (bit 0x80 is the
                // core-dump flag, excluded by the mask).
                let low = status & 0x7f
                guard low != 0, low != 0x7f else {
                    throw CrashSetupError.notSignaled(
                        "child was not signal-terminated (status \(status))")
                }
                guard low == SIGKILL else {
                    throw CrashSetupError.notSignaled(
                        "child died from signal \(low), not SIGKILL")
                }
                process.waitUntilExit()
                return low
            }
            // Not reaped by us: either reaped elsewhere (ECHILD — the
            // child is dead by definition) or still alive past the
            // deadline. A live child here is a hard failure, not a longer
            // wait; `waitUntilExit` below is only safe because the ECHILD
            // branch guarantees death, and the live branch throws first.
            if process.isRunning {
                throw CrashSetupError.childDied(
                    "child survived SIGKILL past the deadline; refusing to hang or signal further")
            }
            process.waitUntilExit()
            guard process.terminationReason == .uncaughtSignal else {
                throw CrashSetupError.notSignaled(
                    "child was not signal-terminated (reason \(process.terminationReason), status \(process.terminationStatus))")
            }
            // Framework-reaped path: the only signal a parked child with
            // no handlers can have died from is the SIGKILL delivered
            // after verifying it parked — recorded as observed.
            return process.terminationStatus
        }

        /// Bounded teardown: a still-running child is SIGKILLed and
        /// reaped with a deadline. Never hangs: if the child somehow
        /// survives, the failure is recorded loudly and the run moves on
        /// (the zombie, if any, dies with the test process).
        func ensureReaped() {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            if reapBounded(pid: process.processIdentifier, deadline: 10) == nil,
               process.isRunning {
                Issue.record("crash child survived SIGKILL past the teardown deadline")
            }
        }
    }

    // MARK: - Matrix (each: spawn → acknowledged barrier → SIGKILL → fresh reopen)

    private static let session = SessionID("s-crash")
    private static let writer = "crash-writer"

    private static func withKilledChild(
        stage: String, _ body: (URL, String) throws -> Void
    ) throws {
        let run = try CrashChild.spawn(stage: stage)
        defer { try? FileManager.default.removeItem(at: run.directory) }
        defer { run.ensureReaped() }
        try run.awaitReady(marker: stage)
        #expect(run.process.isRunning, "child must still hold its staged point when killed")
        let termsig = try run.killAndVerifySIGKILL()
        #expect(termsig == SIGKILL, "termination must be the delivered SIGKILL")
        try body(run.directory, run.dbPath)
    }

    private static func sentinelText(in directory: URL) -> String? {
        let url = directory.appendingPathComponent("sentinel")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Fresh-handle writability via the SAME writer identity (the
    /// documented crash-recovery re-acquire): proves the ownership row
    /// and the record log survived the kill and accept new work. The
    /// holder is asserted via raw SQL BEFORE re-claiming — a lost
    /// ownership row fails loudly here instead of being silently
    /// recreated by the idempotent claim.
    private static func assertWritableAfterReopen(dbPath: String) throws {
        let probe = try DatabaseQueue(path: dbPath)
        let holder = try probe.read { db in
            try String.fetchOne(
                db, sql: "SELECT writer FROM writer WHERE session = ?",
                arguments: [session.raw])
        }
        try probe.close()
        #expect(holder == writer, "ownership row survived the kill (holder \(holder ?? "none"))")
        let store = try GRDBSessionStore(path: dbPath)
        defer { try? store.close() }
        try store.claimWriterOwnership(session: session, writer: writer)
        try store.append(.transcriptAppended(.user("post-reopen")),
                         as: WriterIdentity(session: session, writer: writer))
        let (page, _) = try store.records(session: session, since: 0, limit: 10_000)
        #expect(page.contains { $0.record == .transcriptAppended(.user("post-reopen")) },
                "fresh handle writes and reads back after the kill")
    }

    /// Minimal epoch builder (mirrors the state-suite fixtures so this
    /// target needs no new dependency edge): only `resumedAfterReopen` +
    /// `transition` admission blocking is under test here.
    private static func testEpoch() throws -> EpochDescriptor {
        let configJSON = """
            {"version":1,"default_model":"local-coder","allow_http_origins":["http://127.0.0.1:11434"],"models":[{"alias":"local-coder","protocol":"openai-chat-completions","base_url":"http://127.0.0.1:11434","model":"qwen","context_window":262144,"max_output":4096,"locality":"local","credential":{"env":"NT_M1B_KEY"},"connect_timeout_s":10,"read_idle_timeout_s":300,"request_timeout_s":1800,"max_in_flight":1}],"tools":{"read":true,"search":true,"edit":true,"write":true,"exec":"ask","consult":false}}
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

    @Test("STORE-02 sqlite kill before intent commit leaves nothing")
    func STORE_02_sqliteKillBeforeIntentCommitLeavesNothing() throws {
        try Self.withKilledChild(stage: "s1") { directory, dbPath in
            // Private fixture root (hermetic even on shared /tmp).
            let dirAttrs = try FileManager.default.attributesOfItem(atPath: directory.path)
            #expect((dirAttrs[.posixPermissions] as? Int) == 0o700,
                    "crash fixture directory is private")
            // The conversation row proves the database itself survived;
            // no operation records of any kind were invented.
            let store = try GRDBSessionStore(path: dbPath)
            defer { try? store.close() }
            let report = try store.reconcile(session: Self.session)
            #expect(report.completed.isEmpty)
            #expect(report.heldOperations.isEmpty, "nothing unstarted is held")
            #expect(report.explicitUnknown.isEmpty && report.orphanResults.isEmpty)
            #expect(report.unmatchedMutating.isEmpty && report.unmatchedNonMutating.isEmpty)
            let (page, _) = try store.records(session: Self.session, since: 0, limit: 100)
            #expect(page.contains { $0.record == .transcriptAppended(.user("s1 alive")) },
                    "pre-intent rows survive the kill")
            #expect(!page.contains {
                if case .operationIntent = $0.record { return true }
                if case .operationResult = $0.record { return true }
                return false
            }, "no intent, no result, no invented outcome")
            try Self.assertWritableAfterReopen(dbPath: dbPath)
        }
    }

    @Test("STORE-02 sqlite kill after intent commit holds unknown")
    func STORE_02_sqliteKillAfterIntentCommitHoldsUnknown() throws {
        try Self.withKilledChild(stage: "s2") { directory, dbPath in
            // The fixture KNOWS the effect never ran (no sentinel), but
            // the ledger cannot know that: conservative unknown + hold.
            #expect(Self.sentinelText(in: directory) == nil, "effect demonstrably never ran")
            let store = try GRDBSessionStore(path: dbPath)
            defer { try? store.close() }
            let report = try store.reconcile(session: Self.session)
            #expect(report.completed.isEmpty, "no result, no completion")
            #expect(report.unmatchedMutating.map(\.operationID) == [OperationID("e1/c1")])
            #expect(report.heldOperations.map(\.operationID) == [OperationID("e1/c1")],
                    "unmatched mutating intent holds")
            try Self.assertWritableAfterReopen(dbPath: dbPath)
        }
    }

    @Test("STORE-02 sqlite kill after side effect holds without redispatch")
    func STORE_02_sqliteKillAfterSideEffectHoldsWithoutRedispatch() throws {
        try Self.withKilledChild(stage: "s3") { directory, dbPath in
            // The side effect demonstrably happened EXACTLY once...
            #expect(Self.sentinelText(in: directory) == "effect-1\n",
                    "side effect provably occurred once")
            let store = try GRDBSessionStore(path: dbPath)
            defer { try? store.close() }
            let report = try store.reconcile(session: Self.session)
            #expect(report.completed.isEmpty, "result absent: not completed")
            #expect(report.heldOperations.map(\.operationID) == [OperationID("e1/c1")],
                    "uncertain outcome holds")
            // ...and resuming with those holds refuses new work: no new
            // run starts, so the operation can never auto-dispatch again
            // under a fresh call ID.
            var ids = DeterministicIDSource(prefix: "k")
            let resumed = SessionState.resumedAfterReopen(
                sessionID: Self.session, epoch: try Self.testEpoch(), trustMode: .workspace,
                heldOperations: report.heldOperations)
            let blocked = transition(resumed, .operatorInput(
                commandID: CommandID("new-1"), text: "new work", kind: .followUp,
                revision: 1, sealed: false, atMillis: 1_000_000), &ids)
            #expect(blocked.state.activeRun == nil, "no new run while the kill's outcome is unknown")
            #expect(blocked.state.liveReservations.isEmpty, "nothing dispatched")
            // Sentinel stability (occurrence/once-ness only): it still
            // reads exactly once, as before. Non-replay is proven by the
            // state check above — the refused transition is pure and
            // could never write the sentinel, so this re-read is a
            // stability check, not replay evidence.
            #expect(Self.sentinelText(in: directory) == "effect-1\n",
                    "sentinel unchanged after the refused submission")
            try Self.assertWritableAfterReopen(dbPath: dbPath)
        }
    }

    @Test("STORE-02 sqlite kill before result commit derives uncertainty")
    func STORE_02_sqliteKillBeforeResultCommitDerivesUncertainty() throws {
        try Self.withKilledChild(stage: "s4") { directory, dbPath in
            // The result transaction was initiated but never committed:
            // the WAL frames rolled back with the dead child.
            #expect(Self.sentinelText(in: directory) == "effect-1\n")
            let store = try GRDBSessionStore(path: dbPath)
            defer { try? store.close() }
            let (page, _) = try store.records(session: Self.session, since: 0, limit: 100)
            let results = page.compactMap { sequenced -> OperationRef? in
                if case .operationResult(let ref, _) = sequenced.record { return ref }
                return nil
            }
            #expect(!results.contains {
                $0.operationID == OperationID("e1/c1") && $0.state == .done
            }, "uncommitted result must not survive the kill")
            // No partial success either: no tool response, no consumed
            // effect, no continuation records for the call.
            #expect(!page.contains {
                if case .transcriptAppended(.toolResponse(let callID, _)) = $0.record {
                    return callID == "c1"
                }
                return false
            }, "no partial transcript continuation")
            #expect(!page.contains {
                if case .eventAppended(_, let kind, _) = $0.record {
                    return kind == "effect-consumed"
                }
                return false
            }, "no partial effect-consumed marker")
            // Uncertainty derives SOLELY from the previously committed
            // intent — there is no unknown/orphan record to lean on.
            let report = try store.reconcile(session: Self.session)
            #expect(report.explicitUnknown.isEmpty && report.orphanResults.isEmpty)
            #expect(report.unmatchedMutating.map(\.operationID) == [OperationID("e1/c1")])
            #expect(report.heldOperations.map(\.operationID) == [OperationID("e1/c1")])
            try Self.assertWritableAfterReopen(dbPath: dbPath)
        }
    }

    @Test("STORE-02 sqlite kill after result commit survives complete")
    func STORE_02_sqliteKillAfterResultCommitSurvivesComplete() throws {
        try Self.withKilledChild(stage: "s5") { directory, dbPath in
            #expect(Self.sentinelText(in: directory) == "effect-1\n")
            // Production format check FIRST: a raw handle reads the file
            // header before any production store open could convert it —
            // otherwise the store's own WAL setup would make this probe
            // vacuous.
            let probe = try DatabaseQueue(path: dbPath)
            let mode = try probe.read { db in
                try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "?"
            }
            try probe.close()
            #expect(mode.lowercased() == "wal", "production WAL format, got \(mode)")
            let store = try GRDBSessionStore(path: dbPath)
            defer { try? store.close() }
            let report = try store.reconcile(session: Self.session)
            #expect(report.completed == [OperationID("e1/c1")], "committed result survives")
            #expect(report.heldOperations.isEmpty, "no false unknown classification")
            try Self.assertWritableAfterReopen(dbPath: dbPath)
        }
    }

    @Test("STORE-02 sqlite interrupted artifact tmp reports no reference")
    func STORE_02_sqliteInterruptedArtifactTmpReportsNoReference() throws {
        try Self.withKilledChild(stage: "s6") { directory, dbPath in
            let store = try GRDBSessionStore(path: dbPath)
            defer { try? store.close() }
            let orphans = try store.detectArtifactOrphans()
            #expect(orphans.orphaned.isEmpty, "tmp files are interrupted, not orphaned")
            #expect(orphans.interrupted.count == 1, "exactly the abandoned tmp file")
            #expect(orphans.interrupted.allSatisfy { $0.hasPrefix(".tmp-") })
            let (page, _) = try store.records(session: Self.session, since: 0, limit: 100)
            #expect(!page.contains { if case .artifactPublished = $0.record { return true }; return false },
                    "interrupted publication commits no reference")
            try Self.assertWritableAfterReopen(dbPath: dbPath)
        }
    }

    @Test("STORE-02 sqlite renamed artifact without reference is orphan")
    func STORE_02_sqliteRenamedArtifactWithoutReferenceIsOrphan() throws {
        try Self.withKilledChild(stage: "s7") { _, dbPath in
            let store = try GRDBSessionStore(path: dbPath)
            defer { try? store.close() }
            let expectedDigest = artifactSHA256Hex(Data("orphaned-artifact-bytes".utf8))
            let orphans = try store.detectArtifactOrphans()
            #expect(orphans.interrupted.isEmpty, "rename finished: not interrupted")
            #expect(orphans.orphaned == [expectedDigest],
                    "exactly the renamed-but-unreferenced file, got \(orphans.orphaned)")
            let (page, _) = try store.records(session: Self.session, since: 0, limit: 100)
            #expect(!page.contains { if case .artifactPublished = $0.record { return true }; return false },
                    "no reference row for the orphan")
            // The operation itself stays unknown and held — the orphan is
            // reported, never attached to it as a success.
            let report = try store.reconcile(session: Self.session)
            #expect(report.completed.isEmpty)
            #expect(report.heldOperations.map(\.operationID) == [OperationID("e1/c1")])
            try Self.assertWritableAfterReopen(dbPath: dbPath)
        }
    }

    @Test("STORE-02 sqlite committed artifact reference reads verified")
    func STORE_02_sqliteCommittedArtifactReferenceReadsVerified() throws {
        try Self.withKilledChild(stage: "s8") { _, dbPath in
            let store = try GRDBSessionStore(path: dbPath)
            defer { try? store.close() }
            let orphans = try store.detectArtifactOrphans()
            #expect(orphans.orphaned.isEmpty && orphans.interrupted.isEmpty,
                    "committed artifacts are neither orphaned nor interrupted")
            // Fresh-handle reference AND verified bytes agree.
            let (page, _) = try store.records(session: Self.session, since: 0, limit: 100)
            let refs = page.compactMap { sequenced -> ArtifactRef? in
                if case .artifactPublished(let ref) = sequenced.record { return ref }
                return nil
            }
            #expect(refs.count == 1, "exactly the committed reference")
            #expect(try store.readArtifact(refs[0]) == Data("committed-bytes".utf8),
                    "verified bytes agree with the reference after process death")
            let report = try store.reconcile(session: Self.session)
            #expect(report.heldOperations.isEmpty)
            try Self.assertWritableAfterReopen(dbPath: dbPath)
        }
    }

    @Test("in-memory contrast cannot prove kill survival")
    func inMemoryContrastCannotProveKillSurvival() throws {
        // PORT-04 contrast, deliberately UNLABELED (no case prefix, no
        // sqlite/sigkill token): the in-memory ledger reconciles trivially
        // with no process, no signal and no file — there is NOTHING here
        // that could certify crash durability. This test documents what
        // the native leg below adds; it can never satisfy PORT-04 itself.
        let memory = InMemorySessionStore()
        let memSession = SessionID("s-mem")
        try memory.claimWriterOwnership(session: memSession, writer: "w-1")
        let memIdentity = WriterIdentity(session: memSession, writer: "w-1")
        try memory.append(.operationIntent(OperationRef(
            operationID: OperationID("e1/c1"), callID: "c1",
            state: .intent, mutating: true)), as: memIdentity)
        try memory.append(.operationResult(OperationRef(
            operationID: OperationID("e1/c1"), callID: "c1",
            state: .done, mutating: true), outcome: "ok"), as: memIdentity)
        let (memPage, _) = try memory.records(session: memSession, since: 0, limit: 100)
        #expect(memPage.count == 2, "in-memory ledger completes with no kill involved")
    }

    @Test("PORT-04 sqlite native kill reopen leg must execute")
    func PORT_04_sqliteNativeKillReopenLegMustExecute() throws {
        // PORT-04 native leg, and ONLY the native leg: a REAL child dies
        // from a REAL SIGKILL (verified signal termination) and a FRESH
        // handle recovers. In-memory success cannot mask this leg — the
        // required variant is this native function, and the maps pin plus
        // the ingestion gate fail loudly if it is missing, skipped or
        // broken. (Body removal is covered structurally: the contrast
        // above lives in a separate, unlabeled, non-qualifying test.)
        try Self.withKilledChild(stage: "port04") { directory, dbPath in
            #expect(Self.sentinelText(in: directory) == "effect-1\n")
            let store = try GRDBSessionStore(path: dbPath)
            defer { try? store.close() }
            let report = try store.reconcile(session: Self.session)
            #expect(report.completed == [OperationID("e1/c1")])
            #expect(report.heldOperations.isEmpty)
            try Self.assertWritableAfterReopen(dbPath: dbPath)
        }
    }
}
