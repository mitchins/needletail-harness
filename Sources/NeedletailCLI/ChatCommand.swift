import ArgumentParser
import Foundation
import SystemPackage
import NeedletailCore
import NeedletailRuntime
import NeedletailProviders
import NeedletailPresentation
import NeedletailTerminal
import NeedletailLineEditor
import AsyncHTTPClient
import Dispatch
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import NIOCore

/// `needletail chat` (M4-C): real interactive terminal presentation
/// adapter over the qualified M4-B pure contracts.
///
/// Composition root ONLY: config/store/transport/actor setup mirrors
/// `run` (same validation, same gates, same durability), then drives
/// the `ChatLoop` runloop. The terminal never owns agent state: every
/// operator intent becomes a `UIEffect` the edge translates into actor
/// calls; every display byte flows through the single
/// `TerminalOutputOwner`.
///
/// Headless `run` is untouched (same binary, separate command).
/// M4-D owns PTY acceptance, lifecycle/cleanup and release smoke.
struct ChatCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chat",
        abstract: "Run an interactive terminal session (M4-C adapter).")

    @Option(name: .long, help: "Explicit configuration file path.")
    var config: String?

    @Option(name: .long, help: "Model alias to run (defaults to config default_model).")
    var alias: String?

    @Option(name: .long, help: "Maximum turns for this session (default 80).")
    var maxTurns: Int?

    @Option(name: .long, help: "Workspace root (must exist) for mutating file tools.")
    var workspace: String?

    @Flag(name: .long, help: "Allow native command execution inside the workspace (requires --workspace; every command needs explicit operator approval of its resolved identity; config tools.exec must also be granted).")
    var allowExec: Bool = false

    @Option(name: .customLong("sandbox-grant"), help: "Container-scoped automatic approval via the launcher-issued grant file. Requires --workspace. Never use on an ordinary host run.")
    var sandboxGrant: String?

    @Option(name: .customLong("read-root"), help: "Read-only root for read/search (may be repeated).")
    var readRoot: [String] = []

    @Option(name: .long, help: "Trace file path for JSONL output (in addition to terminal display).")
    var trace: String?

    @Option(name: .customLong("acknowledge-unresolved-outcomes"),
            help: "Explicit operator decision for the cross-run gate: 'operator-accepted-risk' or 'manually-reconciled:<note>'.")
    var acknowledgeUnresolvedOutcomes: String?

    mutating func run() throws {
        // Interactive requires a real terminal on stdin AND stdout;
        // automation keeps using headless `run` (contract preserved).
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
            eprint("chat requires an interactive terminal (stdin and stdout must be TTYs); use `needletail run` for automation.")
            throw ExitCode(2)
        }
        let configCopy = config
        let traceCopy = trace
        let aliasCopy = alias
        let maxTurnsCopy = maxTurns
        let workspaceCopy = workspace
        let readRootCopy = readRoot
        let sandboxGrantCopy = sandboxGrant
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
        let allowExecCopy = allowExec
        Task { @Sendable in
            do {
                try await ChatCommand.executeStatic(
                    config: configCopy, trace: traceCopy, alias: aliasCopy,
                    maxTurns: maxTurnsCopy, allowExec: allowExecCopy,
                    workspace: workspaceCopy, readRoot: readRootCopy,
                    sandboxGrant: sandboxGrantCopy,
                    acknowledgedDetermination: acknowledgedDetermination)
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
            eprint("chat failed: \(terminalSafe(String(describing: error)))")
            throw ExitCode(4)
        }
        throw ExitCode(code)
    }

    /// Backend sum for chat (durable native or scripted fallback — no
    /// sealed/ephemeral path; chat is never sealed).
    enum ChatExecutor: ToolExecutor {
        case scripted(ScriptedToolBackend)
        case native(NativeToolExecutor)

        func describe(batch: ToolBatch) -> String {
            switch self {
            case .scripted(let b): b.describe(batch: batch)
            case .native(let b): b.describe(batch: batch)
            }
        }

        func execute(batch: ToolBatch, reservation: EffectReservation) async throws -> ExecutorResult {
            switch self {
            case .scripted(let b): try await b.execute(batch: batch, reservation: reservation)
            case .native(let b): try await b.execute(batch: batch, reservation: reservation)
            }
        }
    }

    /// UISink fan-in: every actor projection becomes a loop event.
    final class ChatSink: UISink, @unchecked Sendable {
        var post: (@Sendable (ChatLoop.Event) -> Void)?
        func emit(_ projection: SessionEventProjection) async throws {
            post?(.projection(projection))
        }
    }

    typealias ChatActor = SessionActor<
        DeltaTapTransport<ChatCompletionsTransport>, ChatExecutor, GRDBSessionStore,
        AnyApprovalGateway, SystemClock, DeterministicIDSource
    >

    final class ActorRef: @unchecked Sendable {
        private let lock = NSLock()
        private var actor: ChatActor?
        func set(_ actor: ChatActor) { lock.withLock { self.actor = actor } }
        func get() -> ChatActor? { lock.withLock { actor } }
    }

    private static func executeStatic(config: String?, trace: String?, alias: String?, maxTurns: Int?, allowExec: Bool, workspace: String?, readRoot: [String], sandboxGrant: String?, acknowledgedDetermination: String?) async throws {
        #if canImport(Glibc)
        _ = Glibc.umask(0o077)
        #elseif canImport(Darwin)
        _ = Darwin.umask(0o077)
        #endif
        // 1. Config (same validation as `run`).
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
        let route = authorizeRequestDestination(snapshot: snapshot, requestedAlias: aliasToUse, sealed: false)
        guard case .allowed = route else {
            eprint("route denied for alias '\(terminalSafe(aliasToUse))'")
            throw ExitCode(2)
        }
        // 2. Caps (chat is never sealed/trusted: workspace/read-root
        // grants only; otherwise all-denied, like a denied-caps demo).
        let mode: TrustMode = .workspace
        let workspaceGrant: ToolCapabilities
        if workspace != nil {
            workspaceGrant = ToolCapabilities(read: true, search: true, edit: true, write: true, exec: allowExec ? .ask : .denied, consult: false)
        } else if !readRoot.isEmpty {
            workspaceGrant = ToolCapabilities(read: true, search: true, edit: false, write: false, exec: .denied, consult: false)
        } else {
            workspaceGrant = .allDenied
        }
        let effective = effectiveCapabilities(
            build: .allAllowed, userConfig: snapshot.tools,
            workspaceGrant: workspaceGrant, invocationMask: .allAllowed,
            sealed: SealedRestrictions(sealed: false))
        do {
            _ = try validateTrustConsistency(mode: mode, caps: effective.tools)
        } catch {
            eprint("trust inconsistency: \(error)")
            throw ExitCode(2)
        }
        let execComposed = workspace != nil && effective.tools.exec != .denied
        if workspace != nil && sandboxGrant == nil && !allowExec && effective.tools.exec != .denied {
            // Unreachable by construction (exec ceiling is .ask only via
            // --allow-exec); defensive honesty over silent trust.
            eprint("trust inconsistency: workspace exec granted without --allow-exec")
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
        if let grantPath = sandboxGrant, let ws = workspace {
            let cwd = FileManager.default.currentDirectoryPath
            func canonical(_ p: String) -> String {
                let abs = p.hasPrefix("/") ? p : (cwd as NSString).appendingPathComponent(p)
                return URL(fileURLWithPath: abs).standardizedFileURL.resolvingSymlinksInPath().path
            }
            let canonGrant = canonical(grantPath)
            let canonWS = canonical(ws)
            if canonGrant == canonWS || canonGrant.hasPrefix(canonWS + "/") {
                eprint("error: --sandbox-grant file must live outside --workspace (a model-writable grant is a self-approval)")
                throw ExitCode(2)
            }
        }
        if sandboxGrant != nil && workspace == nil {
            eprint("error: --sandbox-grant requires --workspace")
            throw ExitCode(2)
        }
        if allowExec && workspace == nil {
            eprint("error: --allow-exec requires --workspace")
            throw ExitCode(2)
        }
        // Same explicit-decision validation as `run`: an unreadable or
        // garbage determination never sneaks past the cross-run gate.
        if let ack = acknowledgedDetermination {
            guard ack == "operator-accepted-risk"
                    || (ack.hasPrefix("manually-reconciled:") && ack.dropFirst("manually-reconciled:".count).count > 0),
                  !ack.utf8.contains(0) else {
                eprint("error $.cli.--acknowledge-unresolved-outcomes: must be 'operator-accepted-risk' or 'manually-reconciled:<note>'.")
                throw ExitCode(2)
            }
        }
        let epoch = EpochDescriptor(
            epochID: EpochID("epoch-chat-\(UUID().uuidString)"),
            configSnapshot: snapshot, profile: profile,
            effectiveCaps: effective, route: route, execComposed: execComposed)
        let state = SessionState(
            sessionID: SessionID("sess-chat-\(UUID().uuidString)"),
            epoch: epoch, trustMode: mode, phase: .idle,
            turnLimit: maxTurns ?? 80)
        if let max = maxTurns {
            guard max > 0 else {
                eprint("error $.cli.--max-turns: must be a positive integer.")
                throw ExitCode(2)
            }
        }
        // 3. Store claim + gates (same durability as `run`).
        let store = try RunCommand.openProductionStore()
        let writerID = UUID().uuidString
        let runIdentity = WriterIdentity(session: state.sessionID, writer: writerID)
        do {
            try store.claimWriterOwnership(session: state.sessionID, writer: writerID)
            try store.appendBatch([
                .sessionOpened(session: state.sessionID, atMillis: SystemClock().nowMillis()),
                .epochOpened(epoch),
            ], as: runIdentity)
            // Read-your-write + fresh-session reconcile (same as `run`):
            // the two identity rows must come back first, and a fresh
            // session reconciles clean — otherwise fail closed here.
            let (prefix, _) = try store.records(session: state.sessionID, since: 0, limit: 10)
            guard prefix.count >= 2,
                  case .sessionOpened(let openedSession, _) = prefix[0].record,
                  openedSession == state.sessionID,
                  case .epochOpened = prefix[1].record else {
                eprint("store error: run identities did not persist; refusing to chat without durable session.")
                throw ExitCode(6)
            }
            let report = try store.reconcile(session: state.sessionID)
            guard report.completed.isEmpty, report.heldOperations.isEmpty,
                  report.unmatchedMutating.isEmpty, report.unmatchedNonMutating.isEmpty,
                  report.explicitUnknown.isEmpty, report.orphanResults.isEmpty,
                  report.admissionIntents == 0, report.nonToolResults == 0 else {
                eprint("store error: fresh session reconciles unclean; refusing to chat on a corrupt ledger.")
                throw ExitCode(6)
            }
        } catch let error as ExitCode {
            throw error
        } catch {
            eprint("store error: cannot persist run identities: \(terminalSafe(String(describing: error)))")
            throw ExitCode(6)
        }
        do {
            _ = try store.reconcileByteUsage()
        } catch {
            eprint("store error: byte reconciliation failed: \(terminalSafe(String(describing: error)))")
            throw ExitCode(6)
        }
        let holds: [CrossSessionHold]
        do {
            holds = try CrossRunGate.unresolvedHolds(store: store)
        } catch {
            eprint("store error: cross-run gate cannot verify history: \(terminalSafe(String(describing: error)))")
            throw ExitCode(6)
        }
        if !holds.isEmpty {
            let namedSessions = holds.map(\.session.raw).sorted().map { terminalSafe($0) }.joined(separator: ", ")
            let runMayMutate = effective.tools.edit || effective.tools.write || effective.tools.exec != .denied
            if !runMayMutate {
                eprint("note: proceeding read-only with history in session(s) \(namedSessions)")
            } else if let determination = acknowledgedDetermination {
                do {
                    try CrossRunGate.appendAcknowledgment(
                        store: store, as: runIdentity,
                        acknowledgment: Acknowledgment(
                            subjectSessions: holds.map(\.session),
                            operationIDs: holds.flatMap(\.operationIDs),
                            determination: determination,
                            atMillis: SystemClock().nowMillis(),
                            queueEntryIDs: holds.flatMap(\.unknownQueueDeliveries).map(\.entryID)))
                } catch {
                    eprint("store error: cannot record acknowledgment: \(terminalSafe(String(describing: error)))")
                    throw ExitCode(6)
                }
            } else {
                eprint("blocked: unresolved mutating outcomes in session(s) \(namedSessions) — re-run with --acknowledge-unresolved-outcomes.")
                throw ExitCode(3)
            }
        }
        // 4. Backend (native when roots exist, else empty scripted).
        var nativeExecutor: NativeToolExecutor?
        if workspace != nil || !readRoot.isEmpty {
            let resolver: WorkspaceResolver
            do {
                resolver = try WorkspaceResolver(
                    workspace: workspace.map { FilePath($0) },
                    readRoots: readRoot.map { FilePath($0) })
            } catch {
                eprint("store error: cannot pin execution roots: \(terminalSafe(String(describing: error)))")
                throw ExitCode(6)
            }
            nativeExecutor = NativeToolExecutor(
                resolver: resolver, store: store,
                sessionID: state.sessionID, writer: runIdentity,
                rgPath: RunCommand.locateExecutable("rg"), gitPath: nil,
                execGrant: execComposed)
        }
        let executor: ChatExecutor
        if let native = nativeExecutor {
            executor = .native(native)
        } else {
            executor = .scripted(ScriptedToolBackend(script: [], caps: effective.tools))
        }
        // 5. Transport + raw display tap (display-only, bounded).
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton,
                                    configuration: ChatTransportPolicy.configuration(profile: profile))
        let messageProvider: @Sendable (ProviderInvocation) async throws -> [ChatMessage] = { invocation in
            if invocation.isCheckpoint {
                let full = try loadTranscript(from: store, session: state.sessionID, limit: 1024)
                return CheckpointValidator.captureOverlay(history: full, retryNote: invocation.checkpointRetryNote)
            }
            // First request happens after the first submit (the actor is
            // queue-driven), so the transcript is non-empty here; an
            // empty projection is a fail-closed transport error, never a
            // synthetic message.
            return try loadTranscriptProjection(from: store, session: state.sessionID, limit: 1024)
        }
        let credentialStore = EnvFileCredentialStore()
        let innerTransport = ChatCompletionsTransport(
            client: httpClient,
            messageProvider: messageProvider,
            credentialProvider: { ref, op in try credentialStore.resolve(ref, for: op) },
            snapshotProvider: { snapshot },
            advertisedTools: effective.tools,
            nativeExecComposed: execComposed)
        // 6. Terminal seams: owner, editor, tap box, loop.
        guard let lineEditor = LineEditorSession() else {
            eprint("chat error: cannot initialize the line editor")
            throw ExitCode(4)
        }
        let caps = TerminalCaps.fromEnvironment(
            ProcessInfo.processInfo.environment,
            isTTYStdout: isatty(STDOUT_FILENO) != 0,
            columns: TerminalCaps.resolveColumns(
                env: ProcessInfo.processInfo.environment, explicit: nil,
                ioctlWidth: TerminalCaps.ioctlColumns()))
        // Owner writer path: every byte is pre-sanitized (encoded spans
        // sanitize at the renderer; emitText/progress sanitize in the
        // owner), so direct `emit` satisfies the sanitized-input
        // contract. NUL never reaches the `strlen` emit path.
        let owner = TerminalOutputOwner(
            caps: caps, writer: { [lineEditor] text in lineEditor.emit(text) })
        let actorRef = ActorRef()
        let isSandbox = sandboxGrant != nil
        // The loop is created before the actor (the sink/presenter/tap
        // closures capture it; the actor is published via actorRef and
        // only touched after assignment — `run` starts last).
        let chatSink = ChatSink()
        // The loop is created after the closures that reference it;
        // the holder breaks the initialization cycle (closures only
        // fire after `run` starts, long after assignment).
        final class LoopHolder: @unchecked Sendable {
            var loop: ChatLoop?
        }
        let holder = LoopHolder()
        let tapBox = TapBox(
            onProgress: { req, n in holder.loop?.post(.tapProgress(req, n)) },
            onComplete: { req, rev, text in holder.loop?.post(.tapComplete(req, rev, text)) },
            onTruncated: { req, _ in holder.loop?.post(.tapTruncated(req)) })
        let transport = DeltaTapTransport(wrapping: innerTransport, box: tapBox)
        // Approval: sandbox grant ⇒ policy gateway (container only);
        // otherwise the interactive gateway (sole decision path — the
        // reducer grant/deny intents are never emitted by the bridge).
        let approvalsGateway: AnyApprovalGateway
        if let grantPath = sandboxGrant {
            approvalsGateway = AnyApprovalGateway(SandboxPolicyGateway(grantPath: grantPath))
        } else {
            approvalsGateway = AnyApprovalGateway(ReplxxApprovalGateway { req, box in
                holder.loop?.prepareConfirm(box: box)
                holder.loop?.post(.approvalArmed(req))
            })
        }
        // Trace tee: projections to the loop AND the JSONL trace file.
        let tee: (any UISink)
        if let tracePath = trace {
            guard FileManager.default.createFile(
                atPath: tracePath, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                eprint("cannot create trace file \(tracePath)")
                throw ExitCode(2)
            }
            guard let handle = FileHandle(forWritingAtPath: tracePath) else {
                eprint("cannot open trace file \(tracePath)")
                throw ExitCode(2)
            }
            let fileSink = FileHandleUISink(handle: handle, sessionID: state.sessionID.raw, ownsHandle: true)
            tee = TeeUISink(primary: chatSink, secondary: fileSink)
        } else {
            tee = chatSink
        }
        let identityResolver: (any ExecIdentityResolver)?
        if execComposed, let native = nativeExecutor {
            identityResolver = native
        } else {
            identityResolver = nil
        }
        let actor: ChatActor
        do {
            actor = try ChatActor(
                state: state, ids: DeterministicIDSource(prefix: "chat"), clock: SystemClock(),
                transport: transport, executor: executor, store: store,
                approvals: approvalsGateway, sink: tee, writer: writerID,
                execResolver: identityResolver)
        } catch {
            try? await httpClient.shutdown().get()
            throw error
        }
        actorRef.set(actor)
        if execComposed, nativeExecutor != nil {
            eprint("needletail: native exec composed (host execution is not OS-isolated; Linux-only execution path)")
        }
        // SIGINT → actor cancel (same as `run`); the input thread owns
        // Ctrl+C as a key (raw mode), this is the signal fallback.
#if canImport(Glibc)
        signal(SIGINT, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
#elseif canImport(Darwin)
        Darwin.signal(SIGINT, SIG_IGN)
        Darwin.signal(SIGPIPE, SIG_IGN)
#endif
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigintSource.setEventHandler {
            Task { @Sendable in
                await actorRef.get()?.cancel()
            }
        }
        sigintSource.resume()
        defer { sigintSource.cancel() }
        // 7. Loop: state snapshots + effect translation (the edge).
        let loop = ChatLoop(
            config: ChatLoop.Config(
                caps: caps,
                sessionID: state.sessionID.raw,
                snapshotProvider: {
                    guard let live = actorRef.get() else {
                        return QueueSyncSnapshot(entries: [], activeRequest: nil, queueHeld: false,
                                                 heldReason: nil, pendingApproval: nil,
                                                 admittedCommandIDs: [], liveEpoch: epoch.epochID)
                    }
                    return QueueSyncSnapshot.from(await live.currentState(), sandbox: isSandbox)
                },
                onEffects: { fx in
                    guard let live = holder.loop else { return }
                    await ChatCommand.translate(
                        fx, actorRef: actorRef, store: store, sessionID: state.sessionID,
                        workspace: workspace, readRoots: readRoot, isSandbox: isSandbox, loop: live)
                },
                mintCommandID: { CommandID(UUID().uuidString) }),
            lineEditor: lineEditor,
            owner: owner)
        holder.loop = loop
        chatSink.post = { event in holder.loop?.post(event) }
        await loop.run()
        // Safety-net tap drop (per-request state already finalizes at
        // invoke return; run_finished drops via projections).
        tapBox.dropAll()
        try? await httpClient.shutdown().get()
    }

    /// Edge translation: UIEffects → actor/store calls + loop feedback.
    /// Defensive: unreachable intents (grant/deny — the bridge never
    /// emits them) are ignored loudly via notice, never executed.
    static func translate(
        _ effects: [UIEffect],
        actorRef: ActorRef,
        store: GRDBSessionStore,
        sessionID: SessionID,
        workspace: String?,
        readRoots: [String],
        isSandbox: Bool,
        loop: ChatLoop
    ) async {
        for effect in effects {
            do {
                switch effect {
                case .submit(let input):
                    try await ChatCommand.withActor(actorRef) {
                        await $0.submitText(commandID: input.commandID, text: input.text, kind: .followUp, sealed: false)
                    }
                case .queue(let input, let kind):
                    try await ChatCommand.withActor(actorRef) {
                        await $0.submitText(commandID: input.commandID, text: input.text, kind: kind, sealed: false)
                    }
                case .queueEdit(let entryID, let newText, let baseRevision):
                    try await ChatCommand.withActor(actorRef) {
                        await $0.editEntry(entryID: entryID, newText: newText, baseRevision: baseRevision)
                    }
                case .queueWithdraw(let entryID):
                    try await ChatCommand.withActor(actorRef) {
                        await $0.withdrawEntry(entryID: entryID)
                    }
                case .queueResume:
                    try await ChatCommand.withActor(actorRef) { await $0.resumeQueue() }
                case .cancelCurrent:
                    try await ChatCommand.withActor(actorRef) { await $0.cancel() }
                case .queueReorder(let entryID, let beforeID):
                    try await ChatCommand.withActor(actorRef) {
                        await $0.reorderQueueEntry(entryID: entryID, beforeID: beforeID)
                    }
                case .requestLineageFork(let boundary):
                    try await ChatCommand.withActor(actorRef) {
                        await $0.requestLineageFork(boundary: boundary)
                    }
                case .previewFile(let path):
                    let text: String
                    do {
                        let data = try readBoundedFile(path, limit: 64 * 1024)
                        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                        if lines.count > 100 {
                            lines = Array(lines.prefix(100)) + ["…[preview truncated at 100 lines: \(path)]"]
                        }
                        text = ([path] + lines).joined(separator: "\n")
                    } catch {
                        text = "preview unavailable: \(path) (\(error))"
                    }
                    loop.post(.notice(text, .normal))
                case .requestCompletions(let query, let revision):
                    let candidates = ChatCommand.fetchCandidates(query: query, workspace: workspace, readRoots: readRoots)
                    loop.post(.completions(query: query, revision: revision, candidates: candidates))
                case .inspect(.queue):
                    if let actor = actorRef.get() {
                        // Sandbox display rule threads the SAME explicit
                        // flag as composition (never a type-test).
                        let ids = QueueSyncSnapshot.from(await actor.currentState(), sandbox: isSandbox).entries.map(\.entryID)
                        loop.post(.notice(ids.isEmpty ? "queue empty" : "queue:\n" + ids.joined(separator: "\n"), .normal))
                    }
                case .inspect(let command):
                    // PARTIAL (receipt): queue is live; the remaining
                    // inspect legs need edge read paths not yet wired in
                    // chat (M4-D). Never silent, never fabricated.
                    loop.post(.notice("inspect \(String(describing: command)) is not yet wired in chat", .warning))
                case .attachFile(let path, _):
                    // PARTIAL (receipt): fd-pinned capture needs the
                    // AttachmentCaptureService edge; tokens stay display.
                    loop.post(.notice("@\(path) noted (attach not yet wired in chat; text submits without files)", .warning))
                case .undoPreview(let groupID):
                    try await ChatCommand.undoPreview(groupID: groupID, actorRef: actorRef, store: store, sessionID: sessionID, loop: loop)
                case .runUndo(let groupID):
                    loop.post(.notice("undo run \(groupID): explicit runs stay headless in M4-C (preview only in chat)", .warning))
                case .decideApproval:
                    loop.post(.notice("internal: decideApproval is never produced by the interactive bridge", .errorNotice))
                }
            } catch {
                loop.post(.notice("edge error: \(terminalSafe(String(describing: error)))", .errorNotice))
            }
        }
    }

    private static func withActor(_ ref: ActorRef, _ body: (ChatActor) async throws -> Void) async throws {
        guard let actor = ref.get() else { throw ChatEdgeError.noActor }
        try await body(actor)
    }

    enum ChatEdgeError: Error {
        case noActor
    }

    /// Undo preview edge: reconcile the durable log, find the group,
    /// and ask the actor to preview (results surface as projections).
    static func undoPreview(groupID: String, actorRef: ActorRef, store: GRDBSessionStore, sessionID: SessionID, loop: ChatLoop) async throws {
        let (records, _) = try store.records(session: sessionID, since: 0, limit: 10_000)
        let groups = reconcileChangeGroups(records.map(\.record))
        guard let group = groups.first(where: { $0.groupID == groupID }) else {
            loop.post(.notice("undo: no reconciled group \(groupID) in this session", .warning))
            return
        }
        // Real preimage availability (same rule as the actor tests):
        // a member whose digest has no artifact record is unavailable.
        var preimages: [String: Bool] = [:]
        for member in group.members {
            if let digest = member.preimageDigest {
                preimages[digest] = (try? store.artifactRecord(session: sessionID, digest: digest)) != nil
            }
        }
        guard let actor = actorRef.get() else { throw ChatEdgeError.noActor }
        await actor.previewUndo(group: group, preimagesAvailable: preimages)
    }

    /// Bounded workspace candidate fetch for `@` completion (caller-
    /// confined roots only; the UI never opens these paths).
    /// Max 500 files walked, 10 candidates, 3 preview lines each.
    static func fetchCandidates(query: String, workspace: String?, readRoots: [String]) -> [CandidateFile] {
        let roots = ([workspace] + readRoots).compactMap { $0 }
        guard !roots.isEmpty else { return [] }
        let needle = query.lowercased()
        var out: [CandidateFile] = []
        var walked = 0
        for root in roots {
            guard out.count < maxCandidates else { break }
            let enumerator = FileManager.default.enumerator(atPath: root)
            while let relative = enumerator?.nextObject() as? String, walked < 500, out.count < maxCandidates {
                walked += 1
                let name = (relative as NSString).lastPathComponent.lowercased()
                guard name.hasPrefix(needle) || relative.lowercased().contains(needle) else { continue }
                let full = (root as NSString).appendingPathComponent(relative)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
                // Never follow symlinked files out of the pinned roots
                // (the resolver pins directories; a symlinked FILE inside
                // could otherwise point anywhere — skip, don't resolve).
                if (try? FileManager.default.attributesOfItem(atPath: full))?[.type] as? FileAttributeType == .typeSymbolicLink { continue }
                // Size-bound + text-only previews (never whole files).
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: full),
                      let size = attrs[.size] as? Int, size <= 64 * 1024 else { continue }
                let preview = (try? String(contentsOfFile: full, encoding: .utf8))?
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .prefix(3).map(String.init) ?? []
                out.append(CandidateFile(path: relative, previewLines: preview, previewTruncated: false))
            }
        }
        return out
    }
}

