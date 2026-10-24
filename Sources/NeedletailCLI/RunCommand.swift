import ArgumentParser
import Foundation
import NeedletailCore
import NeedletailProviders
import NeedletailRuntime
import AsyncHTTPClient
import Dispatch
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import NIOCore

/// `needletail run` (M1-D): headless coding-agent loop via production
/// `SessionActor` + `ChatCompletionsTransport` + `ScriptedToolBackend`.
/// A5-1: ordinary runs persist to the production GRDB store (durable
/// session/epoch/transcript records, fenced writer ownership); sealed
/// runs keep the volatile in-memory exception. No cloud fallback.
struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a headless agent turn against a configured model (M1-D).")

    @Option(name: .long, help: "Explicit configuration file path.")
    var config: String?

    @Option(name: .long, help: "Operator prompt text for this run.")
    var prompt: String

    @Option(name: .long, help: "Trace file path for JSONL output (in addition to stdout when --format jsonl).")
    var trace: String?

    @Option(name: .long, help: "Output format: jsonl writes only versioned JSON events to stdout.")
    var format: String?

    @Option(name: .long, help: "Scripted tool backend JSON file (array of {tool, arguments, result}).")
    var tools: String?

    @Option(name: .long, help: "Model alias to run (defaults to config default_model).")
    var alias: String?

    @Option(name: .long, help: "Maximum turns for this run (default 80).")
    var maxTurns: Int?

    @Flag(name: .long, help: "Sealed mode: request is tool-free, model must not propose tools.")
    var sealed: Bool = false

    @Flag(name: .long, help: "Trusted execution fixture: allow all tools without approval (demo only, not the default).")
    var trusted: Bool = false

    @Option(name: .long, help: "Workspace root (must exist) for mutating file tools.")
    var workspace: String?

    @Option(name: .customLong("acknowledge-unresolved-outcomes"),
            help: "Explicit operator decision for the B5-B cross-run gate: 'operator-accepted-risk' or 'manually-reconciled:<note>'. Records a durable acknowledgment in the new session; required when the store holds unresolved mutating outcomes, never persisted, never exempts future runs.")
    var acknowledgeUnresolvedOutcomes: String?

    @Option(name: .customLong("read-root"), help: "Read-only root for read/search (may be repeated).")
    var readRoot: [String] = []

    mutating func run() throws {
        let isJSONL = format?.lowercased() == "jsonl"
        if let format, !["json", "human", "jsonl"].contains(format.lowercased()) {
            eprint("error $.cli.--format: must be 'jsonl', 'human', or 'json'.")
            throw ExitCode(2)
        }
        // B1 workspace/read-root + sealed/trusted conflict validations (exit 2)
        if workspace != nil && trusted {
            eprint("error: --workspace and --trusted are mutually exclusive")
            throw ExitCode(2)
        }
        if workspace != nil && sealed {
            eprint("error: --workspace and --sealed are mutually exclusive")
            throw ExitCode(2)
        }
        if !readRoot.isEmpty && sealed {
            eprint("error: --read-root and --sealed are mutually exclusive")
            throw ExitCode(2)
        }
        if let ws = workspace {
            if ws.utf8.contains(0) {
                eprint("error: --workspace contains NUL")
                throw ExitCode(2)
            }
            let fd = ws.withCString { cstr in open(cstr, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard fd >= 0 else {
                eprint("error: --workspace must exist and be a directory (not symlink): \(terminalSafe(ws)): \(String(cString: strerror(errno)))")
                throw ExitCode(2)
            }
            close(fd)
        }
        for rr in readRoot {
            if rr.utf8.contains(0) {
                eprint("error: --read-root contains NUL")
                throw ExitCode(2)
            }
            let fd = rr.withCString { cstr in open(cstr, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard fd >= 0 else {
                eprint("error: --read-root must exist and be a directory (not symlink): \(terminalSafe(rr)): \(String(cString: strerror(errno)))")
                throw ExitCode(2)
            }
            close(fd)
        }
        if let ack = acknowledgeUnresolvedOutcomes {
            guard ack == "operator-accepted-risk"
                    || (ack.hasPrefix("manually-reconciled:") && ack.dropFirst("manually-reconciled:".count).count > 0),
                  !ack.utf8.contains(0) else {
                eprint("error $.cli.--acknowledge-unresolved-outcomes: must be 'operator-accepted-risk' or 'manually-reconciled:<note>'.")
                throw ExitCode(2)
            }
        }
        // Capture values for Sendable closure (mutating self cannot be captured)
        let promptCopy = prompt
        let configCopy = config
        let traceCopy = trace
        let formatCopy = format
        let toolsCopy = tools
        let aliasCopy = alias
        let maxTurnsCopy = maxTurns
        let workspaceCopy = workspace
        let readRootCopy = readRoot
        let acknowledgedDetermination = acknowledgeUnresolvedOutcomes
        final class Box: @unchecked Sendable {
            var exitCode: Int32 = 0
            var error: Error?
            let lock = NSLock()
        }
        final class SemBox: @unchecked Sendable {
            let value = DispatchSemaphore(value: 0)
            func signal() { value.signal() }
            func wait() { value.wait() }
        }
        let box = Box()
        let semBox = SemBox()
        let sealedCopy = sealed
        let trustedCopy = trusted
        Task { @Sendable in
            do {
                try await RunCommand.executeStatic(
                    prompt: promptCopy, config: configCopy, trace: traceCopy,
                    format: formatCopy, tools: toolsCopy, alias: aliasCopy,
                    maxTurns: maxTurnsCopy, sealed: sealedCopy, trusted: trustedCopy, workspace: workspaceCopy, readRoot: readRootCopy, acknowledgedDetermination: acknowledgedDetermination, isJSONL: isJSONL)
            } catch let error as ExitCode {
                box.lock.withLock { box.exitCode = error.rawValue }
            } catch {
                box.lock.withLock {
                    box.error = error
                    box.exitCode = 4
                }
            }
            semBox.signal()
        }
        semBox.wait()
        let (code, err) = box.lock.withLock { (box.exitCode, box.error) }
        if let error = err {
            eprint("run failed: \(terminalSafe(String(describing: error)))")
            throw ExitCode(4)
        }
        throw ExitCode(code)
    }

    // Ephemeral in-memory store for the CLI (production store is M2 GRDB).
    // RETAINED narrowly for sealed runs only (req: sealed nonpersistence
    // by default): ordinary runs use the production GRDB store below.
    // A5-2 owns export; there is deliberately no promotion path here.
    final class EphemeralStore: SessionStore, @unchecked Sendable {        private let lock = NSLock()
        private var log: [SequencedRecord] = []
        private var sessionRows: [String] = []
        private var sequence: UInt64 = 0
        private var claims: [String: String] = [:]
        func append(_ record: DurableRecord, as identity: WriterIdentity) throws {
            try lock.withLock {
                guard claims[identity.session.raw] == identity.writer else {
                    throw StoreError.notWriter(session: identity.session.raw, writer: identity.writer)
                }
                guard log.count < 10_000 else { throw StoreError.quotaExceeded(limit: 10_000) }
                sequence += 1
                log.append(SequencedRecord(sequence: SequenceNumber(sequence), record: record))
                sessionRows.append(identity.session.raw)
            }
        }
        /// A3-1 atomic override: the whole transition group is quota/fencing
        /// checked BEFORE any row lands — a breached quota at the 10k
        /// boundary fails the group whole, never partially committed.
        func appendBatch(_ records: [DurableRecord], as identity: WriterIdentity) throws {
            try lock.withLock {
                guard claims[identity.session.raw] == identity.writer else {
                    throw StoreError.notWriter(session: identity.session.raw, writer: identity.writer)
                }
                guard log.count + records.count <= 10_000 else { throw StoreError.quotaExceeded(limit: 10_000) }
                for record in records {
                    sequence += 1
                    log.append(SequencedRecord(sequence: SequenceNumber(sequence), record: record))
                    sessionRows.append(identity.session.raw)
                }
            }
        }
        func records(session: SessionID, since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) {
            guard limit > 0 else {
                throw StoreError.integrity("invalid page limit \(limit); must be > 0")
            }
            return try lock.withLock {
                let window = log.enumerated().filter {
                    $0.element.sequence.value > since && sessionRows[$0.offset] == session.raw
                }.prefix(limit).map { $0.element }
                let next: UInt64? = window.count < limit ? nil : window.last?.sequence.value
                return (window, next)
            }
        }
        /// UNSCOPED diagnostic read (support tooling/tests only).
        func records(since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) {
            try lock.withLock {
                let matching = log.filter { $0.sequence.value > since }
                let window = matching.prefix(limit)
                let batch = Array(window)
                let hasMore = matching.count > batch.count
                let next: UInt64? = hasMore ? batch.last?.sequence.value : nil
                return (batch, next)
            }
        }
        func claimWriterOwnership(session: SessionID, writer: String) throws {
            try lock.withLock {
                if let current = claims[session.raw], current != writer {
                    throw StoreError.alreadyOwned(session: session.raw, writer: current)
                }
                claims[session.raw] = writer
            }
        }
        /// B5-B session enumeration: sessions with appended records.
        func sessions() throws -> [SessionID] {
            lock.withLock {
                Array(Set(sessionRows)).sorted().map(SessionID.init)
            }
        }
        func releaseWriterOwnership(session: SessionID, writer: String) throws {
            try lock.withLock {
                guard claims[session.raw] == writer else {
                    throw StoreError.notWriter(session: session.raw, writer: writer)
                }
                claims[session.raw] = nil
            }
        }
    }

    /// A5-1 production state location. Explicit, private, XDG-compatible:
    /// `$NEEDLETAIL_STATE_DIR` wins (isolated test dirs and explicit
    /// operator placement), else absolute `$XDG_DATA_HOME/needletail`,
    /// else `~/.local/share/needletail`. A relative XDG value is invalid
    /// per the XDG Base Directory specification and is ignored (falls
    /// through to HOME) rather than scattering a store per working
    /// directory. No silent fallback — without a home the run refuses
    /// to start rather than scattering state.
    static func resolveStateDirectory() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["NEEDLETAIL_STATE_DIR"], !override.isEmpty {
            return override
        }
        if let xdg = environment["XDG_DATA_HOME"], xdg.hasPrefix("/") {
            return xdg + "/needletail"
        }
        if let home = environment["HOME"], !home.isEmpty {
            return home + "/.local/share/needletail"
        }
        eprint("error: cannot determine a private state directory (set NEEDLETAIL_STATE_DIR or HOME). Refusing to run without durable state.")
        throw ExitCode(2)
    }

    /// Enforces private mode on a managed path, failing closed instead of
    /// silently keeping lax permissions (a file the process can write but
    /// not chmod — foreign owner, ACL/FUSE setup — must refuse the run,
    /// not complete it on a world-readable database).
    private static func enforcePrivateFile(_ path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        let mode = try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        guard mode == 0o600 else {
            eprint("store error: cannot establish private permissions on \(terminalSafe(path)). Refusing to run on a non-private store.")
            throw ExitCode(6)
        }
    }

    /// Opens (never creates-over) the production store at the resolved
    /// state directory. The directory is created private (0700, repaired
    /// when pre-existing); the database file itself is enforced 0600.
    /// An existing incompatible store fails closed — never overwritten,
    /// never silently replaced with memory.
    static func openProductionStore() throws -> GRDBSessionStore {
        let directory = try resolveStateDirectory()
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        } catch {
            eprint("error: cannot establish private state directory at \(terminalSafe(directory)): \(terminalSafe(String(describing: error)))")
            throw ExitCode(4)
        }
        let dbPath = (directory as NSString).appendingPathComponent("store.sqlite")
        let store: GRDBSessionStore
        do {
            store = try GRDBSessionStore(path: dbPath)
        } catch {
            // Corrupt, future-schema or foreign files fail closed here —
            // the CLI never deletes or replaces them, and never falls
            // back to memory (which would silently discard durability).
            eprint("store error: cannot open durable store at \(terminalSafe(dbPath)): \(terminalSafe(String(describing: error)))")
            throw ExitCode(6)
        }
        // Enforce 0600 on the database and any live sidecars (covers
        // pre-existing lax modes; fresh files are already 0600 via the
        // process umask set at startup).
        try enforcePrivateFile(dbPath)
        try enforcePrivateFile(dbPath + "-wal")
        try enforcePrivateFile(dbPath + "-shm")
        return store
    }

    private static func executeStatic(prompt: String, config: String?, trace: String?, format: String?, tools: String?, alias: String?, maxTurns: Int?, sealed: Bool, trusted: Bool, workspace: String?, readRoot: [String], acknowledgedDetermination: String?, isJSONL: Bool) async throws {
        // Unused format param kept for future envelope versioning
        _ = format
        // Private-by-default file creation for EVERYTHING this process
        // writes (SPEC §9.2: dirs 0700, files 0600 — database, WAL,
        // artifacts, trace output). Set once, up front: sealed runs never
        // reach openProductionStore, but their trace output (and any
        // future file) falls under the same rule. Fresh files created
        // under this mask are private by construction; pre-existing lax
        // files are repaired-and-verified below, never silently kept.
        #if canImport(Glibc)
        _ = Glibc.umask(0o077)
        #elseif canImport(Darwin)
        _ = Darwin.umask(0o077)
        #endif
        // 1. Load and validate config
        let configPath: String
        if let explicit = config {
            configPath = explicit
        } else if let fallback = defaultConfigPath() {
            configPath = fallback
        } else {
            eprint("error $: configNotFound — no configuration file found. Fix: pass --config PATH.")
            throw ExitCode(2)
        }
        let data: Data
        do {
            data = try readBoundedFile(configPath)
        } catch let error as ConfigError {
            eprint("\(error)")
            throw ExitCode(2)
        }
        let snapshot: ConfigSnapshot
        do {
            snapshot = try validateConfig(data)
        } catch let error as ConfigError {
            eprint("\(error)")
            throw ExitCode(2)
        }
        let aliasToUse = alias ?? snapshot.defaultAlias
        guard let profile = snapshot.profiles[aliasToUse] else {
            eprint("error $.models: missingReference — unknown model alias '\(terminalSafe(aliasToUse))'.")
            throw ExitCode(2)
        }
        // 2. Route check (authorize-before-dial)
        let route = authorizeRequestDestination(snapshot: snapshot, requestedAlias: aliasToUse, sealed: false)
        guard case .allowed(let endpoint, _) = route else {
            eprint("route denied for alias '\(terminalSafe(aliasToUse))'")
            throw ExitCode(2)
        }
        // 3. Effective caps and epoch — default is fail-closed
        // (workspace deny-all, mode workspace) per §10/ARCH. The demo
        // fixture explicitly opts into trustedExec via --trusted.
        // B1: workspace/read-root grants resolve the blanket allDenied.
        let mode: TrustMode = trusted ? .trustedExec : .workspace
        let workspaceGrant: ToolCapabilities
        if trusted {
            workspaceGrant = .allAllowed
        } else if workspace != nil {
            workspaceGrant = ToolCapabilities(read: true, search: true, edit: true, write: true, exec: .denied, consult: false)
        } else if !readRoot.isEmpty {
            workspaceGrant = ToolCapabilities(read: true, search: true, edit: false, write: false, exec: .denied, consult: false)
        } else {
            workspaceGrant = .allDenied
        }
        let effective = effectiveCapabilities(
            build: .allAllowed, userConfig: snapshot.tools,
            workspaceGrant: workspaceGrant, invocationMask: .allAllowed,
            sealed: SealedRestrictions(sealed: sealed))
        do {
            _ = try validateTrustConsistency(mode: mode, caps: effective.tools)
        } catch {
            eprint("trust inconsistency: \(error)")
            throw ExitCode(2)
        }
        let epoch = EpochDescriptor(
            epochID: EpochID("epoch-run-\(UUID().uuidString)"),
            configSnapshot: snapshot, profile: profile,
            effectiveCaps: effective, route: route)
        let state = SessionState(
            sessionID: SessionID("sess-run-\(UUID().uuidString)"),
            epoch: epoch, trustMode: mode, phase: .idle,
            turnLimit: maxTurns ?? 80)
        // Turn limit: explicit CLI flag bounds the run; invalid values are
        // argument errors (ExitCode 2), never silently ignored.
        if let max = maxTurns {
            guard max > 0 else {
                eprint("error $.cli.--max-turns: must be a positive integer.")
                throw ExitCode(2)
            }
        }
        // A5-1: ordinary runs use the production GRDB store; sealed runs
        // keep the narrowly scoped volatile exception (no sealed
        // source/prompt bytes may land in persistent files).
        // Existentials cannot bind SessionActor's Store parameter on this
        // toolchain, so the choice is an explicit dispatch enum — one
        // forwarding method per seam, no behavior of its own.
        enum CLIStore: SessionStore {
            case ephemeral(EphemeralStore)
            case durable(GRDBSessionStore)

            func append(_ record: DurableRecord, as identity: WriterIdentity) throws {
                switch self {
                case .ephemeral(let s): try s.append(record, as: identity)
                case .durable(let s): try s.append(record, as: identity)
                }
            }

            func appendBatch(_ records: [DurableRecord], as identity: WriterIdentity) throws {
                switch self {
                case .ephemeral(let s): try s.appendBatch(records, as: identity)
                case .durable(let s): try s.appendBatch(records, as: identity)
                }
            }

            func records(session: SessionID, since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) {
                switch self {
                case .ephemeral(let s): try s.records(session: session, since: since, limit: limit)
                case .durable(let s): try s.records(session: session, since: since, limit: limit)
                }
            }

            func records(since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) {
                switch self {
                case .ephemeral(let s): try s.records(since: since, limit: limit)
                case .durable(let s): try s.records(since: since, limit: limit)
                }
            }

            func claimWriterOwnership(session: SessionID, writer: String) throws {
                switch self {
                case .ephemeral(let s): try s.claimWriterOwnership(session: session, writer: writer)
                case .durable(let s): try s.claimWriterOwnership(session: session, writer: writer)
                }
            }

            /// B5-B enumeration forwarding (mechanical, like every other seam).
            func sessions() throws -> [SessionID] {
                switch self {
                case .ephemeral(let s): try s.sessions()
                case .durable(let s): try s.sessions()
                }
            }

            func releaseWriterOwnership(session: SessionID, writer: String) throws {
                switch self {
                case .ephemeral(let s): try s.releaseWriterOwnership(session: session, writer: writer)
                case .durable(let s): try s.releaseWriterOwnership(session: session, writer: writer)
                }
            }
        }

        let store: CLIStore
        let grdb: GRDBSessionStore?
        if sealed {
            store = .ephemeral(EphemeralStore())
            grdb = nil
        } else {
            let production = try openProductionStore()
            store = .durable(production)
            grdb = production
        }
        let sink: any UISink
        let traceHandle: FileHandle?
        if let tracePath = trace {
            // Explicit operator output: created private (0600) at once
            // rather than relying on umask alone, since sealed runs may
            // carry sensitive prompts through this file.
            guard FileManager.default.createFile(
                atPath: tracePath, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                eprint("cannot create trace file \(tracePath)")
                throw ExitCode(2)
            }
            guard let handle = FileHandle(forWritingAtPath: tracePath) else {
                eprint("cannot open trace file \(tracePath)")
                throw ExitCode(2)
            }
            traceHandle = handle
            if isJSONL {
                // Tee: both stdout and trace file get same JSONL
                let stdoutSink = FileHandleUISink(handle: FileHandle.standardOutput, sessionID: state.sessionID.raw, ownsHandle: false)
                let fileSink = FileHandleUISink(handle: handle, sessionID: state.sessionID.raw, ownsHandle: true)
                sink = TeeUISink(primary: stdoutSink, secondary: fileSink)
            } else {
                sink = FileHandleUISink(handle: handle, sessionID: state.sessionID.raw, ownsHandle: true)
            }
        } else if isJSONL {
            sink = FileHandleUISink(handle: FileHandle.standardOutput, sessionID: state.sessionID.raw, ownsHandle: false)
            traceHandle = nil
        } else {
            sink = NoopUISink()
            traceHandle = nil
        }
        defer { try? traceHandle?.close() }

        // 4. Scripted backend
        let scriptEntries: [ScriptedToolBackend.Entry]
        if let toolsPath = tools {
            let toolData: Data
            do {
                toolData = try readBoundedFile(toolsPath, limit: 1024 * 1024)
            } catch {
                eprint("error $.tools.: invalidToolScript — \(terminalSafe(String(describing: error))). Fix: pass a valid --tools JSON file.")
                throw ExitCode(2)
            }
            let object: Any
            do {
                object = try JSONSerialization.jsonObject(with: toolData)
            } catch {
                eprint("error $.tools.: malformedJSON — \(terminalSafe(String(describing: error))). Fix: validate the tools file as JSON.")
                throw ExitCode(2)
            }
            guard let array = object as? [[String: Any]] else {
                eprint("tools script must be JSON array")
                throw ExitCode(2)
            }
            var entries: [ScriptedToolBackend.Entry] = []
            for obj in array {
                guard let tool = obj["tool"] as? String,
                      let result = obj["result"] as? String else {
                    eprint("each tools entry needs tool and result")
                    throw ExitCode(2)
                }
                let arguments: String
                if let argStr = obj["arguments"] as? String {
                    arguments = argStr
                } else if let argObj = obj["arguments"] {
                    let data = try JSONSerialization.data(withJSONObject: argObj, options: [.sortedKeys])
                    arguments = String(data: data, encoding: .utf8) ?? "{}"
                } else {
                    arguments = "{}"
                }
                entries.append(ScriptedToolBackend.Entry(tool: tool, arguments: arguments, result: result))
            }
            scriptEntries = entries
        } else {
            scriptEntries = []
        }
        let backend = ScriptedToolBackend(script: scriptEntries, caps: effective.tools)

        // 5. Run identities BEFORE any network client exists. The explicit
        // claim fences this writer; the actor re-claims the same identity
        // idempotently at init. Persisting + verifying + reconciling here
        // (rather than after transport setup) guarantees no store failure
        // can strand a live HTTP client: every failure below this point
        // happens before the client is constructed, so there is nothing
        // to leak (an un-shut-down client fatals the process on deinit).
        let writerID = UUID().uuidString
        if let production = grdb {
            let runIdentity = WriterIdentity(session: state.sessionID, writer: writerID)
            do {
                try production.claimWriterOwnership(session: state.sessionID, writer: writerID)
                try production.appendBatch([
                    .sessionOpened(session: state.sessionID, atMillis: SystemClock().nowMillis()),
                    .epochOpened(epoch),
                ], as: runIdentity)
                // Read-your-write: the two identity rows must come back
                // first through a fresh session-scoped read. Reconcile
                // ignores non-operation records by design, so only this
                // read proves they persisted.
                let (prefix, _) = try production.records(session: state.sessionID, since: 0, limit: 10)
                guard prefix.count >= 2,
                      case .sessionOpened(let openedSession, _) = prefix[0].record,
                      openedSession == state.sessionID,
                      case .epochOpened = prefix[1].record else {
                    eprint("store error: run identities did not persist; refusing to run without durable session.")
                    throw ExitCode(6)
                }
                let report = try production.reconcile(session: state.sessionID)
                guard report.completed.isEmpty, report.heldOperations.isEmpty,
                      report.unmatchedMutating.isEmpty, report.unmatchedNonMutating.isEmpty,
                      report.explicitUnknown.isEmpty, report.orphanResults.isEmpty,
                      report.admissionIntents == 0, report.nonToolResults == 0 else {
                    eprint("store error: fresh session reconciles unclean; refusing to run on a corrupt ledger.")
                    throw ExitCode(6)
                }
            } catch let error as ExitCode {
                throw error
            } catch {
                eprint("store error: cannot persist run identities: \(terminalSafe(String(describing: error)))")
                throw ExitCode(6)
            }
            // B5-B(i): settle the byte ledger under the existing artifact
            // lock BEFORE the gate reads history. Reuses B3's
            // reconcileByteUsage — no second accounting mechanism. A
            // byte-reconciliation failure fails the run closed (exit 6)
            // with no provider traffic and no filesystem mutation past
            // this point.
            do {
                _ = try production.reconcileByteUsage()
            } catch let error as ExitCode {
                throw error
            } catch {
                eprint("store error: byte reconciliation failed: \(terminalSafe(String(describing: error)))")
                throw ExitCode(6)
            }
            // B5-B(ii): read-only cross-session operation reconciliation.
            // The gate performs NO writes and runs BEFORE any provider or
            // tool dispatch (transport is constructed in step 6 below).
            // An unreadable session ledger fails closed here (exit 6) —
            // never treated as clean, and no acknowledgment can cure it.
            let holds: [CrossSessionHold]
            do {
                holds = try CrossRunGate.unresolvedHolds(store: production)
            } catch let error as ExitCode {
                throw error
            } catch {
                eprint("store error: cross-run gate cannot verify history: \(terminalSafe(String(describing: error)))")
                throw ExitCode(6)
            }
            if !holds.isEmpty {
                let namedSessions = holds.map(\.session.raw).sorted().map { terminalSafe($0) }.joined(separator: ", ")
                let heldOpCount = holds.reduce(0) { $0 + $1.operationIDs.count }
                if let determination = acknowledgedDetermination {
                    // The RECORD is the decision — the flag alone authorizes
                    // nothing. Append under this run's fenced writer
                    // identity AFTER claim + sessionOpened, verify
                    // persistence, and only then permit dispatch. Original
                    // unresolved markers are preserved untouched.
                    let acknowledgment = Acknowledgment(
                        subjectSessions: holds.map(\.session),
                        operationIDs: holds.flatMap(\.operationIDs),
                        determination: determination,
                        atMillis: SystemClock().nowMillis())
                    do {
                        try CrossRunGate.appendAcknowledgment(
                            store: production, as: runIdentity,
                            acknowledgment: acknowledgment)
                    } catch let error as ExitCode {
                        throw error
                    } catch {
                        eprint("store error: cannot record acknowledgment: \(terminalSafe(String(describing: error)))")
                        throw ExitCode(6)
                    }
                    eprint("acknowledged \(heldOpCount) unresolved operation(s) in session(s) \(namedSessions) as '\(terminalSafe(determination))' (recorded in session \(state.sessionID.raw); history preserved)")
                } else {
                    // This gate IS a non-interactive approval check (same
                    // code as approval-required): the invocation is
                    // well-formed and no TTY interaction can satisfy it —
                    // only the explicit flag. NOT exit 4 (no run/ambiguous
                    // delivery occurred) and NOT exit 6 (the ledgers are
                    // readable; their outcomes are unknown, not corrupt).
                    eprint("blocked: unresolved mutating outcomes in session(s) \(namedSessions) (\(heldOpCount) operation(s)) — an explicit operator decision is required before mutating work. Inspect with `needletail session export SESSION --output FILE`, then re-run with --acknowledge-unresolved-outcomes 'operator-accepted-risk' (or 'manually-reconciled:<note>').")
                    throw ExitCode(3)
                }
            }
        }

        // 6. Transport with transcript-based messageProvider
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton,
                                    configuration: ChatTransportPolicy.configuration(profile: profile))
        // Use the session store (GRDB production or sealed-volatile) for transcript paging
        let promptCopy = prompt
        let messageProvider: @Sendable (ProviderInvocation) async throws -> [ChatMessage] = { _ in
            // Paged transcript (M1-D D1): read from store, map to messages
            // Over-limit throws, which surfaces as preSend failure (honest)
            do {
                let messages = try loadTranscript(from: store, session: state.sessionID, limit: 1024)
                // If no transcript yet (should have user prompt), fallback to prompt
                if messages.isEmpty {
                    return [ChatMessage(role: .user, text: promptCopy)]
                }
                return messages
            }
        }
        let credentialStore = EnvFileCredentialStore()
        let transport = ChatCompletionsTransport(
            client: httpClient,
            messageProvider: messageProvider,
            credentialProvider: { ref, op in try credentialStore.resolve(ref, for: op) },
            snapshotProvider: { snapshot })

        // 7. Actor
        // The fencing claim above already established this writer identity;
        // the actor re-claims it idempotently here (same-identity re-claim
        // is the documented crash-recovery re-acquire, never a conflict).
        // Actor init is the last throwing call before provider work: on the
        // (near-impossible) failure path the client is shut down first, so
        // a store fault can never strand it into a deinit fatalError.
        let actor: SessionActor<
            ChatCompletionsTransport, ScriptedToolBackend, CLIStore,
            HeadlessApprovals, SystemClock, DeterministicIDSource
        >
        do {
            actor = try SessionActor(
                state: state, ids: DeterministicIDSource(prefix: "run"), clock: SystemClock(),
                transport: transport, executor: backend, store: store,
                approvals: HeadlessApprovals(), sink: sink, writer: writerID)
        } catch {
            try? await httpClient.shutdown().get()
            throw error
        }

        // H2: catchable SIGINT drives production cancellation (not a default
        // termination), so JSONL runs can emit terminal run_finished and
        // return 130. Broken-pipe handling remains unchanged.
#if canImport(Glibc)
        signal(SIGINT, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
#endif
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigintSource.setEventHandler {
            Task { @Sendable in
                await actor.cancel()
            }
        }
        sigintSource.resume()
        defer { sigintSource.cancel() }

        // 8. Submit and wait for completion (multi-turn loop)
        await actor.submitText(commandID: CommandID("cmd-run"), text: prompt, kind: .followUp, sealed: sealed)
        // Poll for terminal phase with timeout (max 60s per run, plus turn budget)
        let deadline = Date().addingTimeInterval(max(60.0, Double(maxTurns ?? 80) * Double(max(1, profile.requestTimeout))))
        var finalState: SessionState?
        var approvalRequest: ApprovalRequest?
        while Date() < deadline {
            let current = await actor.currentState()
            switch current.phase {
            case .completed, .failed, .interrupted:
                finalState = current
                break
            case .authorising where current.pendingApproval != nil:
                // Headless approval never blocks forever (POLICY-04, SPEC
                // §12.2 exit 3): capture the structured request and return.
                approvalRequest = current.pendingApproval
                finalState = current
                break
            default:
                if current.queueHeld && !current.unresolvedOperations.isEmpty {
                    finalState = current
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                continue
            }
            if finalState != nil { break }
        }
        let done: SessionState
        if let f = finalState {
            done = f
        } else {
            await actor.cancel()
            done = await actor.currentState()
            let reason = terminalSafe("run did not complete within the wall budget")
            eprint("run did not complete within timeout")
            if isJSONL {
                try? await sink.emitTerminal(outcome: "budget_exhausted", detail: reason)
            }
            try? await httpClient.shutdown().get()
            throw ExitCode(5)
        }
        // Shutdown HTTP client before handling output (actor no longer needs it)
        try? await httpClient.shutdown().get()
        if done.queueHeld && !done.unresolvedOperations.isEmpty && !done.phase.isTerminal {
            // Non-terminal hold with unknown outcomes: ambiguous delivery
            // needs explicit reconciliation (exit 4, provider-shaped).
            // A TERMINAL phase (failed, interrupted, completed) falls
            // through to the phase switch below (integrity → 6): a failed
            // persistence commit must never masquerade as a provider
            // outcome (SPEC §12.2).
            let marker = done.unresolvedOperations.compactMap { $0.callID }.joined(separator: ",")
            let reason = terminalSafe("ambiguous delivery; reconcile unresolved operation(s): \(marker)")
            if isJSONL {
                try? await sink.emitTerminal(outcome: "ambiguous", detail: reason)
            }
            eprint("held: ambiguous delivery requires explicit reconciliation: \(reason)")
            try? await httpClient.shutdown().get()
            throw ExitCode(4)
        }
        if let approval = approvalRequest {
            let reason = "approval required for \(approval.operation)"
            if isJSONL {
                try? await sink.emitTerminal(outcome: "approval_required", detail: reason)
            }
            eprint("approval required: \(terminalSafe(reason))")
            // Shut down before throwing: every post-client exit path must
            // release the client, or its deinit fatals the process.
            try? await httpClient.shutdown().get()
            throw ExitCode(3)
        }
        // Also emit terminal run_finished envelope if JSONL
        if isJSONL {
            let outcome: String
            let detail: String
            switch done.phase {
            case .completed(let receipt):
                outcome = "completed"
                detail = "turns=\(receipt.turnsUsed)"
                try? await sink.emitTerminal(outcome: outcome, detail: detail)
                // A5-1 claim retention: release ONLY at a proven quiescent,
                // clean boundary (completed run, no unresolved operations).
                // Failed, interrupted or held runs keep their claim row AND
                // their holds — never auto-released, never silently
                // discarded. Retention policy: claim rows accumulate until
                // an explicit operator cleanup (A5-2 owns export/reconcile
                // tooling); the ledger is the audit trail.
                if done.unresolvedOperations.isEmpty {
                    do {
                        try store.releaseWriterOwnership(session: state.sessionID, writer: writerID)
                    } catch {
                        eprint("warning: completed run but ownership release failed: \(terminalSafe(String(describing: error)))")
                    }
                }
                // Human final answer goes to stderr in JSONL mode and is
                // terminal-safe: no control scalar reaches the terminal or
                // JSON diagnostics.
                if let last = try? loadTranscript(from: store, session: state.sessionID).last, last.role == ChatRole.assistant {
                    var err = StandardErrorStream()
                    print(terminalSafe(last.text), to: &err)
                }
                return
            case .failed(let failure):
                // Map RunFailure to exit code per §12.2
                switch failure {
                case .approvalDenied(let msg):
                    try? await sink.emitTerminal(outcome: "approval_required", detail: msg)
                    eprint("approval required: \(terminalSafe(msg))")
                    throw ExitCode(3)
                case .budgetExhausted:
                    try? await sink.emitTerminal(outcome: "budget_exhausted", detail: "\(failure)")
                    eprint("budget exhausted: \(failure)")
                    throw ExitCode(5)
                case .integrityStopped:
                    try? await sink.emitTerminal(outcome: "integrity", detail: "\(failure)")
                    eprint("integrity failure: \(failure)")
                    throw ExitCode(6)
                case .providerError(let msg):
                    try? await sink.emitTerminal(outcome: "provider_error", detail: msg)
                    eprint("provider failure: \(terminalSafe(msg))")
                    throw ExitCode(4)
                case .invalidStopped(let msg):
                    try? await sink.emitTerminal(outcome: "invalid", detail: msg)
                    eprint("invalid: \(terminalSafe(msg))")
                    throw ExitCode(2)
                }
            case .interrupted:
                try? await sink.emitTerminal(outcome: "interrupted", detail: "interrupted")
                eprint("interrupted")
                throw ExitCode(130)
            default:
                eprint("run ended in unexpected phase \(done.phase)")
                throw ExitCode(4)
            }
        } else {
            // Non-JSONL: print final assistant text to stdout, diagnostics to stderr
            switch done.phase {
            case .completed:
                if let last = try? loadTranscript(from: store, session: state.sessionID).last, last.role == ChatRole.assistant {
                    print(terminalSafe(last.text))
                } else if let transcript = try? loadTranscript(from: store, session: state.sessionID), let lastAssistant = transcript.reversed().first(where: { $0.role == ChatRole.assistant }) {
                    print(terminalSafe(lastAssistant.text))
                }
                // A5-1 claim retention (see JSONL path): release only on a
                // proven-clean completed run.
                if done.unresolvedOperations.isEmpty {
                    do {
                        try store.releaseWriterOwnership(session: state.sessionID, writer: writerID)
                    } catch {
                        eprint("warning: completed run but ownership release failed: \(terminalSafe(String(describing: error)))")
                    }
                }
                return
            case .failed(let failure):
                eprint("run failed: \(failure)")
                switch failure {
                case .approvalDenied: throw ExitCode(3)
                case .budgetExhausted: throw ExitCode(5)
                case .integrityStopped: throw ExitCode(6)
                case .invalidStopped: throw ExitCode(2)
                case .providerError: throw ExitCode(4)
                }
            case .interrupted:
                eprint("interrupted")
                throw ExitCode(130)
            default:
                eprint("run ended in \(done.phase)")
                throw ExitCode(4)
            }
        }
    }
}

/// Headless approvals: tool approval always unavailable (headless must not
/// block forever); the transition will hold the run and the CLI maps it to
/// exit 3 per §12.2.
struct HeadlessApprovals: ApprovalGateway, Sendable {
    func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
        .unavailable("headless approval required for \(request.operation)")
    }
}

/// System clock for production CLI (real wall time, not VirtualClock).
struct SystemClock: Clock, Sendable {
    func nowMillis() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
}

/// Tee sink for JSONL to both stdout and trace file.
final class TeeUISink: UISink, Sendable {
    let primary: any UISink
    let secondary: any UISink
    init(primary: any UISink, secondary: any UISink) {
        self.primary = primary
        self.secondary = secondary
    }
    func emit(_ projection: SessionEventProjection) async throws {
        // Write to both; if primary fails with broken pipe, propagate 130,
        // but still try secondary for trace.
        do {
            try await primary.emit(projection)
        } catch let error as UISinkError where error == .brokenPipe {
            try? await secondary.emit(projection)
            throw error
        }
        try await secondary.emit(projection)
    }
}
