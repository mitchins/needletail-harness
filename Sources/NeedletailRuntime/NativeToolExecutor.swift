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
            if cls == .grantable && !reservation.approvedPaths.contains(path) {
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
            var acc = 0
            var keep = 0
            for line in slice {
                // Each kept line is followed by "\n" in the output (mid-file cut
                // always ends at a line boundary; EOF-newline case keeps it).
                let lb = line.utf8.count + 1
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
        // fstat), so the loop itself caps at maxReadFileBytes+1 and reports
        // oversize instead of buffering unboundedly.
        var data = Data()
        let readCap = Int(Self.maxReadFileBytes) + 1
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
    private func runBounded(executablePath: String, args: [String], stdoutCap: Int, stderrCap: Int, timeout: TimeInterval) throws -> BoundedRunResult {
        try Task.checkCancellation()
        var outFds = [Int32](repeating: 0, count: 2)
        var errFds = [Int32](repeating: 0, count: 2)
        guard pipe(&outFds) == 0, pipe(&errFds) == 0 else {
            throw ToolFailure.preDispatch(status: "failed", summary: "rg pipe failed")
        }
        let outR = outFds[0], outW = outFds[1]
        let errR = errFds[0], errW = errFds[1]
        // Nonblocking reads for the poll drain loop.
        for fd in [outR, errR] {
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
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
            throw ToolFailure.preDispatch(status: "failed", summary: "rg fork failed: \(String(cString: strerror(e)))")
        }
        if pid == 0 {
            // Child: wire pipes to stdio, drop pipe FDs, exec. The qualified
            // rg FD (CLOEXEC) stays open through exec pathname resolution;
            // search-root FDs (inheritable) survive into rg for /proc/self/fd
            // traversal. No Swift runtime interaction here.
            _ = dup2(outW, STDOUT_FILENO)
            _ = dup2(errW, STDERR_FILENO)
            close(outR); close(errR); close(outW); close(errW)
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
        var outTrunc = false
        var errTrunc = false
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
        func drain(fd: Int32, eof: inout Bool, current: inout Data, trunc: inout Bool, cap: Int) {
            if eof { return }
            var buf = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = buf.withUnsafeMutableBytes { ptr in
#if canImport(Glibc)
                    Glibc.read(fd, ptr.baseAddress, ptr.count)
#else
                    Darwin.read(fd, ptr.baseAddress, ptr.count)
#endif
                }
                if n > 0 {
                    appendBounded(Data(buf[0..<n]), cap: cap, current: &current, trunc: &trunc)
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
        var exitStatus: Int32 = -1
        var childDone = false
        let deadline = Date().addingTimeInterval(timeout)
        var termSent = false
        var killSent = false
        var killDeadline = Date.distantFuture
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
                        drain(fd: outR, eof: &outEOF, current: &outData, trunc: &outTrunc, cap: stdoutCap)
                    } else {
                        drain(fd: errR, eof: &errEOF, current: &errData, trunc: &errTrunc, cap: stderrCap)
                    }
                }
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
            }
            if childDone && outEOF && errEOF { break }
            let now = Date()
            if Task.isCancelled {
                cancelled = true
                break
            }
            if !childDone && now >= deadline && !termSent {
#if canImport(Glibc)
                Glibc.kill(pid, SIGTERM)
#else
                Darwin.kill(pid, SIGTERM)
#endif
                termSent = true
                killDeadline = now.addingTimeInterval(2)
            }
            if !childDone && termSent && !killSent && now >= killDeadline {
#if canImport(Glibc)
                Glibc.kill(pid, SIGKILL)
#else
                Darwin.kill(pid, SIGKILL)
#endif
                killSent = true
                killDeadline = now.addingTimeInterval(2)
            }
            if killSent && now >= killDeadline { break }
            if childDone && outEOF && errEOF { break }
        }
        if cancelled || (!childDone) {
            // Escalate and reap; cancellation always terminates the child.
#if canImport(Glibc)
            Glibc.kill(pid, SIGTERM)
#else
            Darwin.kill(pid, SIGTERM)
#endif
            var st: Int32 = 0
            var waited = 0
            while waitpid(pid, &st, WNOHANG) != pid && waited < 20 {
                usleep(100_000)
                waited += 1
            }
            if !childDone {
#if canImport(Glibc)
                Glibc.kill(pid, SIGKILL)
#else
                Darwin.kill(pid, SIGKILL)
#endif
                _ = waitpid(pid, &st, 0)
                if (st & 0x7F) == 0 {
                    exitStatus = (st >> 8) & 0xFF
                }
            }
            // Final nonblocking drain after termination.
            drain(fd: outR, eof: &outEOF, current: &outData, trunc: &outTrunc, cap: stdoutCap)
            drain(fd: errR, eof: &errEOF, current: &errData, trunc: &errTrunc, cap: stderrCap)
        }
        close(outR)
        close(errR)
        if cancelled {
            throw CancellationError()
        }
        let timedOut = !childDone
        return BoundedRunResult(stdout: outData, stderr: errData, status: exitStatus, truncated: outTrunc || errTrunc, timedOut: timedOut)
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
        // Approval-aware traversal pruning: absolute-denial categories
        // (.needletail, credentials, artifacts) are ALWAYS pruned (approval can
        // never grant them); grantable categories (.git/.ssh/.env) are pruned
        // unless the reservation approves a path inside that category, in
        // which case ripgrep traverses it and the per-line JSON classifier
        // below enforces approval exactly (approved subtree visible,
        // everything else still dropped).
        var skipGitGlobs = false
        var skipSshGlobs = false
        var skipEnvGlobs = false
        for a in reservation.approvedPaths {
            let comps = a.split(separator: "/").map(String.init)
            if comps.contains(".git") { skipGitGlobs = true }
            if comps.contains(".ssh") { skipSshGlobs = true }
            if comps.contains(where: { $0 == ".env" || $0.hasPrefix(".env.") }) { skipEnvGlobs = true }
        }
        var argv = ["--json", "--no-config", "--hidden", "--max-count", "1000"]
        if !skipGitGlobs {
            argv += ["--glob", "!.git/", "--glob", "!**/.git/**"]
        }
        if !skipEnvGlobs {
            argv += ["--glob", "!.env*", "--glob", "!**/.env*"]
        }
        if !skipSshGlobs {
            argv += ["--glob", "!.ssh/", "--glob", "!**/.ssh/**"]
        }
        argv += ["--glob", "!.needletail/", "--glob", "!**/.needletail/**", "--glob", "!*artifacts*/", "--glob", "!**/*artifacts*/**", "--glob", "!.credentials/", "--glob", "!**/.credentials/**", "--glob", "!credentials/", "--glob", "!**/credentials/**", "--", pattern]
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
        func holdRootFD(_ fd: Int32) -> String {
            // Child must inherit this FD so /proc/self/fd/<fd> resolves inside
            // ripgrep after exec; clear FD_CLOEXEC (set by openRelative).
            _ = fcntl(fd, F_SETFD, 0)
            heldRootFDs.append(fd)
            return Self.fdProcPath(fd)
        }
        if let searchPath = json["path"] as? String, !searchPath.isEmpty {
            let cls = ToolValidator.protectedClassification(for: searchPath)
            if cls == .absoluteDenied {
                throw ToolFailure.preDispatch(status: "denied", summary: "absolute protected path for search")
            }
            if cls == .grantable && !reservation.approvedPaths.contains(searchPath) {
                throw ToolFailure.preDispatch(status: "denied", summary: "grantable search path requires approval")
            }
            var found = false
            if resolver.workspaceRoot != nil {
                do {
                    let dirFD = try resolver.validatedWorkspaceFD()
                    defer { close(dirFD) }
                    let fd = try resolver.openRelative(searchPath, from: dirFD, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    roots.append((holdRootFD(fd), searchPath))
                    found = true
                } catch {}
            }
            if !found {
                for rr in resolver.readRoots {
                    do {
                        let dirFD = try resolver.revalidatedFD(for: rr)
                        defer { close(dirFD) }
                        let fd = try resolver.openRelative(searchPath, from: dirFD, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        roots.append((holdRootFD(fd), searchPath))
                        found = true
                        break
                    } catch { continue }
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
                    roots.append((holdRootFD(fd), ""))
                } catch {
                    throw ToolFailure.preDispatch(status: "denied", summary: "workspace root replaced")
                }
            }
            for rr in resolver.readRoots {
                do {
                    let fd = try resolver.revalidatedFD(for: rr)
                    roots.append((holdRootFD(fd), ""))
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
        if run.status != 0 && run.status != 1 {
            if run.stdout.isEmpty {
                return ToolCallOutcome(callID: callID, status: "failed", summary: "rg failed", data: "", error: "rg exit \(run.status)", started: true)
            }
        }
        // Cap was enforced during the drain; if the cap cut mid-line, drop the
        // trailing partial JSON line so every retained line parses completely.
        var outputData = run.stdout
        var truncated = run.truncated
        if truncated, let lastNL = outputData.lastIndex(of: 0x0A) {
            outputData = outputData.prefix(through: lastNL)
        } else if truncated {
            outputData = Data()
        }
        let (text, omittedUnparseable) = Self.filterSearchJSON(outputData, roots: roots, approvedPaths: reservation.approvedPaths)
        if omittedUnparseable {
            truncated = true
        }
        return ToolCallOutcome(callID: callID, status: "success", summary: "search \(pattern)", data: text, truncated: truncated, started: true)
    }

    /// Parse ripgrep --json output and keep only authorized lines. Each line
    /// with data.path.text is classified by its LOGICAL path (argv
    /// /proc/self/fd prefix stripped, joined to the root's logical base) via
    /// ToolValidator.protectedClassification: absoluteDenied is always
    /// dropped; grantable is kept only when the reservation approves the path
    /// or an ancestor prefix. Lines without a path (summary) are kept;
    /// unparseable non-empty lines are dropped fail-closed. Content
    /// mentioning ".git"/".env" in ordinary files is preserved: only the
    /// actual file path is classified, never the match text.
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
            var pathText: String? = nil
            if let data = obj["data"] as? [String: Any],
               let path = data["path"] as? [String: Any],
               let t = path["text"] as? String {
                pathText = t
            }
            guard let reported = pathText else {
                kept.append(line)
                continue
            }
            guard let logical = Self.logicalSearchPath(reported: reported, roots: roots) else {
                continue
            }
            switch ToolValidator.protectedClassification(for: logical) {
            case .absoluteDenied:
                continue
            case .grantable:
                if Self.isSearchPathApproved(logical, approvedPaths: approvedPaths) {
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
        for r in roots {
            if reported == r.proc {
                return r.logicalBase.isEmpty ? nil : r.logicalBase
            }
            let prefix = r.proc + "/"
            if reported.hasPrefix(prefix) {
                let rel = String(reported.dropFirst(prefix.count))
                if rel.isEmpty || rel.split(separator: "/").contains(where: { $0 == ".." }) {
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
        for a in approvedPaths {
            if logical == a || logical.hasPrefix(a + "/") {
                return true
            }
        }
        return false
    }

    private func edit(callID: String, json: [String: Any]) throws -> ToolCallOutcome {
        let path = json["path"] as? String ?? ""
        let expectedHash = json["expectedHash"] as? String ?? ""
        let oldStr = (json["oldBytes"] as? String) ?? (json["old_string"] as? String) ?? ""
        let newStr = (json["newBytes"] as? String) ?? (json["new_string"] as? String) ?? ""
        let oldBytes = oldStr.data(using: .utf8) ?? Data()
        let newBytes = newStr.data(using: .utf8) ?? Data()
        if oldBytes.isEmpty {
            throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "empty oldBytes")
        }
        guard let ws = resolver.workspaceRoot else {
            throw ToolFailure.preDispatch(status: "denied", summary: "no workspace")
        }
        // Open file descriptor-relative
        let dirFD = try resolver.validatedWorkspaceFD()
        defer { close(dirFD) }
        let fd = try resolver.openRelative(path, from: dirFD, flags: O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        defer { close(fd) }
        var st = stat()
        fstat(fd, &st)
        // Read current content via fd
        _ = lseek(fd, 0, SEEK_SET)
        var current = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = buf.withUnsafeMutableBytes { ptr in Glibc.read(fd, ptr.baseAddress, ptr.count) }
            if n <= 0 { break }
            current.append(contentsOf: buf[0..<n])
        }
        let currentHash = SHA256.hash(data: current).map { String(format: "%02x", $0) }.joined()
        if !expectedHash.isEmpty && currentHash != expectedHash {
            return ToolCallOutcome(callID: callID, status: "conflict", summary: "hash mismatch", data: "", error: "conflict", path: path, beforeHash: currentHash, started: true)
        }
        guard let range = current.range(of: oldBytes) else {
            return ToolCallOutcome(callID: callID, status: "no-match", summary: "oldBytes not found", data: "", path: path, beforeHash: currentHash, started: true)
        }
        let rest = current[range.upperBound...]
        if rest.range(of: oldBytes) != nil {
            return ToolCallOutcome(callID: callID, status: "invalid-arguments", summary: "multiple matches", data: "", error: "multiple", started: true)
        }
        var newData = Data(current[..<range.lowerBound])
        newData.append(newBytes)
        newData.append(Data(current[range.upperBound...]))
        let afterHash = SHA256.hash(data: newData).map { String(format: "%02x", $0) }.joined()
        // Write via same-dir tmp + rename using descriptor-relative
        let dirPath = (path as NSString).deletingLastPathComponent
        let parentFD: Int32
        if dirPath.isEmpty || dirPath == "." {
            parentFD = dirFD
        } else {
            parentFD = try resolver.openRelative(dirPath, from: dirFD, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            defer { if parentFD != dirFD { close(parentFD) } }
        }
        let tmpName = "." + UUID().uuidString + ".tmp"
        let tmpFD = tmpName.withCString { name in
            openat(parentFD, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        }
        guard tmpFD >= 0 else {
            return ToolCallOutcome(callID: callID, status: "failed", summary: "tmp create failed", data: "", error: String(cString: strerror(errno)), started: true)
        }
        // Write
        let written = newData.withUnsafeBytes { ptr in
            Glibc.write(tmpFD, ptr.baseAddress, ptr.count)
        }
        guard written == newData.count else {
            close(tmpFD); _ = tmpName.withCString { unlinkat(parentFD, $0, 0) }
            return ToolCallOutcome(callID: callID, status: "failed", summary: "write failed", data: "", error: "write", started: true)
        }
        _ = fsync(tmpFD)
        // Preserve mode
        _ = fchmod(tmpFD, st.st_mode & 0o777)
        close(tmpFD)
        defer { _ = tmpName.withCString { unlinkat(parentFD, $0, 0) } }
        // Rename via renameat
        let oldName = (path as NSString).lastPathComponent
        let renameRet = oldName.withCString { oldC in
            tmpName.withCString { tmpC in
                renameat(parentFD, tmpC, parentFD, oldC)
            }
        }
        if renameRet != 0 {
            return ToolCallOutcome(callID: callID, status: "failed", summary: "rename failed", data: "", error: String(cString: strerror(errno)), started: true)
        }
        // Sync directory
        _ = fsync(parentFD)
        return ToolCallOutcome(callID: callID, status: "success", summary: "edit \(path)", data: "edited", path: path, beforeHash: currentHash, afterHash: afterHash, started: true)
    }

    private func write(callID: String, json: [String: Any]) throws -> ToolCallOutcome {
        let path = json["path"] as? String ?? ""
        let content = (json["content"] as? String ?? "").data(using: .utf8) ?? Data()
        guard let ws = resolver.workspaceRoot else {
            throw ToolFailure.preDispatch(status: "denied", summary: "no workspace")
        }
        let dirFD = try resolver.validatedWorkspaceFD()
        defer { close(dirFD) }
        // Check existence via openRelative: if exists, fail
        do {
            let fd = try resolver.openRelative(path, from: dirFD, flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            return ToolCallOutcome(callID: callID, status: "failed", summary: "exists", data: "", error: "exists", started: true)
        } catch {
            // Not exists is expected for create_new, continue
            if let se = error as? StoreError, case .integrity(let msg) = se, msg.contains("No such") {
                // Expected
            } else if "\(error)".contains("No such") {
                // Expected
            } else {
                // Other error (e.g., absolute, protected) should have been thrown earlier
                // If it's a StoreError for protected, it would have been thrown as ToolFailure, not here
                // So if we are here and it's not "No such", we need to propagate
                // But for write, we want to create the file, so we need to create parent dirs first
            }
        }
        let dirPath = (path as NSString).deletingLastPathComponent
        let parentFD: Int32
        if dirPath.isEmpty || dirPath == "." {
            parentFD = dirFD
        } else {
            // Create parent dirs descriptor-relative via mkdirat chain (no FileManager path following symlinks)
            do {
                parentFD = try resolver.openRelative(dirPath, from: dirFD, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            } catch {
                // Try to create the missing parent chain via mkdirat
                try Self.mkdirs(dirPath, from: dirFD)
                parentFD = try resolver.openRelative(dirPath, from: dirFD, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            defer { if parentFD != dirFD { close(parentFD) } }
        }
        let fileName = (path as NSString).lastPathComponent
        let fd = fileName.withCString { name in
            openat(parentFD, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        }
        guard fd >= 0 else {
            if errno == EEXIST {
                return ToolCallOutcome(callID: callID, status: "failed", summary: "exists", data: "", error: "exists", started: true)
            }
            return ToolCallOutcome(callID: callID, status: "failed", summary: "create failed", data: "", error: String(cString: strerror(errno)), started: true)
        }
        defer { close(fd) }
        let written = content.withUnsafeBytes { ptr in Glibc.write(fd, ptr.baseAddress, ptr.count) }
        guard written == content.count else {
            return ToolCallOutcome(callID: callID, status: "failed", summary: "write failed", data: "", error: "write", started: true)
        }
        _ = fsync(fd)
        let hash = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        return ToolCallOutcome(callID: callID, status: "success", summary: "write \(path)", data: "written", path: path, afterHash: hash, started: true)
    }

    private static func mkdirs(_ dirPath: String, from dirFD: Int32) throws {
        let components = dirPath.split(separator: "/")
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
