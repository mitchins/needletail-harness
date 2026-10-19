import ArgumentParser
import Foundation
import NeedletailCore
import NeedletailProviders
import NeedletailRuntime
import AsyncHTTPClient
import Dispatch
#if canImport(Glibc)
import Glibc
#endif
import NIOCore

/// `needletail run` (M1-D): headless coding-agent loop via production
/// `SessionActor` + `ChatCompletionsTransport` + `ScriptedToolBackend`.
/// No real filesystem writes, no GRDB, no cloud fallback. The transcript
/// lives as `DurableRecord.transcriptAppended` paged from the store.
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

    mutating func run() throws {
        let isJSONL = format?.lowercased() == "jsonl"
        if let format, !["json", "human", "jsonl"].contains(format.lowercased()) {
            eprint("error $.cli.--format: must be 'jsonl', 'human', or 'json'.")
            throw ExitCode(2)
        }
        // Capture values for Sendable closure (mutating self cannot be captured)
        let promptCopy = prompt
        let configCopy = config
        let traceCopy = trace
        let formatCopy = format
        let toolsCopy = tools
        let aliasCopy = alias
        let maxTurnsCopy = maxTurns
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
                    maxTurns: maxTurnsCopy, sealed: sealedCopy, trusted: trustedCopy, isJSONL: isJSONL)
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
    final class EphemeralStore: SessionStore, @unchecked Sendable {
        private let lock = NSLock()
        private var log: [SequencedRecord] = []
        private var sessions: [String] = []
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
                sessions.append(identity.session.raw)
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
                    sessions.append(identity.session.raw)
                }
            }
        }
        func records(session: SessionID, since: UInt64, limit: Int) throws -> ([SequencedRecord], nextCursor: UInt64?) {
            guard limit > 0 else {
                throw StoreError.integrity("invalid page limit \(limit); must be > 0")
            }
            return try lock.withLock {
                let window = log.enumerated().filter {
                    $0.element.sequence.value > since && sessions[$0.offset] == session.raw
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
        func releaseWriterOwnership(session: SessionID, writer: String) throws {
            try lock.withLock {
                guard claims[session.raw] == writer else {
                    throw StoreError.notWriter(session: session.raw, writer: writer)
                }
                claims[session.raw] = nil
            }
        }
    }

    private static func executeStatic(prompt: String, config: String?, trace: String?, format: String?, tools: String?, alias: String?, maxTurns: Int?, sealed: Bool, trusted: Bool, isJSONL: Bool) async throws {
        // Unused format param kept for future envelope versioning
        _ = format
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
        let mode: TrustMode = trusted ? .trustedExec : .workspace
        let workspaceGrant: ToolCapabilities = trusted ? .allAllowed : .allDenied
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
        let store = EphemeralStore()
        let sink: any UISink
        let traceHandle: FileHandle?
        if let tracePath = trace {
            FileManager.default.createFile(atPath: tracePath, contents: nil)
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

        // 5. Transport with transcript-based messageProvider
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton,
                                    configuration: ChatTransportPolicy.configuration(profile: profile))
        // Use InMemory store for transcript paging
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

        // 6. Actor
        // A2 fencing: the actor claims this session for a unique
        // per-process writer identity in its own (throwing) init.
        let writerID = UUID().uuidString
        let actor = try SessionActor(
            state: state, ids: DeterministicIDSource(prefix: "run"), clock: SystemClock(),
            transport: transport, executor: backend, store: store,
            approvals: HeadlessApprovals(), sink: sink, writer: writerID)

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

        // 7. Submit and wait for completion (multi-turn loop)
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
        if done.queueHeld && !done.unresolvedOperations.isEmpty {
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
