import Foundation
import SystemPackage
import NeedletailCore
import Crypto
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

private func byteSplit(_ path: String) -> [String] {
    var parts: [String] = []
    var piece: [UInt8] = []
    piece.reserveCapacity(64)
    for b in path.utf8 {
        if b == 0x2F { parts.append(String(decoding: piece, as: UTF8.self)); piece.removeAll(keepingCapacity: true) }
        else { piece.append(b) }
    }
    parts.append(String(decoding: piece, as: UTF8.self))
    return parts
}

/// C2 exec runner — revalidates approved identity immediately before spawn
/// (anchored walk, qualify, hash, compare), uses FD-based exec via
/// /proc/self/fd and F_DUPFD, and handles cwd revalidation. The exec-error
/// pipe and spill-lease are handled in NativeToolExecutor.runBounded for the
/// generic case; this runner is the typed exec entry point used by tests
/// and by the SessionActor's exec arm.
public struct ExecRunner: Sendable {
    public struct Result: Sendable {
        public var stdout: Data
        public var stderr: Data
        public var exitStatus: Int32
        public var truncated: Bool
        public var timedOut: Bool
        /// Exact bytes read from the pipe but dropped by the cap (from the
        /// runner's drain counters — never cap-minus-kept).
        public var discardedStdoutBytes: Int64
        public var discardedStderrBytes: Int64
        public var durationMs: UInt64
    }

    static let baseEnv: [String: String] = [
        "PATH": "/usr/bin:/bin",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
    ]

    public let resolver: WorkspaceResolver

    public init(resolver: WorkspaceResolver) {
        self.resolver = resolver
    }

    // MARK: - C2 revalidation (anchored walk, no FD crosses actor hops)

    private struct Verified {
        let fd: Int32
        let execPath: String
        let cwdFD: Int32?
        let resolvedPath: String
    }

    private func revalidateAndOpen(
        args: ExecArguments,
        expectedDigest: String,
        expectedCwd: (device: UInt64, inode: UInt64)?
    ) throws -> Verified {
        // Re-run the anchored walk from "/" for the executable, exactly as
        // NativeToolExecutor.resolveOne does, but keep the FD open for exec.
        // No FD crosses actor hops — we re-resolve here.
        var stack: [String] = []
        var dirFD: Int32 = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dirFD >= 0 else { throw ToolFailure.preDispatch(status: "failed", summary: "root unavailable") }
        var hops = 0
        var resolvedPath = ""
        var finalFD: Int32 = -1
        defer { if dirFD >= 0 { close(dirFD) } }
        var components = byteSplit(args.executable).filter { !$0.isEmpty }
        var i = 0
        while i < components.count {
            let comp = components[i]
            if comp == ".." {
                guard stack.popLast() != nil else { throw ToolFailure.preDispatch(status: "conflict", summary: "exec identity mismatch (symlink escape)") }
                let parent = openat(dirFD, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                guard parent >= 0 else { throw ToolFailure.preDispatch(status: "conflict", summary: "exec identity mismatch") }
                close(dirFD); dirFD = parent; i += 1; continue
            }
            if comp == "." || comp.isEmpty { i += 1; continue }
            if i == components.count - 1 {
                let fd = comp.withCString { openat(dirFD, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
                if fd >= 0 {
                    finalFD = fd; stack.append(comp); resolvedPath = "/" + stack.joined(separator: "/"); break
                }
                var target = [CChar](repeating: 0, count: 4097)
                let n = comp.withCString { readlinkat(dirFD, $0, &target, 4096) }
                if n > 0 {
                    hops += 1; if hops > 40 { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "symlink hop budget exceeded") }
                    target[n] = 0
                    let linkTarget = String(cString: target)
                    if linkTarget.utf8.first == 0x2F {
                        close(dirFD); dirFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                        guard dirFD >= 0 else { throw ToolFailure.preDispatch(status: "failed", summary: "root unavailable") }
                        stack.removeAll(); resolvedPath = ""
                        components = byteSplit(linkTarget).filter({ !$0.isEmpty }) + Array(components[(i+1)...]); i = 0
                    } else {
                        var tail = byteSplit(linkTarget).filter({ !$0.isEmpty }) + Array(components[(i+1)...])
                        var newStack = stack
                        while let first = tail.first, first == ".." {
                            guard newStack.popLast() != nil else { throw ToolFailure.preDispatch(status: "conflict", summary: "exec identity mismatch (symlink escape)") }
                            let parent = openat(dirFD, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                            guard parent >= 0 else { throw ToolFailure.preDispatch(status: "conflict", summary: "exec identity mismatch") }
                            close(dirFD); dirFD = parent; tail.removeFirst()
                        }
                        components = tail; stack = newStack; resolvedPath = "/" + stack.joined(separator: "/")
                        if components.isEmpty { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "symlink resolves to directory") }
                        i = 0
                    }
                    continue
                }
                throw ToolFailure.preDispatch(status: "conflict", summary: "exec identity mismatch (executable not found)")
            }
            let nextFD = comp.withCString { openat(dirFD, $0, O_RDONLY | O_NOFOLLOW | O_DIRECTORY) }
            if nextFD >= 0 {
                close(dirFD); dirFD = nextFD; stack.append(comp); resolvedPath = "/" + stack.joined(separator: "/"); i += 1; continue
            }
            var target = [CChar](repeating: 0, count: 4097)
            let n = comp.withCString { readlinkat(dirFD, $0, &target, 4096) }
            guard n > 0 else { throw ToolFailure.preDispatch(status: "conflict", summary: "exec identity mismatch") }
            hops += 1; if hops > 40 { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "symlink hop budget exceeded") }
            target[n] = 0
            let linkTarget = String(cString: target)
            if linkTarget.utf8.first == 0x2F {
                close(dirFD); dirFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                guard dirFD >= 0 else { throw ToolFailure.preDispatch(status: "failed", summary: "root unavailable") }
                stack.removeAll(); resolvedPath = ""
                components = byteSplit(linkTarget).filter({ !$0.isEmpty }) + Array(components[(i+1)...]); i = 0
            } else {
                var tail = byteSplit(linkTarget).filter({ !$0.isEmpty }) + Array(components[(i+1)...])
                var newStack = stack
                while let first = tail.first, first == ".." {
                    guard newStack.popLast() != nil else { throw ToolFailure.preDispatch(status: "conflict", summary: "exec identity mismatch") }
                    let parent = openat(dirFD, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                    guard parent >= 0 else { throw ToolFailure.preDispatch(status: "conflict", summary: "exec identity mismatch") }
                    close(dirFD); dirFD = parent; tail.removeFirst()
                }
                components = tail; stack = newStack; resolvedPath = "/" + stack.joined(separator: "/"); i = 0
            }
        }
        if finalFD < 0 { throw ToolFailure.preDispatch(status: "conflict", summary: "exec identity mismatch") }
        // Qualify (same checks as resolveOne)
        var st = stat()
        guard fstat(finalFD, &st) == 0 else { close(finalFD); throw ToolFailure.preDispatch(status: "conflict", summary: "exec identity mismatch") }
        guard (st.st_mode & S_IFMT) == S_IFREG else { close(finalFD); throw ToolFailure.preDispatch(status: "conflict", summary: "exec identity mismatch (not regular file)") }
        if (st.st_mode & 0o002) != 0 || (st.st_mode & 0o020) != 0 { close(finalFD); throw ToolFailure.preDispatch(status: "conflict", summary: "exec identity mismatch (writable)") }
        let uid = getuid()
        guard st.st_uid == 0 || st.st_uid == uid else { close(finalFD); throw ToolFailure.preDispatch(status: "conflict", summary: "exec identity mismatch (owner)") }
        guard (st.st_mode & 0o111) != 0 else { close(finalFD); throw ToolFailure.preDispatch(status: "conflict", summary: "exec identity mismatch (not executable)") }
        let size = UInt64(st.st_size)
        guard size <= 64*1024*1024 else { close(finalFD); throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "executable too large") }
        let contentSHA: String
        do { contentSHA = try NativeToolExecutor.sha256Hex(fd: finalFD) } catch { close(finalFD); throw ToolFailure.preDispatch(status: "conflict", summary: "exec identity mismatch (hash failed)") }
        let dev = UInt64(st.st_dev), ino = UInt64(st.st_ino)
        let computedDigest = NativeToolExecutor.sha256Hex(of: "\(resolvedPath)\n\(dev)\n\(ino)\n\(size)\n\(contentSHA)")
        guard computedDigest == expectedDigest else { close(finalFD); throw ToolFailure.preDispatch(status: "conflict", summary: "exec identity mismatch (digest mismatch)") }
        // Lift above stdio and make inheritable for /proc/self/fd exec
        let lifted = fcntl(finalFD, F_DUPFD, 3)
        close(finalFD)
        guard lifted >= 0 else { throw ToolFailure.preDispatch(status: "failed", summary: "exec fd lift failed") }
        // Clear CLOEXEC so child can exec via /proc/self/fd
        let flags = fcntl(lifted, F_GETFD)
        if flags >= 0 { _ = fcntl(lifted, F_SETFD, flags & ~FD_CLOEXEC) }
        let execPath = "/proc/self/fd/\(lifted)"

        // Cwd revalidation (anchored at workspace root, resolve symlinks with containment)
        var cwdFD: Int32? = nil
        if let cwd = args.cwd {
            guard let root = resolver.workspaceRoot else { close(lifted); throw ToolFailure.preDispatch(status: "conflict", summary: "exec identity mismatch (cwd no root)") }
            let rootPath = root.path.string
            let rootFD2 = rootPath.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard rootFD2 >= 0 else { close(lifted); throw ToolFailure.preDispatch(status: "conflict", summary: "exec identity mismatch (cwd root unavailable)") }
            defer { close(rootFD2) }
            var st2 = stat()
            guard fstat(rootFD2, &st2) == 0, UInt64(st2.st_dev) == root.device, UInt64(st2.st_ino) == root.inode else { close(lifted); throw ToolFailure.preDispatch(status: "conflict", summary: "exec identity mismatch (cwd root changed)") }
            var dirFD2: Int32 = -1
            // Use a dup so we don't close rootFD2
            dirFD2 = fcntl(rootFD2, F_DUPFD, 3)
            guard dirFD2 >= 0 else { close(lifted); throw ToolFailure.preDispatch(status: "failed", summary: "cwd fd dup failed") }
            var cwdHops = 0
            var cwdStack: [String] = []
            var cwdComps = byteSplit(cwd).filter { !$0.isEmpty }
            var j = 0
            var resolvedCwdFD = dirFD2
            var failed = false
            while j < cwdComps.count {
                let comp = cwdComps[j]
                if comp == "." { j += 1; continue }
                if comp == ".." {
                    // Pop past root is fail-closed (cwd escape)
                    guard cwdStack.popLast() != nil else { failed = true; break }
                    let parent = openat(resolvedCwdFD, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                    if parent < 0 { failed = true; break }
                    close(resolvedCwdFD); resolvedCwdFD = parent; j += 1; continue
                }
                let next = comp.withCString { openat(resolvedCwdFD, $0, O_RDONLY | O_NOFOLLOW | O_DIRECTORY) }
                if next >= 0 {
                    close(resolvedCwdFD); resolvedCwdFD = next; cwdStack.append(comp); j += 1; continue
                }
                var target2 = [CChar](repeating: 0, count: 4097)
                let n2 = comp.withCString { readlinkat(resolvedCwdFD, $0, &target2, 4096) }
                if n2 <= 0 { failed = true; break }
                cwdHops += 1; if cwdHops > 40 { failed = true; break }
                target2[n2] = 0
                let linkTarget = String(cString: target2)
                if linkTarget.utf8.first == 0x2F {
                    // Absolute symlink must re-enter workspace root
                    close(resolvedCwdFD)
                    resolvedCwdFD = fcntl(rootFD2, F_DUPFD, 3)
                    if resolvedCwdFD < 0 { failed = true; break }
                    // Containment by boundary-exact prefix: the target must
                    // be the root itself or stay beneath it (a plain
                    // hasPrefix would admit "/a/bc" for root "/a/b"). The
                    // tail is then walked relatively from the root FD, so
                    // containment holds structurally; the dev/ino check
                    // below still closes any residual mismatch.
                    guard linkTarget == rootPath || linkTarget.hasPrefix(rootPath + "/") else { failed = true; break }
                    let tailPart = linkTarget == rootPath ? "" : String(linkTarget.dropFirst(rootPath.count + 1))
                    cwdStack.removeAll()
                    cwdComps = byteSplit(tailPart).filter({ !$0.isEmpty }) + Array(cwdComps[(j+1)...]); j = 0
                    cwdHops += 1; if cwdHops > 40 { failed = true; break }
                } else {
                    var tail = byteSplit(linkTarget).filter({ !$0.isEmpty }) + Array(cwdComps[(j+1)...])
                    var newStack = cwdStack
                    // Walk leading ".." with single ownership: cur starts
                    // aliased to resolvedCwdFD (unowned); each successful
                    // pop closes the previous fd exactly once.
                    var cur: Int32 = resolvedCwdFD
                    var curOwned = false
                    var popFailed = false
                    while let first = tail.first, first == ".." {
                        guard newStack.popLast() != nil else { popFailed = true; break }
                        let parent = openat(cur, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                        if parent < 0 { popFailed = true; break }
                        if curOwned { close(cur) } else { close(resolvedCwdFD) }
                        cur = parent; curOwned = true; tail.removeFirst()
                    }
                    if popFailed {
                        // Ownership rule: cur is live iff curOwned (the
                        // original resolvedCwdFD was already closed on the
                        // first pop). Invalidate the dead reference so the
                        // shared failure epilogue below can never double-close
                        // it (close(-1) is a harmless no-op).
                        if curOwned { close(cur); resolvedCwdFD = -1 }
                        failed = true; break
                    }
                    cwdComps = tail; cwdStack = newStack
                    if curOwned { resolvedCwdFD = cur }
                    j = 0
                }
            }
            if failed { close(resolvedCwdFD); close(lifted); throw ToolFailure.preDispatch(status: "conflict", summary: "exec identity mismatch (cwd)") }
            // Verify dev/ino matches expected if provided
            var st3 = stat()
            guard fstat(resolvedCwdFD, &st3) == 0 else { close(resolvedCwdFD); close(lifted); throw ToolFailure.preDispatch(status: "conflict", summary: "exec identity mismatch (cwd fstat)") }
            if let expected = expectedCwd, (UInt64(st3.st_dev) != expected.device || UInt64(st3.st_ino) != expected.inode) {
                close(resolvedCwdFD); close(lifted); throw ToolFailure.preDispatch(status: "conflict", summary: "exec identity mismatch (cwd identity mismatch)")
            }
            let held = fcntl(resolvedCwdFD, F_DUPFD, 3)
            close(resolvedCwdFD)
            guard held >= 0 else { close(lifted); throw ToolFailure.preDispatch(status: "failed", summary: "cwd fd lift failed") }
            let cflags = fcntl(held, F_GETFD)
            if cflags >= 0 { _ = fcntl(held, F_SETFD, cflags & ~FD_CLOEXEC) }
            // Actually cwdFD should be inheritable? For fchdir, it needs to be open in child, but not necessarily CLOEXEC cleared? We clear for consistency.
            cwdFD = held
        } else if let expected = expectedCwd {
            // No cwd in args: the workspace root IS the cwd (plan: omitted
            // ⇒ root, the only way to name it). Verify its identity AND pin
            // it — the child must not inherit an arbitrary process cwd.
            guard let root = resolver.workspaceRoot else { close(lifted); throw ToolFailure.preDispatch(status: "conflict", summary: "exec identity mismatch (cwd)") }
            if root.device != expected.device || root.inode != expected.inode {
                close(lifted); throw ToolFailure.preDispatch(status: "conflict", summary: "exec identity mismatch (cwd root mismatch)")
            }
            let rootPath = root.path.string
            let pinned: Int32 = rootPath.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard pinned >= 0 else { close(lifted); throw ToolFailure.preDispatch(status: "conflict", summary: "exec identity mismatch (cwd root unavailable)") }
            var rst = stat()
            guard fstat(pinned, &rst) == 0, UInt64(rst.st_dev) == expected.device, UInt64(rst.st_ino) == expected.inode else {
                close(pinned); close(lifted); throw ToolFailure.preDispatch(status: "conflict", summary: "exec identity mismatch (cwd root changed)")
            }
            let heldRoot = fcntl(pinned, F_DUPFD, 3)
            close(pinned)
            guard heldRoot >= 0 else { close(lifted); throw ToolFailure.preDispatch(status: "failed", summary: "cwd fd lift failed") }
            let rflags = fcntl(heldRoot, F_GETFD)
            if rflags >= 0 { _ = fcntl(heldRoot, F_SETFD, rflags & ~FD_CLOEXEC) }
            cwdFD = heldRoot
        }

        return Verified(fd: lifted, execPath: execPath, cwdFD: cwdFD, resolvedPath: resolvedPath)
    }

    public func run(
        args: ExecArguments,
        approvedDigest: String? = nil,
        approvedCwdIdentity: (device: UInt64, inode: UInt64)? = nil,
        timeout: TimeInterval = Double(ExecArguments.defaultTimeoutSecs)
    ) throws -> Result {
#if !canImport(Glibc)
        // M2-C C3: the /proc/self/fd FD-binding path is Linux-only and
        // qualified there. Refuse closed on other platforms rather than
        // silently falling back to a pathname exec (no TOCTOU-safe spawn
        // exists without /proc/self/fd or /dev/fd).
        if approvedDigest != nil {
            throw ToolFailure.preDispatch(status: "failed", summary: "exec requires Linux (/proc/self/fd unavailable)")
        }
#endif
        let startNanos = NativeToolExecutor.monotonicNanos()
        var execFD: Int32? = nil
        var execPathForSpawn: String? = nil
        var cwdFD: Int32? = nil
        var resolvedPathForArgv0: String? = nil
        defer {
            if let fd = execFD { close(fd) }
            if let fd = cwdFD { close(fd) }
        }
        if let expectedDigest = approvedDigest {
            let verified = try revalidateAndOpen(args: args, expectedDigest: expectedDigest, expectedCwd: approvedCwdIdentity)
            execFD = verified.fd
            execPathForSpawn = verified.execPath
            cwdFD = verified.cwdFD
            resolvedPathForArgv0 = verified.resolvedPath
        } else if let cwd = args.cwd {
            // C1 path without approvedDigest: simple cwd walk
            guard let root = resolver.workspaceRoot else {
                throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "no workspace root for exec cwd")
            }
            let rootPath = root.path.string
            let rootFD = rootPath.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard rootFD >= 0 else { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "workspace root unavailable") }
            defer { close(rootFD) }
            var st = stat()
            guard fstat(rootFD, &st) == 0, UInt64(st.st_dev) == root.device, UInt64(st.st_ino) == root.inode else {
                throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "workspace root replaced")
            }
            var dirFD = rootFD
            for comp in byteSplit(cwd).filter({ !$0.isEmpty }) {
                if comp == "." { continue }
                if comp == ".." { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "parent component in cwd") }
                let next = comp.withCString { openat(dirFD, $0, O_RDONLY | O_NOFOLLOW | O_DIRECTORY) }
                guard next >= 0 else { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "cwd component \(comp): \(String(cString: strerror(errno)))") }
                if dirFD != rootFD { close(dirFD) }
                dirFD = next
            }
            let held = fcntl(dirFD, F_DUPFD, 3)
            if dirFD != rootFD { close(dirFD) }
            guard held >= 0 else { throw ToolFailure.preDispatch(status: "failed", summary: "cwd fd lift failed") }
            cwdFD = held
        }

        var childEnv = Self.baseEnv
        for (k, v) in args.env {
            if ExecEnvPolicy.isDenied(key: k) {
                throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "env key \(k) is denied")
            }
            childEnv[k] = v
        }

        let stdoutCap = 32 * 1024 * 1024
        let stderrCap = 32 * 1024 * 1024
        // argv0 is the resolved path when we revalidated, otherwise the requested executable
        let displayExe = resolvedPathForArgv0 ?? args.executable
        var argvForSpawn = args.argv
        if !argvForSpawn.isEmpty { argvForSpawn[0] = displayExe }

        let result: NativeToolExecutor.BoundedRunResult
        do {
            // Use F_DUPFD-lifted execPath when we have a verified FD, otherwise direct path
            let spawnPath = execPathForSpawn ?? args.executable
            // When using /proc/self/fd, the fd must stay open until exec; runBounded will dup it
            // via F_DUPFD again, so we need to keep execFD open until after fork. Pass the fd
            // as execPath and let runBounded handle the lifecycle — but we already lifted it,
            // so we just pass the path and keep the fd open until runBounded returns (defer above).
            // To ensure the fd survives until exec, we must not close it before fork; runBounded
            // will not close the fd we pass as execPath's backing fd, it only uses the path string.
            // So we keep execFD open until after runBounded.
            result = try NativeToolExecutor.runBounded(
                executablePath: displayExe,
                args: Array(argvForSpawn.dropFirst()),
                stdoutCap: stdoutCap,
                stderrCap: stderrCap,
                timeout: timeout,
                env: childEnv,
                cwdFD: cwdFD,
                execPath: execPathForSpawn,
                useSession: true)
        } catch {
            throw error
        }

        let durationMs = (NativeToolExecutor.monotonicNanos() - startNanos) / 1_000_000
        return Result(
            stdout: result.stdout, stderr: result.stderr, exitStatus: result.status,
            truncated: result.truncated, timedOut: result.timedOut,
            discardedStdoutBytes: result.stdoutDiscarded,
            discardedStderrBytes: result.stderrDiscarded,
            durationMs: durationMs)
    }
}
