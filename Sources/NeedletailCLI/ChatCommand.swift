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

    /// M4-D D2.6 budget backstop: pre-send `LiveRequestBudget.consume`
    /// around the inner transport. Identical mechanism to headless runs
    /// (same state-dir counter file, same fail-closed errors); the
    /// refusal message mirrors the headless wording so operators see
    /// one vocabulary. Covers every send path (including follow-up
    /// auto-dispatch, which bypasses submit-time checks); the submit-
    /// time refusal in the composition closure is the fast path, this
    /// is the backstop. NOT in Runtime/Core (frozen): composition-owned.
    ///
    /// Forwards `DeltaStreamingTransport` (the actor wires its delta
    /// delivery queue through a cast — an opaque wrapper would silently
    /// unwire streaming deltas to the sink/trace).
    struct BudgetEnforcingTransport<Inner: DeltaStreamingTransport>: DeltaStreamingTransport, Sendable {
        var inner: Inner
        let budget: LiveRequestBudget?

        var deltaSink: (@Sendable (String) -> Void)? {
            get { inner.deltaSink }
            set { inner.deltaSink = newValue }
        }

        func invoke(_ invocation: ProviderInvocation, intake: BoundedChannelState<ProviderResponse>) async throws -> TransportResult {
            if let budget {
                do {
                    _ = try budget.consume()
                } catch let error as LiveRequestBudget.BudgetError {
                    throw TransportFailure(phase: .preSend, message: "budget: live-request budget refuses to send (\(String(describing: error))); no provider byte sent")
                }
            }
            return try await inner.invoke(invocation, intake: intake)
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
        BudgetEnforcingTransport<DeltaTapTransport<ChatCompletionsTransport>>, ChatExecutor, GRDBSessionStore,
        AnyApprovalGateway, SystemClock, DeterministicIDSource
    >

    final class ActorRef: @unchecked Sendable {
        private let lock = NSLock()
        private var actor: ChatActor?
        func set(_ actor: ChatActor) { lock.withLock { self.actor = actor } }
        func get() -> ChatActor? { lock.withLock { actor } }
    }

    /// Shared composition root (M4-D D1.2 anti-skew invariant): BOTH the
    /// `chat` command and the composition tests call this factory. The
    /// test path reaches it with a temp config pointing at the loopback
    /// server plus an optional output-capture writer; every other
    /// element (config validation, gates, store, executor, transport,
    /// gateway, loop wiring) is identical by construction. Production
    /// always passes `writer: nil` (the real `lineEditor.emit` path,
    /// covered by the D3 PTY legs). Review must verify this factory is
    /// actually shared, not a parallel reimplementation.
    struct ComposedSession {
        let actor: ChatActor
        let loop: ChatLoop
        let owner: TerminalOutputOwner
        let lineEditor: LineEditorSession
        let transport: BudgetEnforcingTransport<DeltaTapTransport<ChatCompletionsTransport>>
        let tapBox: TapBox
        let httpClient: HTTPClient
        let store: GRDBSessionStore
        let runIdentity: WriterIdentity
        let sessionID: SessionID

        func cancel() async { await actor.cancel() }

        /// Live run (nil scripted input = real input thread) + cleanup.
        func run() async {
            await run(scriptedInput: nil)
        }

        /// Test/scripted run: deterministic input feed, same loop.
        func run(scriptedInput: [String?]?) async {
            await loop.run(scriptedInput: scriptedInput)
            // Safety-net tap drop (per-request state already finalizes
            // at invoke return; run_finished drops via projections).
            tapBox.dropAll()
            try? await httpClient.shutdown().get()
        }
    }

    /// Shared composition root (M4-D D1.2 anti-skew invariant): BOTH the
    /// `chat` command and the composition tests call this factory. The
    /// test path reaches it with a temp config pointing at the loopback
    /// server plus an optional output-capture writer; every other
    /// element (config validation, gates, store, executor, transport,
    /// gateway, loop wiring) is identical by construction. Production
    /// always passes `writer: nil` (the real `lineEditor.emit` path,
    /// covered by the D3 PTY legs). Review must verify this factory is
    /// actually shared, not a parallel reimplementation.
    static func compose(
        config: String?,
        trace: String?,
        alias: String?,
        maxTurns: Int?,
        allowExec: Bool,
        workspace: String?,
        readRoot: [String],
        sandboxGrant: String?,
        acknowledgedDetermination: String?,
        writer: (@Sendable (String) -> Void)? = nil
    ) async throws -> ComposedSession {
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
        // The resolver doubles as the attachment-capture root (M4-D
        // D2.1): same pinned roots, same confinement — capture never
        // opens a path execution cannot.
        var nativeExecutor: NativeToolExecutor?
        var captureResolver: WorkspaceResolver?
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
            captureResolver = resolver
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
        // contract. NUL never reaches the `strlen` emit path. Tests may
        // pass an explicit writer for output capture (production: nil).
        let emit: @Sendable (String) -> Void = writer ?? { [lineEditor] text in lineEditor.emit(text) }
        let owner = TerminalOutputOwner(caps: caps, writer: emit)
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
        // M4-D D2.1 attach: capture service over the same pinned
        // roots; the route grant mirrors the live profile (chat is never
        // sealed; a cloud locality holds attachments for explicit
        // re-consent at dispatch — qualified MENTION-12 semantics).
        let captureService = captureResolver.map { AttachmentCaptureService(resolver: $0) }
        let attachRouteGrant = AttachmentRouteGrant(alias: profile.alias, locality: profile.locality, sealed: false)
        // M4-D D2.6 budget: same state-dir counter file and limit
        // selection as headless runs (resolveStateDirectory +
        // "run-request-budget.json"). Nil when unset (unbounded with a
        // startup notice). Fail-closed like headless: an unreadable
        // counter refuses at the transport backstop, never silently.
        let liveBudget: LiveRequestBudget?
        if let limit = LiveRequestBudget.limit(checkpoint: false, environment: ProcessInfo.processInfo.environment) {
            let budgetDir = try RunCommand.resolveStateDirectory()
            try FileManager.default.createDirectory(
                atPath: budgetDir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            liveBudget = LiveRequestBudget(
                fileURL: URL(fileURLWithPath: (budgetDir as NSString).appendingPathComponent("run-request-budget.json")),
                limit: limit)
        } else {
            liveBudget = nil
        }
        let budgetedTransport = BudgetEnforcingTransport(inner: transport, budget: liveBudget)
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
                // M4-D D2 undo authority: the native validator + applier
                // over the pinned roots (nil without any roots — preview
                // and run then refuse fail-closed on missing evidence,
                // never mutate). Same seam the actor tests qualify.
            let undoValidator: (any UndoFileValidator)? = captureResolver.map { FilesystemUndoValidator(resolver: $0) }
            let inverseApplier: (any UndoInverseApplier)? = captureResolver.map {
                FilesystemUndoApplier(resolver: $0, store: store, session: state.sessionID, writer: runIdentity)
            }
            actor = try ChatActor(
                state: state, ids: DeterministicIDSource(prefix: "chat"), clock: SystemClock(),
                transport: budgetedTransport, executor: executor, store: store,
                approvals: approvalsGateway, sink: tee, writer: writerID,
                execResolver: identityResolver,
                undoValidator: undoValidator, inverseApplier: inverseApplier)
        } catch {
            try? await httpClient.shutdown().get()
            throw error
        }
        actorRef.set(actor)
        if execComposed, nativeExecutor != nil {
            eprint("needletail: native exec composed (host execution is not OS-isolated; Linux-only execution path)")
        }
        // Startup visibility (D2.6): the budget line renders once,
        // before any turn — visible at every decision point together
        // with the /queue display and the exhaustion notice.
        let startupNotices: [String]
        if let liveBudget {
            // Missing counter file means zero usage (same as headless);
            // inspect() nil with a SET limit must not print
            // "unbudgeted" (M4-D review: that label is for unset budgets).
            startupNotices = [budgetReportLine(used: liveBudget.inspect() ?? 0, limit: liveBudget.limit, tag: "chat")]
        } else {
            startupNotices = ["budget: unbounded (operator watches)"]
        }
        // M4-D D2.4 turn-finished tool-result display: transcript tool
        // messages since the last hook run render verbatim (the same
        // bytes the model sees — zero invention; the owner emit
        // sanitizes). Bounded: newest 10 per turn, 2 KiB each, with an
        // explicit truncation marker. Denial/unknown/failure outcomes
        // appear verbatim in the bodies; the status line already shows
        // the terminal phase. Identity-tracked (M4-D review C4): a
        // shorter tool list (checkpoint-shortened projection) never
        // re-renders old results; an over-limit transcript skips
        // silently (results were shown when fresh).
        final class SeenTools: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            var lastIdentity: String? = nil
        }
        let seenTools = SeenTools()
        let turnFinishedHook: @Sendable () async -> Void = {
            guard let live = holder.loop else { return }
            let transcript: [ChatMessage]
            do {
                transcript = try loadTranscriptProjection(from: store, session: state.sessionID, limit: 1024)
            } catch let error as TranscriptError where error == .pageOverflow(limit: 1024) {
                return
            } catch {
                live.post(.notice("tool results unreadable: \(terminalSafe(String(describing: error)))", .warning))
                return
            }
            let tools = transcript.filter { $0.role == .tool }
            let fresh: [ChatMessage] = seenTools.lock.withLock {
                let identityOf: (ChatMessage) -> String = { ($0.toolCallID ?? "") + "\n" + String($0.text.prefix(64)) }
                if let last = seenTools.lastIdentity,
                   let idx = tools.lastIndex(where: { identityOf($0) == last }) {
                    let from = min(idx + 1, tools.count)
                    seenTools.count = tools.count
                    if let newest = tools.last { seenTools.lastIdentity = identityOf(newest) }
                    return Array(tools[from...])
                }
                // No overlap (first run, or the projection shortened):
                // render nothing already seen, never re-render old rows.
                let from = min(seenTools.count, tools.count)
                seenTools.count = tools.count
                if let newest = tools.last { seenTools.lastIdentity = identityOf(newest) }
                if from >= tools.count { return [] }
                return Array(tools[from...])
            }
            guard !fresh.isEmpty else { return }
            for message in fresh.prefix(10) {
                var body = message.text
                if body.utf8.count > 2048 {
                    body = String(body.prefix(2048)) + "\n…[tool result truncated at 2 KiB]"
                }
                let id = message.toolCallID.map { " [\($0)]" } ?? ""
                live.post(.notice("tool result\(id):\n\(body)", .normal))
            }
            if fresh.count > 10 {
                live.post(.notice("…[\(fresh.count - 10) further tool results omitted this turn]", .warning))
            }
        }
        // 7. Loop: state snapshots + effect translation (the edge).
        let loop = ChatLoop(
            config: ChatLoop.Config(
                caps: caps,
                sessionID: state.sessionID.raw,
                startupNotices: startupNotices,
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
                    // One-shot attachments stashed pre-dispatch by the
                    // submit gate (M4-D D2 review C1).
                    let attachments = live.takePendingSubmitAttachments()
                    await ChatCommand.translate(
                        fx, actorRef: actorRef, store: store, sessionID: state.sessionID,
                        workspace: workspace, readRoots: readRoot, isSandbox: isSandbox,
                        budget: liveBudget, attachments: attachments, snapshot: snapshot, loop: live)
                },
                mintCommandID: { CommandID(UUID().uuidString) },
                onTurnFinished: turnFinishedHook,
                submitGate: { context in
                    // M4-D D2 review C1: budget + attach refusal BEFORE
                    // dispatch — the draft, tokens and queue survive a
                    // refusal, so the operator can fix and resubmit.
                    if budgetExhausted(liveBudget) {
                        return .refuse(message: "budget exhausted — submit refused, no provider traffic sent (fresh state dir resets the allowance)", tone: .warning)
                    }
                    if context.tokens.isEmpty { return .proceed(attachments: []) }
                    guard let service = captureService else {
                        return .refuse(message: "@-mentions need --workspace or --read-root for capture; submit withheld", tone: .warning)
                    }
                    do {
                        let snaps = try context.tokens.map { token in
                            try service.capture(
                                relativePath: token.path,
                                lineRange: token.lineRange.map { AttachmentLineRange(start: $0.lowerBound, end: $0.upperBound) },
                                intent: "mention", epochID: epoch.epochID, routeGrant: attachRouteGrant)
                        }
                        return .proceed(attachments: snaps)
                    } catch {
                        return .refuse(message: "attach refused: \(terminalSafe(String(describing: error))) — submit withheld", tone: .warning)
                    }
                }),
            lineEditor: lineEditor,
            owner: owner)
        holder.loop = loop
        chatSink.post = { event in holder.loop?.post(event) }
        return ComposedSession(
            actor: actor, loop: loop, owner: owner,
            lineEditor: lineEditor, transport: budgetedTransport, tapBox: tapBox,
            httpClient: httpClient, store: store,
            runIdentity: runIdentity, sessionID: state.sessionID)
    }

    private static func executeStatic(config: String?, trace: String?, alias: String?, maxTurns: Int?, allowExec: Bool, workspace: String?, readRoot: [String], sandboxGrant: String?, acknowledgedDetermination: String?) async throws {
        let session = try await compose(
            config: config, trace: trace, alias: alias,
            maxTurns: maxTurns, allowExec: allowExec,
            workspace: workspace, readRoot: readRoot,
            sandboxGrant: sandboxGrant,
            acknowledgedDetermination: acknowledgedDetermination,
            writer: nil)
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
                await session.cancel()
            }
        }
        sigintSource.resume()
        defer { sigintSource.cancel() }
        // Catchable exit paths (M4-D D3 PTY-07): SIGTERM/SIGHUP restore
        // the terminal and exit with a conventional code — default
        // disposition would die with raw termios engaged. The restore is
        // a pure termios syscall (safe while the input thread is blocked
        // in readLine); owned work is cancelled best-effort. SIGKILL has
        // NO in-process cleanup (documented; recovery is external).
        // NOTE: no signal(SIGTERM, SIG_IGN) here — GCD signal sources
        // require the DEFAULT disposition (a SIG_IGN signal is discarded
        // by the kernel before the source ever fires; the PTY-08 dumb
        // leg proved that exact failure).
        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        termSource.setEventHandler {
            Task { @Sendable in await session.cancel() }
            session.lineEditor.restoreSaneTermios()
            // _exit, never exit: the dumb-TERM leg runs replxx's
            // iostream line reader; a signal can interrupt it holding
            // the stream lock, and exit()'s atexit stdio flush would
            // deadlock on that lock (observed PTY-08). No flush is
            // needed — the store fsyncs its own writes.
#if canImport(Glibc)
            Glibc._exit(143)
#elseif canImport(Darwin)
            Darwin._exit(143)
#endif
        }
        termSource.resume()
        defer { termSource.cancel() }
        let hupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .global())
        hupSource.setEventHandler {
            Task { @Sendable in await session.cancel() }
            session.lineEditor.restoreSaneTermios()
#if canImport(Glibc)
            Glibc._exit(129)
#elseif canImport(Darwin)
            Darwin._exit(129)
#endif
        }
        hupSource.resume()
        defer { hupSource.cancel() }
        await session.run()
    }

    /// Edge translation: UIEffects → actor/store calls + loop feedback.
    /// Defensive: unreachable intents (grant/deny — the bridge never
    /// emits them) are ignored loudly via notice, never executed.
    /// M4-D D2.6: submit-time budget refusal (inspect, never consume —
    /// the transport backstop consumes pre-send). Refused submits never
    /// reach the actor; the queue stays held with an explicit notice.
    static func translate(
        _ effects: [UIEffect],
        actorRef: ActorRef,
        store: GRDBSessionStore,
        sessionID: SessionID,
        workspace: String?,
        readRoots: [String],
        isSandbox: Bool,
        budget: LiveRequestBudget?,
        attachments: [AttachmentSnapshot],
        snapshot: ConfigSnapshot,
        loop: ChatLoop
    ) async {
        for effect in effects {
            do {
                switch effect {
                case .submit(let input):
                    if attachments.isEmpty {
                        try await ChatCommand.withActor(actorRef) {
                            await $0.submitText(commandID: input.commandID, text: input.text, kind: .followUp, sealed: false)
                        }
                    } else {
                        try await ChatCommand.withActor(actorRef) {
                            await $0.submitTextWithAttachments(commandID: input.commandID, text: input.text, kind: .followUp, sealed: false, attachments: attachments)
                        }
                    }
                case .queue(let input, let kind):
                    if attachments.isEmpty {
                        try await ChatCommand.withActor(actorRef) {
                            await $0.submitText(commandID: input.commandID, text: input.text, kind: kind, sealed: false)
                        }
                    } else {
                        try await ChatCommand.withActor(actorRef) {
                            await $0.submitTextWithAttachments(commandID: input.commandID, text: input.text, kind: kind, sealed: false, attachments: attachments)
                        }
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
                    // Record-only fork (B4): no file mutation. The
                    // divergence warning is explicit and unconditional —
                    // worktree dirtiness is NOT auto-detected, so the
                    // operator verifies with `/diff` (stated, not implied).
                    loop.post(.notice("rewind fork recorded at \(boundary.epochID.raw)#\(boundary.throughSequence); worktree untouched — verify divergence with /diff", .warning))
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
                case .inspect(.filePreview(let path)):
                    // Spec §2.2 keyboard/dumb-terminal fallback: bounded
                    // local file text (shares the previewFile read path).
                    // Workspace/read-root confinement: refuse absolute or
                    // escaping paths (the resolver owns roots; this edge
                    // never opens arbitrary paths).
                    loop.post(.notice(ChatCommand.boundedPreview(path: path, workspace: workspace, readRoots: readRoots), .normal))
                case .inspect(.models):
                    // Complete from the validated config snapshot (no
                    // network request just to list — UX-NAV-03).
                    let routes = snapshot.profiles.values
                        .sorted(by: { $0.alias < $1.alias })
                        .map { UIModelRoute(alias: $0.alias, locality: $0.locality.rawValue, kind: $0.locality == .local ? .local : .cloud, models: [$0.modelID]) }
                    loop.post(.inspection(.models(routes: routes)))
                case .inspect(.sessions):
                    try await ChatCommand.inspectSessions(actorRef: actorRef, store: store, sessionID: sessionID, loop: loop)
                case .inspect(.agents):
                    if let actor = actorRef.get() {
                        let st = await actor.currentState()
                        // The edge reports the live session as the agent
                        // row; consult children surface through phase only
                        // (Core tracks no consult roster — NAV-02 bounded
                        // consult stays pure-qualified).
                        loop.post(.inspection(.agents(rows: [UIAgentRow(alias: st.sessionID.raw, phase: "\(st.phase)", childActivity: nil)])))
                    }
                case .inspect(.context):
                    try ChatCommand.inspectContext(store: store, sessionID: sessionID, loop: loop)
                case .inspect(.epochs):
                    try ChatCommand.inspectEpochs(store: store, sessionID: sessionID, loop: loop)
                case .inspect(.compactDryRun):
                    try ChatCommand.inspectCompact(store: store, sessionID: sessionID, loop: loop)
                case .inspect(.diff):
                    ChatCommand.inspectDiff(workspace: workspace, loop: loop)
                case .inspect(.queue):
                    if let actor = actorRef.get() {
                        // Sandbox display rule threads the SAME explicit
                        // flag as composition (never a type-test).
                        let ids = QueueSyncSnapshot.from(await actor.currentState(), sandbox: isSandbox).entries.map(\.entryID)
                        let budgetLine = budget.map { budgetReportLine(used: $0.inspect() ?? 0, limit: $0.limit, tag: "chat") }
                            ?? budgetReportLine(used: nil, limit: nil, tag: "chat")
                        loop.post(.notice((ids.isEmpty ? "queue empty" : "queue:\n" + ids.joined(separator: "\n")) + "\n" + budgetLine, .normal))
                    }
                case .inspect(.undoPreview(let groupID)):
                    // Same preview path as the `/undo <group>` intent.
                    try await ChatCommand.undoPreview(groupID: groupID, actorRef: actorRef, store: store, sessionID: sessionID, loop: loop)
                case .inspect(let command):
                    // Remaining legs: rewind inspection has no emitter in
                    // the slash vocabulary (the fork path posts its own
                    // warning — see requestLineageFork). Never silent,
                    // never fabricated.
                    loop.post(.notice("inspect \(String(describing: command)) is not yet wired in chat", .warning))
                case .attachFile(let path, _):
                    // Defensive: submit-time tokens are captured via
                    // AttachmentCaptureService (M4-D D2.1); a standalone
                    // attach intent reaching the edge is acknowledged,
                    // never executed (no path is opened here).
                    loop.post(.notice("@\(path) noted (attach resolves at submit via the draft tokens)", .warning))
                case .undoPreview(let groupID):
                    try await ChatCommand.undoPreview(groupID: groupID, actorRef: actorRef, store: store, sessionID: sessionID, loop: loop)
                case .undoPreviewLatest:
                    try await ChatCommand.undoPreviewLatest(actorRef: actorRef, store: store, sessionID: sessionID, loop: loop)
                case .runUndo(let groupID):
                    try await ChatCommand.runUndo(groupID: groupID, actorRef: actorRef, store: store, sessionID: sessionID, loop: loop)
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

    /// M4-D D2.6 submit-time refusal probe (inspect only — never
    /// consumes a unit). Nil budget (unset) is never exhausted. A
    /// missing counter file means zero usage (same as headless);
    /// corrupt/unreadable counters are refused at the transport
    /// backstop with an explicit error, never silently sent.
    /// Consumed by the submit-gate closure (pre-dispatch).
    static func budgetExhausted(_ budget: LiveRequestBudget?) -> Bool {
        guard let budget else { return false }
        let used = budget.inspect() ?? 0
        return used >= budget.limit
    }

    enum ChatEdgeError: Error {
        case noActor
    }

    /// Undo preview edge: reconcile the durable log, find the group,
    /// and ask the actor to preview (results surface as projections).
    /// A successful resolve records the preview (the run path requires
    /// it — read before mutate).
    static func undoPreview(groupID: String, actorRef: ActorRef, store: GRDBSessionStore, sessionID: SessionID, loop: ChatLoop) async throws {
        guard let (group, preimages) = try ChatCommand.resolveUndoGroup(groupID: groupID, store: store, sessionID: sessionID, loop: loop) else { return }
        loop.noteUndoPreviewed(group.groupID)
        guard let actor = actorRef.get() else { throw ChatEdgeError.noActor }
        await actor.previewUndo(group: group, preimagesAvailable: preimages)
    }

    /// Bare-`/undo` latest-eligible preview (M4-D D2, read-only): the
    /// newest group whose every preimage is available. Runs still need
    /// an explicit group ID — latest-eligible never executes.
    static func undoPreviewLatest(actorRef: ActorRef, store: GRDBSessionStore, sessionID: SessionID, loop: ChatLoop) async throws {
        guard let (group, preimages) = try ChatCommand.resolveUndoGroup(groupID: nil, store: store, sessionID: sessionID, loop: loop) else { return }
        loop.noteUndoPreviewed(group.groupID)
        guard let actor = actorRef.get() else { throw ChatEdgeError.noActor }
        await actor.previewUndo(group: group, preimagesAvailable: preimages)
    }

    /// Explicit undo execution (M4-D D2): Core approval + verification
    /// via `actor.runUndo`. Requires a prior preview of the SAME group
    /// (the plan's preview-then-execute; the verb is the confirmation).
    /// Idempotency note (corrected M4-D review): each call mints a FRESH
    /// undo command ID — safety across calls comes from Core postimage
    /// validation + recorded dispositions (a retry of the SAME command
    /// ID reuses its disposition; distinct calls are distinct commands,
    /// each validated).
    static func runUndo(groupID: String, actorRef: ActorRef, store: GRDBSessionStore, sessionID: SessionID, loop: ChatLoop) async throws {
        guard !groupID.isEmpty else {
            loop.post(.notice("usage: /undo run <group> (runs need an explicit group)", .warning))
            return
        }
        guard loop.didPreviewUndo(groupID) else {
            loop.post(.notice("preview group \(groupID) first (`/undo \(groupID)` or `/undo`) — runs need a prior preview", .warning))
            return
        }
        guard let (group, preimages) = try ChatCommand.resolveUndoGroup(groupID: groupID, store: store, sessionID: sessionID, loop: loop) else { return }
        guard let actor = actorRef.get() else { throw ChatEdgeError.noActor }
        let commandID = await actor.runUndo(group: group, preimagesAvailable: preimages)
        loop.post(.notice("undo run \(commandID) dispatched for group \(groupID); disposition renders when recorded", .normal))
    }

    /// Shared group resolution: reconcile the durable log (first 10,000
    /// session records — same documented bound as the preview edge),
    /// find the named group or the latest fully-reconciled one, and
    /// compute real preimage availability (same rule as the actor
    /// tests: a member whose digest has no artifact record is
    /// unavailable). Nil (after an explicit notice) when there is
    /// nothing eligible — never a guess, never a silent skip.
    static func resolveUndoGroup(groupID: String?, store: GRDBSessionStore, sessionID: SessionID, loop: ChatLoop) throws -> (ChangeGroup, [String: Bool])? {
        let (records, _) = try store.records(session: sessionID, since: 0, limit: 10_000)
        let groups = reconcileChangeGroups(records.map(\.record))
        guard !groups.isEmpty else {
            loop.post(.notice("undo: no change groups in this session", .warning))
            return nil
        }
        let target: ChangeGroup?
        if let groupID, !groupID.isEmpty {
            target = groups.first(where: { $0.groupID == groupID })
            if target == nil {
                loop.post(.notice("undo: no reconciled group \(groupID) in this session", .warning))
                return nil
            }
        } else {
            // Latest eligible: newest group whose every preimage is
            // available. Partial groups are previewable by name, never
            // auto-picked.
            target = groups.reversed().first(where: { group in
                group.members.allSatisfy { member in
                    guard let digest = member.preimageDigest else { return true }
                    return (try? store.artifactRecord(session: sessionID, digest: digest)) != nil
                }
            })
            if target == nil {
                loop.post(.notice("undo: no fully-reconciled group; name one explicitly (`/undo <group>`) for a partial preview", .warning))
                return nil
            }
        }
        let group = target!
        var preimages: [String: Bool] = [:]
        for member in group.members {
            if let digest = member.preimageDigest {
                preimages[digest] = (try? store.artifactRecord(session: sessionID, digest: digest)) != nil
            }
        }
        return (group, preimages)
    }

    /// `/sessions` (M4-D D2, UX-NAV): the live session renders fully
    /// from actor state; other sessions show their epoch route (first
    /// records) with explicitly unknown activity (NAV honesty: unknown
    /// labeled unknown, never zero-filled). Capped at 20 rows.
    static func inspectSessions(actorRef: ActorRef, store: GRDBSessionStore, sessionID: SessionID, loop: ChatLoop) async throws {
        var rows: [UISessionRow] = []
        if let actor = actorRef.get() {
            let st = await actor.currentState()
            rows.append(UISessionRow(
                sessionID: sessionID, phase: "\(st.phase)",
                lastActivityMillis: SystemClock().nowMillis(),
                routeAlias: st.epoch.profile.alias, locality: st.epoch.profile.locality.rawValue,
                modelAlias: st.epoch.profile.modelID, isLive: true))
        }
        let ids = (try store.sessions()).filter { $0 != sessionID }.prefix(20)
        for sid in ids {
            // First two records carry sessionOpened + epochOpened when
            // the session started normally (same append order as the
            // chat composition root).
            let (prefix, _) = try store.records(session: sid, since: 0, limit: 2)
            var route = "unknown"
            var locality = "unknown"
            var model = "unknown"
            for sequenced in prefix {
                if case .epochOpened(let epoch) = sequenced.record {
                    route = epoch.profile.alias
                    locality = epoch.profile.locality.rawValue
                    model = epoch.profile.modelID
                }
            }
            rows.append(UISessionRow(
                sessionID: sid, phase: "unknown", lastActivityMillis: nil,
                routeAlias: route, locality: locality, modelAlias: model, isLive: false))
        }
        loop.post(.inspection(.sessions(rows: rows, asOfMillis: SystemClock().nowMillis())))
    }

    /// `/context` (M4-D D2, UX-NAV-04): receipts counted from transcript
    /// tool messages (actual); token totals estimated (provider usage is
    /// not persisted — never present exact numbers); cache always
    /// unknown (no profile cache stats — UNKNOWN is the finding).
    static func inspectContext(store: GRDBSessionStore, sessionID: SessionID, loop: ChatLoop) throws {
        let transcript = try loadTranscriptProjection(from: store, session: sessionID, limit: 1024)
        let receipts = transcript.filter { $0.role == .tool }.count
        loop.post(.inspection(.context(usage: UIContextUsage(
            inputTokens: nil, estimated: true, cacheHits: nil,
            cacheUnknown: true, receipts: UInt64(receipts), unverifiedClaims: 0))))
    }

    /// `/epochs` (M4-D D2, UX-NAV-06): epoch lineage from the durable
    /// log (first 10,000 records — same documented bound as undo);
    /// checkpoint state joined from checkpointCommitted records.
    static func inspectEpochs(store: GRDBSessionStore, sessionID: SessionID, loop: ChatLoop) throws {
        let (records, _) = try store.records(session: sessionID, since: 0, limit: 10_000)
        var committed: Set<String> = []
        for sequenced in records {
            if case .checkpointCommitted(let epoch) = sequenced.record {
                committed.insert(epoch.epochID.raw)
            }
        }
        var seen: Set<String> = []
        var rows: [UIEpochRow] = []
        for sequenced in records {
            guard case .epochOpened(let epoch) = sequenced.record else { continue }
            guard seen.insert(epoch.epochID.raw).inserted else { continue }
            rows.append(UIEpochRow(
                epochID: epoch.epochID.raw,
                parentID: epoch.parentEpochID?.raw,
                checkpoint: committed.contains(epoch.epochID.raw) ? .success(costMillis: 0) : .none,
                prefill: nil))
            if rows.count >= 64 { break }
        }
        loop.post(.inspection(.epochs(rows: rows)))
    }

    /// `/compact --dry-run` (M4-D D2, UX-NAV-05): offline token estimate
    /// from transcript bytes (heuristic ÷4, stated); no provider call,
    /// no epoch replacement. The trigger remains an explicit non-case
    /// deferral (no qualified authority).
    static func inspectCompact(store: GRDBSessionStore, sessionID: SessionID, loop: ChatLoop) throws {
        let transcript = try loadTranscriptProjection(from: store, session: sessionID, limit: 1024)
        let bytes = transcript.reduce(0) { $0 + $1.text.utf8.count }
        loop.post(.inspection(.compact(preview: UICompactPreview(
            estimatedTokens: UInt64(bytes / 4), wouldReplaceEpoch: false,
            note: "heuristic estimate (bytes/4); dry-run only, 0 provider calls; compact trigger not implemented"))))
    }

    /// `/diff` (M4-D D2, UX-NAV-07): bounded `git diff` hunks in the
    /// workspace via the qualified GitDiff runner. Provenance is always
    /// mixed (git cannot attribute authorship — no claim of exclusive
    /// authorship, per spec). No workspace ⇒ explicit notice.
    static func inspectDiff(workspace: String?, loop: ChatLoop) {
        guard let workspace else {
            loop.post(.notice("diff unavailable: no workspace pinned", .warning))
            return
        }
        let gitPath: String?
        do {
            gitPath = try DiffCommand.resolveGit(explicit: nil)
        } catch {
            loop.post(.notice("diff unavailable: git not resolved (\(terminalSafe(String(describing: error))))", .warning))
            return
        }
        let out: GitDiff.Output
        do {
            out = try GitDiff.run(workspace: URL(fileURLWithPath: workspace), gitPath: gitPath)
        } catch let failure as GitDiff.Failure {
            loop.post(.notice("diff failed: \(terminalSafe(String(describing: failure)))", .warning))
            return
        } catch {
            loop.post(.notice("diff failed: \(terminalSafe(String(describing: error)))", .warning))
            return
        }
        let text = String(decoding: out.stdout, as: UTF8.self)
        loop.post(.inspection(.diff(files: ChatCommand.parseUnifiedDiff(text: text))))
    }

    /// Minimal unified-diff parse (edge-owned; the renderer only
    /// displays): `diff --git` file headers + `@@` hunks, bounded
    /// (20 files, 50 hunks each — the frame bounds the rest).
    static func parseUnifiedDiff(text: String) -> [UIDiffFile] {
        var files: [UIDiffFile] = []
        var currentPath: String? = nil
        var currentHunks: [String] = []
        var currentBody: [String] = []
        func flush() {
            guard let path = currentPath else { return }
            var hunks = currentHunks
            if !currentBody.isEmpty { hunks.append(currentBody.joined(separator: "\n")) }
            files.append(UIDiffFile(path: path, provenance: .mixed, hunks: Array(hunks.prefix(50))))
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("diff --git ") {
                flush()
                guard files.count < 20 else { currentPath = nil; currentHunks = []; currentBody = []; continue }
                let parts = line.split(separator: " ")
                if let bpart = parts.last, bpart.hasPrefix("b/") {
                    currentPath = String(bpart.dropFirst(2))
                } else {
                    currentPath = String(parts.last ?? "?")
                }
                currentHunks = []
                currentBody = []
            } else if line.hasPrefix("@@ ") {
                if !currentBody.isEmpty { currentHunks.append(currentBody.joined(separator: "\n")); currentBody = [] }
                currentHunks.append(line)
            } else if currentPath != nil {
                currentBody.append(line)
            }
        }
        flush()
        return files
    }
    /// Bounded file preview with root confinement (used by `/preview`):
    /// absolute paths, `..` segments, and symlinks escaping the pinned
    /// roots are refused (M4-D review C5: an intermediate symlinked dir
    /// under a root must not escape — the path is normalized through
    /// `resolvingSymlinksInPath` and re-checked for containment).
    /// Reads cap at 64 KiB / 100 lines. Residual TOCTOU races (a link
    /// swapped between check and read) are accepted for this read-only
    /// bounded preview; the fd-pinned resolver owns all writes.
    static func boundedPreview(path: String, workspace: String?, readRoots: [String]) -> String {
        let roots = ([workspace] + readRoots).compactMap { $0 }
        let standardized = (path as NSString).standardizingPath
        guard !standardized.hasPrefix("/"), !standardized.contains("..") else {
            return "preview refused: path escapes the pinned roots: \(path)"
        }
        guard !roots.isEmpty else {
            return "preview unavailable: no workspace or read-root pinned"
        }
        // Resolve against the first root containing the path (symlinked
        // files skipped by the same rule as completion fetch), then
        // normalize symlinks and re-check containment.
        var resolved: String? = nil
        for root in roots {
            let full = (root as NSString).appendingPathComponent(standardized)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
            if (try? FileManager.default.attributesOfItem(atPath: full))?[.type] as? FileAttributeType == .typeSymbolicLink { continue }
            resolved = full
            break
        }
        guard let full = resolved else {
            return "preview unavailable: \(path) (not found under pinned roots)"
        }
        let normalized = URL(fileURLWithPath: full).resolvingSymlinksInPath().path
        let contained = roots.contains { root in
            let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
            let prefix = base.hasSuffix("/") ? base : base + "/"
            return normalized == base || normalized.hasPrefix(prefix)
        }
        guard contained else {
            return "preview refused: path escapes the pinned roots: \(path)"
        }
        do {
            let data = try readBoundedFile(full, limit: 64 * 1024)
            var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.count > 100 {
                lines = Array(lines.prefix(100)) + ["…[preview truncated at 100 lines: \(path)]"]
            }
            return ([path] + lines).joined(separator: "\n")
        } catch {
            return "preview unavailable: \(path) (\(error))"
        }
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

