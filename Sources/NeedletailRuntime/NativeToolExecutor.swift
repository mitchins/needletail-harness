import Foundation
import SystemPackage
import NeedletailCore
import Crypto
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// B1 NativeToolExecutor: descriptor-relative via WorkspaceResolver, strict validation pre-side-effect,
/// protected-path enforcement, and per-mutating-batch nonblocking lock.
public struct NativeToolExecutor: ToolExecutor, Sendable {
    public let resolver: WorkspaceResolver
    public let store: any SessionStore
    public let sessionID: SessionID
    public let writer: WriterIdentity
    public let rgPath: String?
    public let gitPath: String?

    public init(resolver: WorkspaceResolver, store: any SessionStore, sessionID: SessionID, writer: WriterIdentity, rgPath: String? = nil, gitPath: String? = nil) {
        self.resolver = resolver
        self.store = store
        self.sessionID = sessionID
        self.writer = writer
        self.rgPath = rgPath
        self.gitPath = gitPath
    }

    public func describe(batch: ToolBatch) -> String {
        // Use validated paths for description if possible, else tool names
        do {
            let validated = try ToolValidator.validateBatchArguments(batch: batch)
            return validated.map { "\($0.tool):\($0.callID):\($0.paths.joined(separator: ","))" }.joined(separator: ", ")
        } catch {
            return batch.proposals.map { "\($0.tool):\($0.callID)" }.joined(separator: ", ")
        }
    }

    public func execute(batch: ToolBatch, reservation: EffectReservation) async throws -> ExecutorResult {
        // Strict validation before any side effect
        do {
            _ = try ToolValidator.validateBatchArguments(batch: batch)
        } catch let ToolFailure.preDispatch(status, summary) {
            var outcomes: [ToolCallOutcome] = []
            for p in batch.proposals {
                let isMut = p.tool != "read" && p.tool != "search" && p.tool != "consult"
                // For preDispatch, even mutating is done with no side effect, so started false
                outcomes.append(ToolCallOutcome(callID: p.callID, status: status, summary: summary, data: "", error: summary, started: false))
            }
            let receipt = ExecutorReceipt(callID: batch.proposals.first?.callID ?? "batch", status: status, summary: summary)
            return ExecutorResult(receipt: receipt, calls: outcomes)
        } catch {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "\(error)")
        }

        var outcomes: [ToolCallOutcome] = []
        var halted = false
        var haltAfter: String? = nil
        var lockFD: Int32? = nil
        defer {
            if let fd = lockFD {
                WorkspaceLock.release(fd)
            }
        }
        let hasMutating = batch.proposals.contains { $0.tool != "read" && $0.tool != "search" && $0.tool != "consult" }

        for proposal in batch.proposals {
            if halted {
                let summary = "unstarted: halted after \(haltAfter ?? "unknown")"
                outcomes.append(ToolCallOutcome(callID: proposal.callID, status: "cancelled", summary: summary, data: "", started: false))
                continue
            }
            // Acquire lock once, before first mutating call, after validation
            let isMutating = proposal.tool != "read" && proposal.tool != "search" && proposal.tool != "consult"
            if isMutating && hasMutating && lockFD == nil {
                if let ws = resolver.workspaceRoot {
                    do {
                        lockFD = try WorkspaceLock.acquire(workspace: ws)
                    } catch {
                        let summary = "workspace lock failed: \(error)"
                        outcomes.append(ToolCallOutcome(callID: proposal.callID, status: "failed", summary: summary, data: "", error: summary, started: false))
                        halted = true
                        haltAfter = proposal.callID
                        continue
                    }
                } else {
                    outcomes.append(ToolCallOutcome(callID: proposal.callID, status: "denied", summary: "no workspace", data: "", error: "no workspace", started: false))
                    halted = true
                    haltAfter = proposal.callID
                    continue
                }
            }
            let outcome: ToolCallOutcome
            do {
                outcome = try executeOne(proposal: proposal, reservation: reservation)
            } catch is CancellationError {
                throw CancellationError()
            } catch let ToolFailure.preDispatch(status, summary) {
                outcome = ToolCallOutcome(callID: proposal.callID, status: status, summary: summary, data: "", error: summary, started: false)
            } catch {
                outcome = ToolCallOutcome(callID: proposal.callID, status: "failed", summary: "\(error)", data: "", error: "\(error)", started: true)
            }
            outcomes.append(outcome)
            if outcome.status != "success" && outcome.status != "no-match" {
                halted = true
                haltAfter = proposal.callID
            }
        }
        let receipt = ExecutorReceipt(callID: batch.proposals.first?.callID ?? "batch", status: outcomes.first?.status ?? "failed", summary: outcomes.map { "\($0.callID):\($0.status)" }.joined(separator: ", "))
        return ExecutorResult(receipt: receipt, calls: outcomes)
    }

    private func executeOne(proposal: ToolProposal, reservation: EffectReservation) throws -> ToolCallOutcome {
        guard let argsStr = proposal.arguments, let data = argsStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "invalid json")
        }
        // Check protected paths before any FS touch; grantable requires explicit approval in reservation
        if let path = json["path"] as? String {
            let cls = ToolValidator.protectedClassification(for: path)
            if cls == .absoluteDenied {
                throw ToolFailure.preDispatch(status: "denied", summary: "absolute protected path")
            }
            if cls == .grantable && !ToolValidator.isApprovedPath(path, approvedPaths: reservation.approvedPaths) {
                throw ToolFailure.preDispatch(status: "denied", summary: "grantable protected path requires approval")
            }
        }
        switch proposal.tool {
        case "read":
            return try read(callID: proposal.callID, json: json)
        case "search":
            return try search(callID: proposal.callID, json: json, reservation: reservation)
        case "edit":
            return try edit(callID: proposal.callID, json: json)
        case "write":
            return try write(callID: proposal.callID, json: json)
        default:
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "unknown tool")
        }
    }

    // B2 closure: read fidelity budgets. File bytes capped at 32 MiB+1 (growth
    // after fstat cannot cause unbounded reads); returned text capped at a
    // 1 MiB result-byte budget independent of line counts, cut at line
    // boundaries so returned bytes are always an exact prefix/slice of the
    // file (terminal newlines preserved). SHA-256 is over the full bytes
    // read; truncated is true iff limit/offset or the byte budget omitted
    // trailing content.
    static let maxReadFileBytes: Int64 = 32 * 1024 * 1024
    static let maxResultBytes = 1 * 1024 * 1024
    static let maxSearchStdoutBytes = 1 * 1024 * 1024
    static let maxSearchStderrBytes = 64 * 1024
    static let searchTimeoutSeconds: TimeInterval = 30
    static let versionTimeoutSeconds: TimeInterval = 10

    /// Slice text into exact bytes: lines [offset, offset+limit), preserving a
    /// terminal newline iff the slice reaches the original EOF newline or is
    /// cut mid-file at a line boundary. Enforces maxResultBytes at line
    /// boundaries. Returns (slice, truncated).
    static func sliceTextExact(_ text: String, limit: Int, offset: Int) -> (String, Bool) {
        var effective = text.split(separator: "\n", omittingEmptySubsequences: false)
        let hadTrailing = text.hasSuffix("\n")
        if hadTrailing && !effective.isEmpty && effective.last == "" {
            effective.removeLast()
        }
        let count = effective.count
        let start = min(offset, count)
        let end = min(start + limit, count)
        var truncated = end < count
        let slice = Array(effective[start..<end])
        var limited: String
        if slice.isEmpty {
            limited = ""
        } else {
            limited = slice.joined(separator: "\n")
            if end < count || hadTrailing {
                limited += "\n"
            }
        }
        if limited.utf8.count > maxResultBytes {
            // Charge each kept line exactly what it costs in the output: a
            // trailing "\n" except for a final unterminated file line, so a
            // line that exactly fits is never dropped on a phantom newline.
            let lastKeepsNewline = (end < count) || hadTrailing
            var acc = 0
            var keep = 0
            for (i, line) in slice.enumerated() {
                let isLast = i == slice.count - 1
                let lb = line.utf8.count + ((isLast && !lastKeepsNewline) ? 0 : 1)
                if acc + lb > maxResultBytes { break }
                acc += lb
                keep += 1
            }
            if keep < slice.count {
                let kept = slice[0..<keep].joined(separator: "\n") + (keep > 0 ? "\n" : "")
                limited = kept
                truncated = true
            }
        }
        return (limited, truncated)
    }

    private func read(callID: String, json: [String: Any]) throws -> ToolCallOutcome {
        // Handle artifact ID read (session-scoped) with bounded output, SHA, binary check
        if let artifactId = (json["artifactId"] as? String) ?? (json["artifact_id"] as? String) {
            do {
                if let data = try store.artifactRecord(session: sessionID, digest: artifactId) {
                    if data.contains(0) {
                        return ToolCallOutcome(callID: callID, status: "failed", summary: "binary artifact", data: "", error: "binary", started: true)
                    }
                    guard let text = String(data: data, encoding: .utf8) else {
                        return ToolCallOutcome(callID: callID, status: "failed", summary: "binary artifact", data: "", error: "binary", started: true)
                    }
                    let limit = json["limit"] as? Int ?? 200
                    let offset = json["offset"] as? Int ?? 0
                    let (limited, truncated) = Self.sliceTextExact(text, limit: limit, offset: offset)
                    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    return ToolCallOutcome(callID: callID, status: "success", summary: "read artifact \(artifactId)", data: limited, truncated: truncated, path: artifactId, beforeHash: hash, started: true)
                }
            } catch {}
            return ToolCallOutcome(callID: callID, status: "denied", summary: "artifact not found or foreign", data: "", error: "artifact denied", started: false)
        }
        let path = json["path"] as? String ?? ""
        var fd: Int32? = nil
        var lastError: Error? = nil
        if let ws = resolver.workspaceRoot {
            do {
                let dirFD = try resolver.validatedWorkspaceFD()
                defer { close(dirFD) }
                fd = try resolver.openRelative(path, from: dirFD, flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            } catch {
                lastError = error
            }
        }
        if fd == nil {
            for rr in resolver.readRoots {
                do {
                    let dirFD = try resolver.revalidatedFD(for: rr)
                    defer { close(dirFD) }
                    fd = try resolver.openRelative(path, from: dirFD, flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    break
                } catch {
                    if let se = error as? StoreError, case .integrity(let msg) = se, msg.contains("is directory") {
                        lastError = error
                        break
                    }
                    lastError = error
                    continue
                }
            }
        }
        guard let readFD = fd else {
            if let err = lastError as? StoreError, case .integrity(let msg) = err, msg.contains("is directory") {
                return ToolCallOutcome(callID: callID, status: "failed", summary: "is directory", data: "", error: "is directory", started: true)
            }
            let msg = "\(lastError ?? StoreError.integrity("no workspace/read-root"))"
            if msg.contains("No such") || msg.contains("not found") {
                return ToolCallOutcome(callID: callID, status: "no-match", summary: "not found", data: "", started: true)
            }
            throw lastError ?? ToolFailure.preDispatch(status: "denied", summary: "no workspace/read-root")
        }
        defer { close(readFD) }
        var st = stat()
        guard fstat(readFD, &st) == 0 else {
            return ToolCallOutcome(callID: callID, status: "failed", summary: "fstat failed", data: "", error: "fstat", started: true)
        }
        if Int64(st.st_size) > 32*1024*1024 {
            return ToolCallOutcome(callID: callID, status: "failed", summary: "over size limit", data: "", error: "too large", started: true)
        }
        // Read via fd, bounded: st_size gate above is racy (file may grow after
        // fstat), so the loop itself fails closed past exactly maxReadFileBytes
        // instead of buffering unboundedly.
        var data = Data()
        let readCap = Int(Self.maxReadFileBytes)
        if st.st_size >= 0 && st.st_size < 8 * 1024 * 1024 {
            data.reserveCapacity(Int(st.st_size) + 1)
        }
        var buf = [UInt8](repeating: 0, count: 8192)
        var total = 0
        while true {
            let n = buf.withUnsafeMutableBytes { ptr in
                Glibc.read(readFD, ptr.baseAddress, ptr.count)
            }
            if n < 0 {
                if errno == EINTR { continue }
                return ToolCallOutcome(callID: callID, status: "failed", summary: "read failed", data: "", error: String(cString: strerror(errno)), started: true)
            }
            if n == 0 { break }
            total += n
            if total > readCap {
                return ToolCallOutcome(callID: callID, status: "failed", summary: "over size limit", data: "", error: "too large", started: true)
            }
            data.append(contentsOf: buf[0..<n])
        }
        if data.contains(0) {
            return ToolCallOutcome(callID: callID, status: "failed", summary: "binary", data: "", error: "binary", started: true)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return ToolCallOutcome(callID: callID, status: "failed", summary: "binary", data: "", error: "binary", started: true)
        }
        let limit = json["limit"] as? Int ?? 200
        let offset = json["offset"] as? Int ?? 0
        let (limited, truncated) = Self.sliceTextExact(text, limit: limit, offset: offset)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ToolCallOutcome(callID: callID, status: "success", summary: "read \(path)", data: limited, truncated: truncated, path: path, beforeHash: hash, started: true)
    }

    /// Minimal sanitized environment for ripgrep: never inherits the parent
    /// process environment, so RIPGREP_CONFIG_PATH/RIPGREP_CONFIG, PATH
    /// shadowing entries, and preprocessor configuration cannot influence the
    /// child. Combined with absolute-path launch + --no-config, poisoned env
    /// is inert by construction.
    static let sanitizedSearchEnv: [String: String] = [
        "PATH": "/usr/bin:/bin",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
    ]

    /// /proc/self/fd path for an open descriptor (Linux; /dev/fd elsewhere).
    /// Used to hand an already-validated open directory to ripgrep: the child
    /// resolves the same open file description, so pathname replacement or
    /// symlink swapping after validation cannot redirect the search.
    static func fdProcPath(_ fd: Int32) -> String {
#if canImport(Glibc)
        return "/proc/self/fd/\(fd)"
#else
        return "/dev/fd/\(fd)"
#endif
    }

    /// Monotonic nanoseconds for timeout accounting (immune to wall-clock
    /// adjustments, unlike Date()).
    static func monotonicNanos() -> UInt64 {
        var ts = timespec()
#if canImport(Glibc)
        _ = Glibc.clock_gettime(CLOCK_MONOTONIC, &ts)
#else
        _ = Darwin.clock_gettime(CLOCK_MONOTONIC, &ts)
#endif
        return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
    }

    /// Qualify the ripgrep executable and return an open FD to it (caller must
    /// close after launch). lstat rejects symlinks without following; open
    /// O_NOFOLLOW + fstat dev/ino equality with lstat rejects replacement
    /// between stat and open; group/world-writable, non-regular, non-root and
    /// non-owner executables are denied. Launching via /proc/self/fd/<fd>
    /// executes exactly the qualified inode (no pathname TOCTOU). The FD is
    /// deliberately inheritable (no O_CLOEXEC): script interpreters re-open
    /// the /proc/self/fd path AFTER exec, so a CLOEXEC executable FD would
    /// break #! probes/wrappers while ELF still worked — an asymmetric,
    /// hard-to-diagnose failure. The child holding a read-only handle to its
    /// own qualified binary is harmless.
    private func qualifiedRgFD() throws -> Int32 {
        guard let rg = rgPath else {
            throw ToolFailure.preDispatch(status: "denied", summary: "rg not provisioned")
        }
        guard rg.hasPrefix("/") else {
            throw ToolFailure.preDispatch(status: "denied", summary: "rg must be absolute path")
        }
        var lst = stat()
        guard lstat(rg, &lst) == 0 else {
            throw ToolFailure.preDispatch(status: "denied", summary: "rg not found")
        }
        if (lst.st_mode & S_IFMT) == S_IFLNK {
            throw ToolFailure.preDispatch(status: "denied", summary: "rg is symlink")
        }
        let fd = rg.withCString { cstr in
            open(cstr, O_RDONLY | O_NOFOLLOW)
        }
        guard fd >= 0 else {
            throw ToolFailure.preDispatch(status: "denied", summary: "rg open failed (symlink or replaced)")
        }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            close(fd)
            throw ToolFailure.preDispatch(status: "denied", summary: "rg fstat failed")
        }
        guard UInt64(st.st_dev) == UInt64(lst.st_dev) && UInt64(st.st_ino) == UInt64(lst.st_ino) else {
            close(fd)
            throw ToolFailure.preDispatch(status: "denied", summary: "rg replaced during qualification")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw ToolFailure.preDispatch(status: "denied", summary: "rg is not a regular file")
        }
        if (st.st_mode & 0o002) != 0 {
            close(fd)
            throw ToolFailure.preDispatch(status: "denied", summary: "rg is world-writable")
        }
        if (st.st_mode & 0o020) != 0 {
            close(fd)
            throw ToolFailure.preDispatch(status: "denied", summary: "rg is group-writable")
        }
        let uid = getuid()
        if st.st_uid != 0 && st.st_uid != uid {
            close(fd)
            throw ToolFailure.preDispatch(status: "denied", summary: "rg not owned by root or current user")
        }
        if (st.st_mode & 0o111) == 0 {
            close(fd)
            throw ToolFailure.preDispatch(status: "denied", summary: "rg is not executable")
        }
        // Lift above stdio (kept inheritable: script interpreters re-open
        // the /proc/self/fd path after exec). Failure fails closed.
        if fd >= 0 && fd <= 2 {
            let n = fcntl(fd, F_DUPFD, 3)
            guard n >= 0 else {
                close(fd)
                throw ToolFailure.preDispatch(status: "denied", summary: "rg fd lift failed")
            }
            close(fd)
            return n
        }
        return fd
    }

    /// Bounded child-process runner: concurrent stdout/stderr drain capped
    /// during execution (never buffered unboundedly), wall-clock timeout with
    /// terminate→SIGKILL escalation and reaping, cooperative cancellation.
    /// Returns stdout/stderr (capped), exit status, truncation and timeout.
    struct BoundedRunResult: Sendable {
        var stdout: Data
        var stderr: Data
        var status: Int32
        var truncated: Bool
        var stdoutTruncated: Bool
        var timedOut: Bool
    }

    /// Raw posix_spawn bounded runner. Foundation.Process closes inherited
    /// FDs in the child, which would break /proc/self/fd execution and
    /// directory-FD traversal; posix_spawn inherits exactly the FDs we leave
    /// open (CLOEXEC ones excepted), so the qualified rg inode and the pinned
    /// search-root FDs resolve inside the child. Stdout/stderr are drained
    /// concurrently via poll() with in-loop caps (never buffered unboundedly);
    /// wall-clock timeout escalates SIGTERM -> SIGKILL; the child is always
    /// reaped via waitpid; Task cancellation terminates and throws.
    /// Process-wide spawn lock: pipe() + FD_CLOEXEC + fork() are separate
    /// syscalls, so a concurrent fork in another thread could otherwise land
    /// inside the pipe-to-CLOEXEC window and inherit a write end without
    /// CLOEXEC (this toolchain's Glibc overlay exposes no pipe2). The lock is
    /// held from pipe creation through fork return, making the whole spawn
    /// section atomic across runners. The child never touches the lock.
    private static let spawnLock = NSLock()

    /// Spawn pipe pair: FDs lifted above stdio (dup2/close wiring can never
    /// alias 0/1/2), CLOEXEC (concurrent children must not inherit write
    /// ends, or EOF becomes unobservable), nonblocking read end for poll().
    /// Must be called with spawnLock held (see runBounded).
    private func makeSpawnPipe() throws -> (Int32, Int32) {
        var fds = [Int32](repeating: 0, count: 2)
        guard pipe(&fds) == 0 else {
            throw ToolFailure.preDispatch(status: "failed", summary: "rg pipe failed")
        }
        // Lift above stdio; F_DUPFD failure (EMFILE/EINTR) fails the whole
        // spawn CLOSED — a low surviving fd would reintroduce stdio aliasing
        // in the child's dup2 wiring. `cur` always holds exactly the open
        // FDs (a moved original is closed at move time and replaced), so the
        // catch below closes each FD exactly once.
        var cur = fds
        do {
            for i in 0..<cur.count {
                while cur[i] >= 0 && cur[i] <= 2 {
                    var n: Int32 = -1
                    var tries = 0
                    while tries < 2 {
                        n = fcntl(cur[i], F_DUPFD, 3)
                        if n >= 0 || errno != EINTR { break }
                        tries += 1
                    }
                    guard n >= 0 else {
                        throw ToolFailure.preDispatch(status: "failed", summary: "rg pipe failed: dup")
                    }
                    close(cur[i])
                    cur[i] = n
                }
            }
        } catch {
            for fd in cur { close(fd) }
            throw error
        }
        for fd in cur {
            let fdFlags = fcntl(fd, F_GETFD)
            _ = fcntl(fd, F_SETFD, fdFlags | FD_CLOEXEC)
        }
        let flags = fcntl(cur[0], F_GETFL)
        _ = fcntl(cur[0], F_SETFL, flags | O_NONBLOCK)
        return (cur[0], cur[1])
    }

    private func runBounded(executablePath: String, args: [String], stdoutCap: Int, stderrCap: Int, timeout: TimeInterval) throws -> BoundedRunResult {
        try Task.checkCancellation()
        Self.spawnLock.lock()
        let (outR, outW): (Int32, Int32)
        do {
            (outR, outW) = try makeSpawnPipe()
        } catch {
            Self.spawnLock.unlock()
            throw error
        }
        let errPair: (Int32, Int32)
        do {
            errPair = try makeSpawnPipe()
        } catch {
            close(outR)
            close(outW)
            Self.spawnLock.unlock()
            throw error
        }
        let (errR, errW) = errPair
        // fork+exec (not posix_spawn): glibc posix_spawn fails scripts with
        // ENOEXEC, while version probes and race-test wrappers are #! scripts
        // launched via /proc/self/fd. fork+execve handles both ELF and
        // scripts. All argv/env C strings are prepared pre-fork; the child
        // performs only async-signal-safe dup2/close/execve/_exit.
        let fullArgs = [executablePath] + args
        var argv: [UnsafeMutablePointer<CChar>?] = fullArgs.map { strdup($0) }
        argv.append(nil)
        defer { for p in argv { if let p { free(p) } } }
        let envList = Self.sanitizedSearchEnv.map { "\($0.key)=\($0.value)" }.sorted()
        var envp: [UnsafeMutablePointer<CChar>?] = envList.map { strdup($0) }
        envp.append(nil)
        defer { for p in envp { if let p { free(p) } } }
        guard let pathC = strdup(executablePath) else {
            close(outR); close(errR); close(outW); close(errW)
            Self.spawnLock.unlock()
            throw ToolFailure.preDispatch(status: "failed", summary: "rg launch failed: alloc")
        }
        defer { free(pathC) }
        let pid: pid_t
#if canImport(Glibc)
        pid = Glibc.fork()
#else
        pid = Darwin.fork()
#endif
        if pid < 0 {
            let e = errno
            close(outR); close(errR); close(outW); close(errW)
            Self.spawnLock.unlock()
            throw ToolFailure.preDispatch(status: "failed", summary: "rg fork failed: \(String(cString: strerror(e)))")
        }
        // Parent leaves the spawn section here; the drain loop below runs
        // unlocked so concurrent runners proceed independently.
        if pid != 0 {
            Self.spawnLock.unlock()
        }
        if pid == 0 {
            // Child: wire pipes to stdio, drop pipe FDs, exec. The qualified
            // rg FD and search-root FDs are inheritable and survive into rg
            // for /proc/self/fd resolution. Guards avoid closing stdio itself
            // if a pipe FD ever lands on 0/1/2. No Swift runtime interaction.
            _ = dup2(outW, STDOUT_FILENO)
            _ = dup2(errW, STDERR_FILENO)
            if outR != STDIN_FILENO && outR != STDOUT_FILENO && outR != STDERR_FILENO { close(outR) }
            if errR != STDIN_FILENO && errR != STDOUT_FILENO && errR != STDERR_FILENO { close(errR) }
            if outW != STDOUT_FILENO { close(outW) }
            if errW != STDERR_FILENO { close(errW) }
            argv.withUnsafeMutableBufferPointer { abuf in
                envp.withUnsafeMutableBufferPointer { ebuf in
#if canImport(Glibc)
                    _ = Glibc.execve(pathC, abuf.baseAddress!, ebuf.baseAddress!)
#else
                    _ = Darwin.execve(pathC, abuf.baseAddress!, ebuf.baseAddress!)
#endif
                }
            }
#if canImport(Glibc)
            Glibc._exit(127)
#else
            Darwin._exit(127)
#endif
        }
        // Parent closes write ends immediately so EOF is observable.
        close(outW)
        close(errW)
        var outData = Data()
        var errData = Data()
        func appendBounded(_ chunk: Data, cap: Int, current: inout Data, trunc: inout Bool) {
            if chunk.isEmpty { return }
            if current.count >= cap {
                trunc = true
                return
            }
            let room = cap - current.count
            if chunk.count <= room {
                current.append(chunk)
            } else {
                current.append(chunk.prefix(room))
                trunc = true
            }
        }
        // Bounded per-wakeup drain: sustained output must not starve the
        // timeout/cancellation checks below.
        func drain(fd: Int32, eof: inout Bool, current: inout Data, trunc: inout Bool, cap: Int, budget: Int) {
            if eof { return }
            var buf = [UInt8](repeating: 0, count: 8192)
            var remaining = budget
            while remaining > 0 {
                let n = buf.withUnsafeMutableBytes { ptr in
#if canImport(Glibc)
                    Glibc.read(fd, ptr.baseAddress, ptr.count)
#else
                    Darwin.read(fd, ptr.baseAddress, ptr.count)
#endif
                }
                if n > 0 {
                    appendBounded(Data(buf[0..<n]), cap: cap, current: &current, trunc: &trunc)
                    remaining -= 1
                } else if n == 0 {
                    eof = true
                    break
                } else {
                    if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    if errno == EINTR { continue }
                    eof = true
                    break
                }
            }
        }
        var outEOF = false
        var errEOF = false
        var outTruncCap = false
        var errTruncCap = false
        var exitStatus: Int32 = -1
        var childDone = false
        // Monotonic clock: wall-clock changes must not extend/truncate the
        // timeout. Hard stop is deadline+6 s; cleanup loops can add ~4 s, so
        // the real bound is ~timeout+10 s.
        let startNanos = Self.monotonicNanos()
        let deadlineNanos = startNanos + UInt64(timeout * 1_000_000_000)
        let hardNanos = deadlineNanos + 6_000_000_000
        var killNanos = UInt64.max
        var deadlineExceeded = false
        var hardStopped = false
        var termSent = false
        var killSent = false
        var cancelled = false
        while true {
            var pfds: [pollfd] = []
            if !outEOF { pfds.append(pollfd(fd: outR, events: Int16(POLLIN), revents: 0)) }
            if !errEOF { pfds.append(pollfd(fd: errR, events: Int16(POLLIN), revents: 0)) }
            if !pfds.isEmpty {
                _ = pfds.withUnsafeMutableBufferPointer { buf in
                    poll(buf.baseAddress, nfds_t(buf.count), 100)
                }
                for pfd in pfds where pfd.revents != 0 {
                    if pfd.fd == outR {
                        drain(fd: outR, eof: &outEOF, current: &outData, trunc: &outTruncCap, cap: stdoutCap, budget: 64)
                    } else {
                        drain(fd: errR, eof: &errEOF, current: &errData, trunc: &errTruncCap, cap: stderrCap, budget: 64)
                    }
                }
            } else {
                // Both pipes EOF but the child lives: do not busy-spin.
                usleep(10_000)
            }
            var st: Int32 = 0
            let wr = waitpid(pid, &st, WNOHANG)
            if wr == pid {
                childDone = true
                if (st & 0x7F) == 0 {
                    exitStatus = (st >> 8) & 0xFF
                } else {
                    exitStatus = 128
                }
            } else if wr < 0 && errno == ECHILD {
                // Reaped elsewhere: no zombie can remain, but the status is
                // unknown and the pid must never be signalled (reuse risk).
                childDone = true
            }
            let now = Self.monotonicNanos()
            // Deadline expiry is sticky and independent of child state: it is
            // evaluated BEFORE any success break, so a clean exit-0 whose EOF
            // is first observed after the deadline still counts as a timeout
            // (output past the budget is never success). A success break is
            // only valid while the deadline has not expired.
            if now >= deadlineNanos { deadlineExceeded = true }
            if childDone && outEOF && errEOF && !deadlineExceeded { break }
            if Task.isCancelled {
                cancelled = true
                break
            }
            if !childDone && now >= deadlineNanos && !termSent {
                deadlineExceeded = true
                termSent = true
#if canImport(Glibc)
                Glibc.kill(pid, SIGTERM)
#else
                Darwin.kill(pid, SIGTERM)
#endif
                killNanos = now + 2_000_000_000
            }
            if !childDone && termSent && !killSent && now >= killNanos {
#if canImport(Glibc)
                Glibc.kill(pid, SIGKILL)
#else
                Darwin.kill(pid, SIGKILL)
#endif
                killSent = true
                killNanos = now + 2_000_000_000
            }
            // Elapsed hard stop: never depend on childDone alone (a reaped
            // child plus an unobservable EOF must not hang the caller, and
            // must never be reported as success when reached).
            if (killSent && now >= killNanos) || now >= hardNanos {
                hardStopped = true
                break
            }
            if childDone && outEOF && errEOF { break }
        }
        if cancelled || (!childDone) {
            // Escalate and reap; cancellation always terminates the child.
            // Never signal a reaped pid (reuse risk): waitpid ECHILD marks
            // childDone above, and every kill below is guarded by !childDone.
            if !childDone {
#if canImport(Glibc)
                Glibc.kill(pid, SIGTERM)
#else
                Darwin.kill(pid, SIGTERM)
#endif
            }
            var st: Int32 = 0
            var waited = 0
            while !childDone && waited < 20 {
                let wr2 = waitpid(pid, &st, WNOHANG)
                if wr2 == pid {
                    childDone = true
                    if (st & 0x7F) == 0 {
                        exitStatus = (st >> 8) & 0xFF
                    } else {
                        exitStatus = 128
                    }
                    break
                }
                if wr2 < 0 && errno == ECHILD {
                    childDone = true
                    break
                }
                usleep(100_000)
                waited += 1
            }
            if !childDone {
#if canImport(Glibc)
                Glibc.kill(pid, SIGKILL)
#else
                Darwin.kill(pid, SIGKILL)
#endif
                var waited2 = 0
                while !childDone && waited2 < 20 {
                    let wr3 = waitpid(pid, &st, WNOHANG)
                    if wr3 == pid {
                        childDone = true
                        if (st & 0x7F) == 0 {
                            exitStatus = (st >> 8) & 0xFF
                        } else {
                            exitStatus = 128
                        }
                        break
                    }
                    if wr3 < 0 && errno == ECHILD {
                        childDone = true
                        break
                    }
                    usleep(100_000)
                    waited2 += 1
                }
            }
            // Final bounded drain after termination.
            drain(fd: outR, eof: &outEOF, current: &outData, trunc: &outTruncCap, cap: stdoutCap, budget: 1024)
            drain(fd: errR, eof: &errEOF, current: &errData, trunc: &errTruncCap, cap: stderrCap, budget: 1024)
        }
        close(outR)
        close(errR)
        if cancelled {
            throw CancellationError()
        }
        // deadlineExceeded is sticky: a SIGTERM that successfully killed rg
        // still counts as a timeout (partial output is never success). An
        // unreaped survivor past the hard stop, or a hard stop with
        // unobservable EOF (reaped child, descendant-held pipe), is likewise
        // a timeout — never masked as success.
        let timedOut = deadlineExceeded || hardStopped || !childDone
        return BoundedRunResult(stdout: outData, stderr: errData, status: exitStatus, truncated: outTruncCap || errTruncCap, stdoutTruncated: outTruncCap, timedOut: timedOut)
    }

    /// Version gate over the qualified FD path with sanitized env, bounded
    /// output and timeout. Must be >= 13.0.0; anything else fails closed.
    private func rgVersionGate(execPath: String) throws {
        let run: BoundedRunResult
        do {
            run = try runBounded(executablePath: execPath, args: ["--version"], stdoutCap: 4096, stderrCap: 4096, timeout: Self.versionTimeoutSeconds)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ToolFailure.preDispatch(status: "denied", summary: "rg version check failed")
        }
        if run.timedOut || run.truncated || run.status != 0 {
            throw ToolFailure.preDispatch(status: "denied", summary: "rg version check failed")
        }
        let out = String(decoding: run.stdout, as: UTF8.self)
        let versionPattern = try NSRegularExpression(pattern: #"ripgrep (\d+)\."#)
        guard let m = versionPattern.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
              let r = Range(m.range(at: 1), in: out),
              let v = Int(out[r]) else {
            throw ToolFailure.preDispatch(status: "denied", summary: "rg version check failed: unexpected output")
        }
        if v < 13 {
            throw ToolFailure.preDispatch(status: "denied", summary: "rg too old")
        }
    }

    private func search(callID: String, json: [String: Any], reservation: EffectReservation) throws -> ToolCallOutcome {
        // Qualify executable once; hold the FD open across version probe and
        // main launch so both execute the qualified inode.
        let rgFD = try qualifiedRgFD()
        defer { close(rgFD) }
        let rgExec = Self.fdProcPath(rgFD)
        do {
            try rgVersionGate(execPath: rgExec)
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as ToolFailure {
            throw e
        } catch {
            throw ToolFailure.preDispatch(status: "denied", summary: "rg version check failed")
        }
        let pattern = json["pattern"] as? String ?? ""
        if pattern.isEmpty {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "missing pattern")
        }
        // Traversal pruning is UNCONDITIONAL: every protected category is
        // excluded before traversal, whether or not the reservation approves
        // something inside it. Approved grantable access is delivered not by
        // relaxing these globs but by resolving each approved grantable path
        // itself to a held-open FD and passing it as an extra search target
        // below — so traversal (and hence every open()) is confined to
        // exactly the approved inodes. The per-line JSON classifier remains as
        // defense in depth (authorization decision per emitted line).
        // Unconditional traversal pruning. Bare-name forms are included
        // alongside dir forms so a regular FILE named exactly .git/.ssh/
        // .needletail/credentials is also pruned before traversal (a file so
        // named is still classified grantable/absolute-denied at the output
        // layer, and an approved one is delivered via its own FD target whose
        // /proc/self/fd path contains no protected name). Substring-style
        // artifact globs are deliberately NOT added: classification denies
        // only exact/suffixed components, and a broad *artifacts* glob would
        // wrongly prune legitimate names with no approval recourse.
        var argv = ["--json", "--no-config", "--hidden", "--max-count", "1000", "--glob", "!.git/", "--glob", "!**/.git/**", "--glob", "!.git", "--glob", "!.env*", "--glob", "!**/.env*", "--glob", "!.ssh/", "--glob", "!**/.ssh/**", "--glob", "!.ssh", "--glob", "!.needletail/", "--glob", "!**/.needletail/**", "--glob", "!.needletail", "--glob", "!*artifacts*/", "--glob", "!**/*artifacts*/**", "--glob", "!artifacts", "--glob", "!*-artifacts", "--glob", "!.credentials/", "--glob", "!**/.credentials/**", "--glob", "!.credentials", "--glob", "!credentials/", "--glob", "!**/credentials/**", "--glob", "!credentials", "--", pattern]
        // Resolve search roots to HELD OPEN directory FDs and pass only
        // /proc/self/fd paths to ripgrep. The FDs stay open (cloexec cleared so
        // the child inherits them) across process launch: ripgrep traverses
        // the pinned open file descriptions, so symlink swapping or directory
        // replacement of the validated path after validation cannot redirect
        // the search. No workspace/read-root pathname ever reaches argv.
        // Each entry maps the argv path to its logical base for output
        // classification (relative portion within the root).
        var heldRootFDs: [Int32] = []
        defer { for fd in heldRootFDs { close(fd) } }
        var roots: [(proc: String, logicalBase: String)] = []
        // Domain identity for approval resolution: -1 = workspace, otherwise
        // the readRoots index. Approvals resolve from the same domain first
        // so an explicit read-root scope never shows a workspace twin.
        var explicitDomain: Int? = nil
        func holdRootFD(_ fd: Int32) throws -> String {
            // Child must inherit this FD so /proc/self/fd/<fd> resolves inside
            // ripgrep after exec; clear FD_CLOEXEC (set by openRelative).
            // Lift above stdio first: with stdio closed a held FD could land
            // on 1/2 and be clobbered by the child's dup2 wiring. Lift failure
            // (EMFILE) fails closed; the original is closed exactly once on
            // either path. Concurrency note: these read-only directory/file
            // FDs (and the qualified rg FD) are intentionally inheritable, so
            // a concurrent runner's child also inherits them. That is safe by
            // construction: (a) pipe write ends are CLOEXEC under spawnLock,
            // so no foreign child can hold our pipes open and EOF stays
            // observable; (b) an inherited FD alone grants no traversal —
            // the child only walks argv paths, and every emitted line still
            // passes the per-path classifier; (c) all held FDs are closed
            // here exactly once via the defer below after the child is
            // reaped.
            var f = fd
            if f >= 0 && f <= 2 {
                let n = fcntl(f, F_DUPFD, 3)
                guard n >= 0 else {
                    close(f)
                    throw ToolFailure.preDispatch(status: "failed", summary: "fd lift failed")
                }
                close(f)
                f = n
            }
            _ = fcntl(f, F_SETFD, 0)
            heldRootFDs.append(f)
            return Self.fdProcPath(f)
        }
        if let searchPath = json["path"] as? String, !searchPath.isEmpty {
            let cls = ToolValidator.protectedClassification(for: searchPath)
            if cls == .absoluteDenied {
                throw ToolFailure.preDispatch(status: "denied", summary: "absolute protected path for search")
            }
            if cls == .grantable && !ToolValidator.isApprovedPath(searchPath, approvedPaths: reservation.approvedPaths) {
                throw ToolFailure.preDispatch(status: "denied", summary: "grantable search path requires approval")
            }
            var found = false
            if resolver.workspaceRoot != nil {
                do {
                    let dirFD = try resolver.validatedWorkspaceFD()
                    defer { close(dirFD) }
                    let fd = try resolver.openRelative(searchPath, from: dirFD, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    roots.append((try holdRootFD(fd), searchPath))
                    found = true
                    explicitDomain = -1
                } catch let e as ToolFailure {
                    throw e
                } catch {
                    // Precedence: a missing path (even one NAMED like a
                    // symlink, or a replaced root that no longer opens) falls
                    // through to the read-root attempt and finally to
                    // no-match. Only a genuine symlink encounter denies, and
                    // resource exhaustion fails. Never let a path substring
                    // decide.
                    if Self.isNotFound(error) {
                        // fall through
                    } else if Self.isSymlinkError(error) {
                        throw ToolFailure.preDispatch(status: "denied", summary: "symlink in search path")
                    } else if Self.isResourceError(error) {
                        throw ToolFailure.preDispatch(status: "failed", summary: "search root unavailable: \(error)")
                    }
                }
            }
            if !found {
                for (i, rr) in resolver.readRoots.enumerated() {
                    do {
                        let dirFD = try resolver.revalidatedFD(for: rr)
                        defer { close(dirFD) }
                        let fd = try resolver.openRelative(searchPath, from: dirFD, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        roots.append((try holdRootFD(fd), searchPath))
                        found = true
                        explicitDomain = i
                        break
                    } catch let e as ToolFailure {
                        throw e
                    } catch {
                        // Precedence: a missing path (even one NAMED like a
                        // symlink, or a replaced root) falls through to the
                        // next domain and finally to no-match; only a genuine
                        // symlink encounter denies, and resource exhaustion
                        // fails. Never let a path substring decide.
                        if Self.isNotFound(error) {
                            continue
                        }
                        if Self.isSymlinkError(error) {
                            throw ToolFailure.preDispatch(status: "denied", summary: "symlink in search path")
                        }
                        if Self.isResourceError(error) {
                            throw ToolFailure.preDispatch(status: "failed", summary: "search root unavailable: \(error)")
                        }
                        continue
                    }
                }
            }
            if !found {
                return ToolCallOutcome(callID: callID, status: "no-match", summary: "search path not found", data: "", started: true)
            }
        } else {
            guard resolver.workspaceRoot != nil || !resolver.readRoots.isEmpty else {
                throw ToolFailure.preDispatch(status: "denied", summary: "no workspace/read-root for search")
            }
            if resolver.workspaceRoot != nil {
                do {
                    let fd = try resolver.validatedWorkspaceFD()
                    roots.append((try holdRootFD(fd), ""))
                } catch let e as ToolFailure {
                    throw e
                } catch {
                    throw ToolFailure.preDispatch(status: "denied", summary: "workspace root replaced")
                }
            }
            for rr in resolver.readRoots {
                do {
                    let fd = try resolver.revalidatedFD(for: rr)
                    roots.append((try holdRootFD(fd), ""))
                } catch let e as ToolFailure {
                    throw e
                } catch {
                    // A replaced read-root fails closed individually; others
                    // still constrain the search to pinned directories.
                    continue
                }
            }
            if roots.isEmpty {
                throw ToolFailure.preDispatch(status: "denied", summary: "no valid search root")
            }
        }
        // Precise approved access: every grantable approval except the exact
        // explicit root gets its own held-open FD target. Approvals deliberately
        // expand the search beyond an explicit path: the unconditioned globs
        // above would otherwise prune an approved grantable descendant of the
        // explicit root (fail-closed false negative), and only an exact root
        // is already fully covered by traversal. Unprotected approvals need
        // no target (broad roots already show them); absolute-denied
        // approvals are never granted.
        let explicitBase: String? = (json["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var domainOrder: [Int] = []
        if let ed = explicitDomain { domainOrder.append(ed) }
        if !domainOrder.contains(-1) { domainOrder.append(-1) }
        for i in resolver.readRoots.indices where !domainOrder.contains(i) { domainOrder.append(i) }
        for approved in reservation.approvedPaths {
            guard ToolValidator.protectedClassification(for: approved) == .grantable else { continue }
            if let base = explicitBase, ToolValidator.byteEqual(approved, base) { continue }
            do {
                if let fd = try openApprovedTarget(approved, domainOrder: domainOrder) {
                    roots.append((try holdRootFD(fd), approved))
                }
            } catch {
                return ToolCallOutcome(callID: callID, status: "failed", summary: "approved target unavailable", data: "", error: "resource exhaustion", started: true)
            }
        }
        for r in roots {
            argv.append(r.proc)
        }
        // Launch via the qualified FD path with the sanitized environment.
        // No parent env (no RIPGREP_CONFIG_PATH, no PATH) is inherited and
        // --no-config is passed, so poisoned config / PATH shadowing /
        // preprocessor injection is inert. Root FDs are held open across the
        // run so the child always traverses the pinned directories.
        let run: BoundedRunResult
        do {
            run = try runBounded(executablePath: rgExec, args: argv, stdoutCap: Self.maxSearchStdoutBytes, stderrCap: Self.maxSearchStderrBytes, timeout: Self.searchTimeoutSeconds)
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as ToolFailure {
            throw e
        } catch {
            return ToolCallOutcome(callID: callID, status: "failed", summary: "rg failed", data: "", error: "\(error)", started: true)
        }
        if run.timedOut {
            return ToolCallOutcome(callID: callID, status: "failed", summary: "rg timed out", data: "", error: "timeout", started: true)
        }
        // rg exit codes are 0 (match), 1 (no match), 2+ (error). Partial
        // stdout alongside an error is not a successful search.
        if run.status != 0 && run.status != 1 {
            return ToolCallOutcome(callID: callID, status: "failed", summary: "rg failed", data: "", error: "rg exit \(run.status)", started: true)
        }
        // The stdout cap was enforced during the drain; if the cap cut
        // mid-line, drop the trailing partial JSON line so every retained
        // line parses completely. (Stderr capping never discards stdout.)
        var outputData = run.stdout
        var truncated = run.truncated
        if run.stdoutTruncated, let lastNL = outputData.lastIndex(of: 0x0A) {
            outputData = outputData.prefix(through: lastNL)
        } else if run.stdoutTruncated {
            outputData = Data()
        }
        let (text, omittedUnparseable) = Self.filterSearchJSON(outputData, roots: roots, approvedPaths: reservation.approvedPaths)
        if omittedUnparseable {
            truncated = true
        }
        return ToolCallOutcome(callID: callID, status: "success", summary: "search \(pattern)", data: text, truncated: truncated, started: true)
    }

    /// Parse ripgrep --json output and keep only authorized match records.
    /// Each line with a path (text, or base64 bytes) is mapped to its LOGICAL
    /// path (argv /proc/self/fd prefix stripped, joined to the root's logical
    /// base) and classified via ToolValidator.protectedClassification:
    /// absoluteDenied is always dropped; grantable is kept only when the
    /// reservation approves the exact path or an ancestor prefix (lossy
    /// names never approve); unprotected is kept. Summary/metadata lines are
    /// dropped by design (stats aggregate over traversed files). Unparseable
    /// or unclassifiable lines are dropped fail-closed. Content mentioning
    /// ".git"/".env" in ordinary files is preserved: only the actual file
    /// path is classified, never the match text.
    ///
    /// Enforcement model: argv globs prune protected categories BEFORE
    /// traversal, unconditionally. Approved grantable paths are delivered as
    /// their own held-open FD targets (never by relaxing the globs), so
    /// traversal never enters unapproved grantable content. This per-line
    /// classifier remains as defense in depth: the authorization decision
    /// point for every emitted line. Summaries are withheld.
    static func filterSearchJSON(_ output: Data, roots: [(proc: String, logicalBase: String)], approvedPaths: [String]) -> (String, Bool) {
        guard !output.isEmpty else { return ("", false) }
        let text = String(decoding: output, as: UTF8.self)
        var kept: [String] = []
        var omittedUnparseable = false
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for raw in lines {
            let line = String(raw)
            guard let objData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: objData) as? [String: Any] else {
                omittedUnparseable = true
                continue
            }
            // ripgrep reports non-UTF-8 paths as {"path":{"bytes":base64}}.
            // A lossless UTF-8 decode proceeds exactly; otherwise the lossy
            // skeleton is used for CLASSIFICATION only (every ASCII byte is
            // preserved exactly, and protected names are pure ASCII, so
            // markers can be neither hidden nor forged). Lossy paths can
            // never satisfy an approval below: distinct raw names decode to
            // the same U+FFFD skeleton, so a literal-U+FFFD approval must not
            // collide across inodes. Undecodable base64 fails closed.
            var pathText: String? = nil
            var pathPresent = false
            var pathLossy = false
            if let data = obj["data"] as? [String: Any],
               let path = data["path"] as? [String: Any] {
                pathPresent = true
                if let t = path["text"] as? String {
                    pathText = t
                } else if let b = path["bytes"] as? String,
                          let rawBytes = Data(base64Encoded: b) {
                    if let exact = String(data: rawBytes, encoding: .utf8) {
                        pathText = exact
                    } else {
                        pathText = String(decoding: rawBytes, as: UTF8.self)
                        pathLossy = true
                    }
                }
            }
            guard let reported = pathText else {
                if pathPresent {
                    // Path object present but unusable: fail closed.
                    omittedUnparseable = true
                } else if (obj["type"] as? String) != "summary" {
                    // Unknown pathless record: fail closed. Summaries are
                    // dropped by design (their stats aggregate over all
                    // traversed files, including unapproved-relaxed ones —
                    // an existence oracle), never emitted.
                    omittedUnparseable = true
                }
                continue
            }
            guard let logical = Self.logicalSearchPath(reported: reported, roots: roots) else {
                continue
            }
            switch ToolValidator.protectedClassification(for: logical) {
            case .absoluteDenied:
                continue
            case .grantable:
                // Lossy-decoded names never match approvals (U+FFFD
                // collisions across distinct raw inodes); only exact names
                // the operator approved are visible.
                if !pathLossy && Self.isSearchPathApproved(logical, approvedPaths: approvedPaths) {
                    kept.append(line)
                }
            case .unprotected:
                kept.append(line)
            }
        }
        var out = kept.joined(separator: "\n")
        if !out.isEmpty {
            out += "\n"
        }
        return (out, omittedUnparseable)
    }

    /// Map an rg-reported path back to its logical relative path: strip the
    /// matching /proc/self/fd argv prefix and join with the root's logical
    /// base. Returns nil for paths outside every pinned root or containing
    /// ".." (fail closed).
    static func logicalSearchPath(reported: String, roots: [(proc: String, logicalBase: String)]) -> String? {
        // Byte-exact prefix matching: a reported name starting with a
        // combining mark would glue to "/" into one grapheme and defeat a
        // Character-based hasPrefix/dropFirst (silently dropping legitimate
        // unprotected matches or mis-mapping approved ones).
        let rep = Array(reported.utf8)
        for r in roots {
            let proc = Array(r.proc.utf8)
            if rep == proc {
                return r.logicalBase.isEmpty ? nil : r.logicalBase
            }
            if rep.count > proc.count + 1, rep.starts(with: proc), rep[proc.count] == 0x2F {
                let rel = String(decoding: rep[(proc.count + 1)...], as: UTF8.self)
                if rel.isEmpty || ToolValidator.byteComponents(of: rel).contains("..") {
                    return nil
                }
                if r.logicalBase.isEmpty {
                    return rel
                }
                return r.logicalBase + "/" + rel
            }
        }
        return nil
    }

    /// Grantable approval covers the exact path or any ancestor prefix
    /// (approving a search root authorizes its subtree view).
    static func isSearchPathApproved(_ logical: String, approvedPaths: [String]) -> Bool {
        ToolValidator.isApprovedPrefix(logical, approvedPaths: approvedPaths)
    }

    /// Resolve one approved grantable path to a held-open FD for use as an
    /// exact search target (caller takes ownership via holdRootFD). Directory
    /// first, then regular file; symlinks, missing paths and special files
    /// fail closed (nil). Domains are tried in the caller-supplied order
    /// (explicit search domain first). Resource exhaustion (EMFILE/ENFILE)
    /// throws instead of returning nil so an unavailable approved target is
    /// reported as a failure rather than silently skipped like a missing path.
    private func openApprovedTarget(_ approved: String, domainOrder: [Int]) throws -> Int32? {
        var resourceHit = false
        func attempt(from dirFD: Int32) -> Int32? {
            do {
                return try resolver.openRelative(approved, from: dirFD, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            } catch {
                if Self.isResourceError(error) { resourceHit = true }
            }
            do {
                return try resolver.openRelative(approved, from: dirFD, flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            } catch {
                if Self.isResourceError(error) { resourceHit = true }
            }
            return nil
        }
        for domain in domainOrder {
            if domain == -1 {
                guard resolver.workspaceRoot != nil else { continue }
                do {
                    let dirFD = try resolver.validatedWorkspaceFD()
                    defer { close(dirFD) }
                    if let fd = attempt(from: dirFD) { return fd }
                } catch {
                    if Self.isResourceError(error) { resourceHit = true }
                    continue
                }
            } else if domain >= 0 && domain < resolver.readRoots.count {
                do {
                    let dirFD = try resolver.revalidatedFD(for: resolver.readRoots[domain])
                    defer { close(dirFD) }
                    if let fd = attempt(from: dirFD) { return fd }
                } catch {
                    if Self.isResourceError(error) { resourceHit = true }
                    continue
                }
            }
        }
        if resourceHit {
            throw ToolFailure.preDispatch(status: "failed", summary: "approved target unavailable: resource exhaustion")
        }
        return nil
    }

    static func isResourceError(_ error: Error) -> Bool {
        // openat/fstat errors surface errno via strerror in StoreError messages.
        let s = "\(error)"
        return s.contains("Too many open files")
    }

    static func isSymlinkError(_ error: Error) -> Bool {
        // Resolver reports symlink encounters and symlink-swapped roots.
        "\(error)".contains("symlink")
    }

    // B3 edit: byte-exact replacement authorized by an expected SHA-256.
    // Order under the B1 workspace lock (held by execute() for the batch):
    // validate → bounded read → hash/match checks → tmp write+fsync →
    // path re-open + dev/ino + hash gate immediately before commit →
    // preimage publish → atomic rename. The gate re-opens the PATH (never
    // the held fd), so replacement, deletion and symlink swap after the
    // initial read all conflict with no preimage and no mutation; the
    // preimage is published only for content that WILL be replaced.
    // Optimistic check only: a same-user writer bypassing the lock is a
    // documented residual (the gate still detects it here); the residual
    // check-to-rename window is nanoseconds wide and documented.
    private func edit(callID: String, json: [String: Any]) throws -> ToolCallOutcome {
        let path = json["path"] as? String ?? ""
        let expectedHash = json["expectedHash"] as? String ?? ""
        // Validator requires a 64-hex expectedHash; re-check defensively —
        // replacement without an authorized hash is never attempted.
        guard expectedHash.count == 64, expectedHash.allSatisfy({ $0.isHexDigit }) else {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "missing or malformed expectedHash for edit \(callID)")
        }
        let oldStr = (json["oldBytes"] as? String) ?? (json["old_string"] as? String) ?? ""
        let newStr = (json["newBytes"] as? String) ?? (json["new_string"] as? String) ?? ""
        let oldBytes = oldStr.data(using: .utf8) ?? Data()
        let newBytes = newStr.data(using: .utf8) ?? Data()
        if oldBytes.isEmpty {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "empty oldBytes")
        }
        guard resolver.workspaceRoot != nil else {
            throw ToolFailure.preDispatch(status: "denied", summary: "no workspace")
        }
        // Open descriptor-relative, read-only: we never write through this
        // fd (commit goes via same-dir tmp + rename). openRelative already
        // rejects directories, FIFOs, sockets and devices for file opens,
        // and symlinks anywhere via O_NOFOLLOW.
        let dirFD = try resolver.validatedWorkspaceFD()
        defer { close(dirFD) }
        let fd: Int32
        do {
            fd = try resolver.openRelative(path, from: dirFD, flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        } catch {
            if Self.isNotFound(error) {
                return ToolCallOutcome(callID: callID, status: "no-match", summary: "not found", data: "", path: path, started: true)
            }
            throw error
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            return ToolCallOutcome(callID: callID, status: "failed", summary: "not a regular file", data: "", error: "not a regular file", started: true)
        }
        let fileMode = st.st_mode & 0o7777
        // Bounded read: post-fstat growth cannot blow memory (same bound as
        // the read path). Quota errors are size errors; anything else is a
        // read failure (never conflated).
        let current: Data
        do {
            current = try Self.readBoundedEdit(fd: fd)
        } catch let e as StoreError {
            if case .quotaExceeded = e {
                return ToolCallOutcome(callID: callID, status: "failed", summary: "over size limit", data: "", error: "too large", path: path, started: true)
            }
            return ToolCallOutcome(callID: callID, status: "failed", summary: "read failed: \(e)", data: "", error: "\(e)", path: path, started: true)
        } catch {
            return ToolCallOutcome(callID: callID, status: "failed", summary: "read failed: \(error)", data: "", error: "\(error)", path: path, started: true)
        }
        let currentHash = Self.sha256Hex(current)
        if currentHash != expectedHash {
            return ToolCallOutcome(callID: callID, status: "conflict", summary: "hash mismatch", data: "", error: "conflict", path: path, beforeHash: currentHash, started: true)
        }
        let occurrences = Self.occurrenceCount(haystack: current, needle: oldBytes)
        if occurrences == 0 {
            return ToolCallOutcome(callID: callID, status: "no-match", summary: "oldBytes not found", data: "", path: path, beforeHash: currentHash, started: true)
        }
        if occurrences > 1 {
            return ToolCallOutcome(callID: callID, status: "invalid-arguments", summary: "multiple matches", data: "", error: "multiple", path: path, beforeHash: currentHash, started: true)
        }
        guard let range = current.range(of: oldBytes) else {
            return ToolCallOutcome(callID: callID, status: "no-match", summary: "oldBytes not found", data: "", path: path, beforeHash: currentHash, started: true)
        }
        var newData = Data(current[..<range.lowerBound])
        newData.append(newBytes)
        newData.append(Data(current[range.upperBound...]))
        // Same-dir parent, descriptor-relative (the held dirFD pins the
        // workspace root; the parent FD pins the rename target directory,
        // so a path swap cannot redirect the commit).
        // NOTE: the cleanup defer is at FUNCTION scope — a defer inside the
        // else branch would run at BRANCH exit and close parentFD early.
        let (dirPath, fileName) = Self.splitParentLeaf(path)
        let parentFD: Int32
        let ownsParentFD: Bool
        if dirPath.isEmpty || dirPath == "." {
            parentFD = dirFD
            ownsParentFD = false
        } else {
            parentFD = try resolver.openRelative(dirPath, from: dirFD, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            ownsParentFD = true
        }
        defer { if ownsParentFD { close(parentFD) } }
        return commitReplacement(callID: callID, path: path, fileFD: fd, current: current, expectedHash: expectedHash, newData: newData, fileMode: fileMode, parentFD: parentFD, fileName: fileName, verb: "edited")
    }

    /// Bounded file read for the edit path (32 MiB cap, growth-safe loop).
    /// Throws on over-cap so callers map to a typed too-large outcome.
    static func readBoundedEdit(fd: Int32) throws -> Data {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        var total = 0
        // Fail when growth EXCEEDS the budget (a file of exactly the budget
        // reads whole; anything more fails closed rather than succeeding
        // with silently truncated bytes that would then hash-mismatch).
        let cap = Int(Self.maxReadFileBytes)
        while true {
            let n = buf.withUnsafeMutableBytes { ptr in Glibc.read(fd, ptr.baseAddress, ptr.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw StoreError.integrity("edit read failed: \(String(cString: strerror(errno)))")
            }
            if n == 0 { break }
            total += n
            if total > cap { throw StoreError.quotaExceeded(limit: Int(Self.maxReadFileBytes)) }
            data.append(contentsOf: buf[0..<n])
        }
        return data
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func modeOctal(_ mode: mode_t) -> String {
        String(format: "%o", mode & 0o7777)
    }

    /// Occurrence count with OVERLAP ("aaa" contains "aa" twice, at 0 and 1).
    /// Stops at 2: callers only distinguish zero / exactly-one / multiple.
    /// REV25 requires "exactly once" — overlapping occurrences are distinct
    /// positions and count toward multiple.
    static func occurrenceCount(haystack: Data, needle: Data) -> Int {
        guard !needle.isEmpty, needle.count <= haystack.count else { return 0 }
        var count = 0
        var from = haystack.startIndex
        while from < haystack.endIndex,
              let r = haystack.range(of: needle, options: [], in: from..<haystack.endIndex) {
            count += 1
            if count > 1 { return count }
            from = haystack.index(after: r.lowerBound)
        }
        return count
    }

    /// Byte-exact parent/leaf split on the LAST 0x2F byte. Character-based
    /// splitting is WRONG here ("/" + combining mark is one grapheme, so
    /// lastIndex(of:) can miss a real separator and hand openat/renameat a
    /// leaf with an embedded "/", traversing an unchecked intermediate).
    /// No NFC/NFD normalization, unlike NSString path APIs — which also hit
    /// a UD2 trap in this toolchain's Foundation on Linux.
    /// "f" → ("", "f"); "sub/dir/n.txt" → ("sub/dir", "n.txt").
    static func splitParentLeaf(_ path: String) -> (dir: String, file: String) {
        let bytes = Array(path.utf8)
        if let i = bytes.lastIndex(of: 0x2F) {
            return (String(decoding: bytes[..<i], as: UTF8.self),
                    String(decoding: bytes[(i + 1)...], as: UTF8.self))
        }
        return ("", path)
    }

    static func isNotFound(_ error: Error) -> Bool {
        "\(error)".contains("No such")
    }

    /// Shared commit tail for edit and authorized write-replacement.
    /// Caller owns all FDs except the tmp (created and cleaned up here).
    /// Order: exclusive tmp (prepare) → re-open gate + preimage + rename
    /// (finalize). Any failure before rename leaves the target untouched and
    /// removes the tmp; a conflict after a complete tmp publishes NO preimage
    /// (nothing will be modified). If rename fails AFTER the preimage commit,
    /// the preimage reference remains (recoverable by design — it describes
    /// verifiable pre-commit bytes; B3-B byte accounting reconciles it).
    /// Unlink failures on cleanup paths are ignored: the parent is writable
    /// in every path that creates a tmp (creation itself would have failed
    /// otherwise), so a leftover would require an intervening failure
    /// outside this function's control; documented residual, no silent
    /// user-data effect either way. Split into two internal phases so
    /// phase-level tests can inject filesystem changes deterministically
    /// between them; production always runs both back-to-back with the
    /// workspace lock held.
    private func commitReplacement(callID: String, path: String, fileFD: Int32, current: Data, expectedHash: String, newData: Data, fileMode: mode_t, parentFD: Int32, fileName: String, verb: String) -> ToolCallOutcome {
        let tmpName: String
        do {
            tmpName = try prepareCommitTmp(newData: newData, fileMode: fileMode, parentFD: parentFD)
        } catch {
            return ToolCallOutcome(callID: callID, status: "failed", summary: "commit prepare failed: \(error)", data: "", error: "\(error)", path: path, beforeHash: expectedHash, started: true)
        }
        return finalizeCommit(callID: callID, path: path, fileFD: fileFD, current: current, expectedHash: expectedHash, newData: newData, fileMode: fileMode, parentFD: parentFD, fileName: fileName, tmpName: tmpName, verb: verb)
    }

    /// Commit phase 1 (internal for phase-level tests): exclusive same-dir
    /// tmp, checked write loop (partial writes retried, never silent),
    /// checked fsync, checked mode preserve. Throws on any failure with
    /// nothing committed and the tmp removed.
    func prepareCommitTmp(newData: Data, fileMode: mode_t, parentFD: Int32) throws -> String {
        let tmpName = "." + UUID().uuidString + ".tmp"
        let tmpFD = tmpName.withCString { name in
            openat(parentFD, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        }
        guard tmpFD >= 0 else {
            throw StoreError.integrity("tmp create failed: \(String(cString: strerror(errno)))")
        }
        var committed = false
        defer {
            close(tmpFD)
            if !committed {
                _ = tmpName.withCString { unlinkat(parentFD, $0, 0) }
            }
        }
        var offset = 0
        let total = newData.count
        while offset < total {
            let n = newData.withUnsafeBytes { raw -> Int in
                Glibc.write(tmpFD, raw.baseAddress!.advanced(by: offset), total - offset)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw StoreError.integrity("tmp write failed: \(String(cString: strerror(errno)))")
            }
            if n == 0 {
                throw StoreError.integrity("tmp short write")
            }
            offset += n
        }
        // fchmod BEFORE fsync so the single sync covers the mode change too.
        guard fchmod(tmpFD, fileMode) == 0 else {
            throw StoreError.integrity("tmp mode preserve failed: \(String(cString: strerror(errno)))")
        }
        guard fsync(tmpFD) == 0 else {
            throw StoreError.integrity("tmp fsync failed: \(String(cString: strerror(errno)))")
        }
        committed = true
        return tmpName
    }

    /// Commit phase 2 (internal for phase-level tests): consumes a prepared
    /// tmp. Re-OPENS the path (never the held fd): atomic replacement,
    /// deletion, and symlink swap between initial read and commit are all
    /// visible here, because the held fd still points at the replaced-away
    /// inode. Dev/ino identity is compared first (replacement/deletion and
    /// symlink swap conflict even when content would hash equal), then the
    /// fresh bytes are hashed. Any gate failure removes the tmp and leaves
    /// the target untouched with no preimage. Rename failure removes the tmp
    /// with the target untouched; a published preimage remains committed
    /// (recoverable by design — it describes bytes that verifiably existed).
    func finalizeCommit(callID: String, path: String, fileFD: Int32, current: Data, expectedHash: String, newData: Data, fileMode: mode_t, parentFD: Int32, fileName: String, tmpName: String, verb: String) -> ToolCallOutcome {
        func fail(_ summary: String, _ error: String, beforeHash: String) -> ToolCallOutcome {
            _ = tmpName.withCString { unlinkat(parentFD, $0, 0) }
            return ToolCallOutcome(callID: callID, status: "failed", summary: summary, data: "", error: error, path: path, beforeHash: beforeHash, started: true)
        }
        func conflict(_ summary: String, beforeHash: String) -> ToolCallOutcome {
            _ = tmpName.withCString { unlinkat(parentFD, $0, 0) }
            return ToolCallOutcome(callID: callID, status: "conflict", summary: summary, data: "", error: "conflict", path: path, beforeHash: beforeHash, started: true)
        }
        // Fresh open of the PATH (O_NOFOLLOW): the held fileFD cannot see a
        // swap, so only this open can. O_NONBLOCK: a swapped-in FIFO must not
        // block the opener while the workspace lock is held (it then fails
        // the regular-file check below and conflicts).
        let checkFD: Int32 = fileName.withCString { name in
            openat(parentFD, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard checkFD >= 0 else {
            let e = errno
            if e == ENOENT {
                return conflict("target deleted before commit", beforeHash: expectedHash)
            }
            if e == ELOOP {
                return conflict("target replaced by symlink before commit", beforeHash: expectedHash)
            }
            return fail("re-open failed: \(String(cString: strerror(e)))", String(cString: strerror(e)), beforeHash: expectedHash)
        }
        defer { close(checkFD) }
        var origST = stat()
        var freshST = stat()
        guard fstat(fileFD, &origST) == 0, fstat(checkFD, &freshST) == 0 else {
            return fail("re-open fstat failed", "integrity", beforeHash: expectedHash)
        }
        guard (freshST.st_mode & S_IFMT) == S_IFREG else {
            return conflict("target replaced by special file before commit", beforeHash: expectedHash)
        }
        guard origST.st_dev == freshST.st_dev, origST.st_ino == freshST.st_ino else {
            return conflict("target replaced before commit", beforeHash: expectedHash)
        }
        let reread: Data
        do {
            reread = try Self.readBoundedEdit(fd: checkFD)
        } catch let e as StoreError {
            if case .quotaExceeded = e {
                return fail("over size limit", "too large", beforeHash: expectedHash)
            }
            return fail("re-read failed: \(e)", "\(e)", beforeHash: expectedHash)
        } catch {
            return fail("re-read failed: \(error)", "\(error)", beforeHash: expectedHash)
        }
        let rereadHash = Self.sha256Hex(reread)
        guard rereadHash == expectedHash else {
            return conflict("hash changed before commit", beforeHash: rereadHash)
        }
        // Verified preimage before modifying a nonempty file. Zero-byte
        // originals publish nothing (hash-only receipt; sha256-empty is
        // constant). Publication failure fails the commit with the target
        // untouched and the tmp cleaned.
        let afterHash = Self.sha256Hex(newData)
        var preimageDigest: String? = nil
        if !current.isEmpty {
            do {
                let ref = try store.publishArtifact(session: sessionID, as: writer, kind: "preimage", operationID: nil, bytes: current)
                guard ref.digest == expectedHash else {
                    return fail("preimage digest mismatch", "integrity", beforeHash: expectedHash)
                }
                preimageDigest = ref.digest
            } catch {
                return fail("preimage publish failed: \(error)", "\(error)", beforeHash: expectedHash)
            }
        }
        let renameRet = fileName.withCString { oldC in
            tmpName.withCString { tmpC in
                renameat(parentFD, tmpC, parentFD, oldC)
            }
        }
        guard renameRet == 0 else {
            return fail("rename failed: \(String(cString: strerror(errno)))", String(cString: strerror(errno)), beforeHash: expectedHash)
        }
        // Post-commit directory sync: best-effort durability signal. A
        // failure here does not undo the atomic rename; it is reported, not
        // hidden, since durability is weakened.
        var warnings: [String] = []
        if fsync(parentFD) != 0 {
            warnings = ["directory sync failed: \(String(cString: strerror(errno)))"]
        }
        return ToolCallOutcome(callID: callID, status: "success", summary: "\(verb) \(path)", data: verb, artifactID: preimageDigest, warnings: warnings, path: path, mode: Self.modeOctal(fileMode), beforeHash: expectedHash, afterHash: afterHash, started: true)
    }

    // B3 write: create_new is exclusive and never silently overwrites.
    // Replacement is a SEPARATE authorized form: presence of expectedHash
    // (64 hex, validated) authorizes whole-file replacement under the exact
    // edit contract (re-read gate, verified preimage, atomic rename,
    // preserved mode, machine-readable receipts). Without expectedHash an
    // existing file (or a symlink/special at the path) fails closed.
    private func write(callID: String, json: [String: Any]) throws -> ToolCallOutcome {
        let path = json["path"] as? String ?? ""
        let content = (json["content"] as? String ?? "").data(using: .utf8) ?? Data()
        let expectedHashOpt = json["expectedHash"] as? String
        if let h = expectedHashOpt {
            guard h.count == 64, h.allSatisfy({ $0.isHexDigit }) else {
                throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "expectedHash must be 64 hex for write \(callID)")
            }
        }
        guard resolver.workspaceRoot != nil else {
            throw ToolFailure.preDispatch(status: "denied", summary: "no workspace")
        }
        let dirFD = try resolver.validatedWorkspaceFD()
        defer { close(dirFD) }
        if let expectedHash = expectedHashOpt {
            return try writeReplacement(callID: callID, path: path, content: content, expectedHash: expectedHash, dirFD: dirFD)
        }
        // Exclusive create: a probe that finds anything (file, dir, symlink,
        // special) fails closed; only genuine absence proceeds. The probe is
        // advisory — O_EXCL below is authoritative and closes the race.
        do {
            let fd = try resolver.openRelative(path, from: dirFD, flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            return ToolCallOutcome(callID: callID, status: "failed", summary: "exists", data: "", error: "exists", path: path, started: true)
        } catch {
            if !Self.isNotFound(error) { throw error }
        }
        // NOTE: the cleanup defer is at FUNCTION scope — a defer inside the
        // else branch would run at BRANCH exit and close parentFD early.
        let (dirPath, fileName) = Self.splitParentLeaf(path)
        let parentFD: Int32
        let ownsParentFD: Bool
        if dirPath.isEmpty || dirPath == "." {
            parentFD = dirFD
            ownsParentFD = false
        } else {
            // Create parent dirs descriptor-relative via mkdirat chain (no FileManager path following symlinks)
            do {
                parentFD = try resolver.openRelative(dirPath, from: dirFD, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            } catch {
                // Try to create the missing parent chain via mkdirat
                try Self.mkdirs(dirPath, from: dirFD)
                parentFD = try resolver.openRelative(dirPath, from: dirFD, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            ownsParentFD = true
        }
        defer { if ownsParentFD { close(parentFD) } }
        let fd = fileName.withCString { name in
            openat(parentFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard fd >= 0 else {
            if errno == EEXIST {
                return ToolCallOutcome(callID: callID, status: "failed", summary: "exists", data: "", error: "exists", path: path, started: true)
            }
            return ToolCallOutcome(callID: callID, status: "failed", summary: "create failed", data: "", error: String(cString: strerror(errno)), path: path, started: true)
        }
        defer { close(fd) }
        // Checked write loop + checked fsync; failure removes the partial file.
        var offset = 0
        let total = content.count
        while offset < total {
            let n = content.withUnsafeBytes { raw -> Int in
                Glibc.write(fd, raw.baseAddress!.advanced(by: offset), total - offset)
            }
            if n < 0 {
                if errno == EINTR { continue }
                _ = fileName.withCString { unlinkat(parentFD, $0, 0) }
                return ToolCallOutcome(callID: callID, status: "failed", summary: "write failed", data: "", error: String(cString: strerror(errno)), path: path, started: true)
            }
            if n == 0 {
                _ = fileName.withCString { unlinkat(parentFD, $0, 0) }
                return ToolCallOutcome(callID: callID, status: "failed", summary: "write failed", data: "", error: "short write", path: path, started: true)
            }
            offset += n
        }
        // fchmod before fsync so the synced image carries the final mode;
        // both checked. Mode is read back (not assumed) for the receipt.
        guard fchmod(fd, mode_t(0o600)) == 0 else {
            _ = fileName.withCString { unlinkat(parentFD, $0, 0) }
            return ToolCallOutcome(callID: callID, status: "failed", summary: "fchmod failed", data: "", error: String(cString: strerror(errno)), path: path, started: true)
        }
        guard fsync(fd) == 0 else {
            _ = fileName.withCString { unlinkat(parentFD, $0, 0) }
            return ToolCallOutcome(callID: callID, status: "failed", summary: "fsync failed", data: "", error: String(cString: strerror(errno)), path: path, started: true)
        }
        var createdST = stat()
        let createdMode: String
        if fstat(fd, &createdST) == 0, (createdST.st_mode & S_IFMT) == S_IFREG {
            createdMode = Self.modeOctal(createdST.st_mode)
        } else {
            createdMode = "600"
        }
        var warnings: [String] = []
        if fsync(parentFD) != 0 {
            warnings = ["directory sync failed: \(String(cString: strerror(errno)))"]
        }
        let hash = Self.sha256Hex(content)
        return ToolCallOutcome(callID: callID, status: "success", summary: "write \(path)", data: "written", warnings: warnings, path: path, mode: createdMode, afterHash: hash, started: true)
    }

    /// Authorized write-replacement: the file must exist and hash exactly to
    /// expectedHash, then the edit commit pipeline runs (re-read gate,
    /// verified preimage, atomic rename, preserved mode). A stale hash
    /// conflicts with the file untouched and no preimage; a missing file is
    /// no-match (create_new without expectedHash creates instead).
    private func writeReplacement(callID: String, path: String, content: Data, expectedHash: String, dirFD: Int32) throws -> ToolCallOutcome {
        let fd: Int32
        do {
            fd = try resolver.openRelative(path, from: dirFD, flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        } catch {
            if Self.isNotFound(error) {
                return ToolCallOutcome(callID: callID, status: "no-match", summary: "not found for replacement", data: "", path: path, started: true)
            }
            throw error
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            return ToolCallOutcome(callID: callID, status: "failed", summary: "not a regular file", data: "", error: "not a regular file", path: path, started: true)
        }
        let fileMode = st.st_mode & 0o7777
        let current: Data
        do {
            current = try Self.readBoundedEdit(fd: fd)
        } catch let e as StoreError {
            if case .quotaExceeded = e {
                return ToolCallOutcome(callID: callID, status: "failed", summary: "over size limit", data: "", error: "too large", path: path, started: true)
            }
            return ToolCallOutcome(callID: callID, status: "failed", summary: "read failed: \(e)", data: "", error: "\(e)", path: path, started: true)
        } catch {
            return ToolCallOutcome(callID: callID, status: "failed", summary: "read failed: \(error)", data: "", error: "\(error)", path: path, started: true)
        }
        let currentHash = Self.sha256Hex(current)
        if currentHash != expectedHash {
            return ToolCallOutcome(callID: callID, status: "conflict", summary: "hash mismatch", data: "", error: "conflict", path: path, beforeHash: currentHash, started: true)
        }
        // NOTE: cleanup defer at FUNCTION scope (a branch-level defer would
        // close parentFD before commitReplacement runs).
        let (dirPath, fileName) = Self.splitParentLeaf(path)
        let parentFD: Int32
        let ownsParentFD: Bool
        if dirPath.isEmpty || dirPath == "." {
            parentFD = dirFD
            ownsParentFD = false
        } else {
            parentFD = try resolver.openRelative(dirPath, from: dirFD, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            ownsParentFD = true
        }
        defer { if ownsParentFD { close(parentFD) } }
        return commitReplacement(callID: callID, path: path, fileFD: fd, current: current, expectedHash: expectedHash, newData: content, fileMode: fileMode, parentFD: parentFD, fileName: fileName, verb: "replaced")
    }

    private static func mkdirs(_ dirPath: String, from dirFD: Int32) throws {
        // Byte-split (see openRelative): a Character split would keep an
        // embedded "/" inside one component and mkdirat/openat would then
        // traverse it, bypassing per-component checks.
        var components: [String] = []
        var piece: [UInt8] = []
        for b in dirPath.utf8 {
            if b == 0x2F {
                components.append(String(decoding: piece, as: UTF8.self))
                piece.removeAll(keepingCapacity: true)
            } else {
                piece.append(b)
            }
        }
        components.append(String(decoding: piece, as: UTF8.self))
        var currentFD = dirFD
        var owned: [Int32] = []
        defer {
            for fd in owned { close(fd) }
            if currentFD != dirFD && !owned.contains(currentFD) {
                close(currentFD)
            }
        }
        for comp in components {
            let name = String(comp)
            if name.isEmpty || name == "." || name == ".." { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "invalid dir component") }
            let fd = name.withCString { cstr in openat(currentFD, cstr, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            if fd >= 0 {
                if currentFD != dirFD {
                    owned.append(currentFD)
                }
                currentFD = fd
                continue
            }
            if errno != ENOENT {
                throw StoreError.integrity("mkdirs open failed: \(String(cString: strerror(errno)))")
            }
            // Create via mkdirat
            let ret = name.withCString { cstr in mkdirat(currentFD, cstr, mode_t(0o700)) }
            guard ret == 0 else {
                throw StoreError.integrity("mkdirat failed for \(name): \(String(cString: strerror(errno)))")
            }
            let newFD = name.withCString { cstr in openat(currentFD, cstr, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard newFD >= 0 else {
                throw StoreError.integrity("mkdirs re-open failed: \(String(cString: strerror(errno)))")
            }
            if currentFD != dirFD {
                owned.append(currentFD)
            }
            currentFD = newFD
        }
    }
}
