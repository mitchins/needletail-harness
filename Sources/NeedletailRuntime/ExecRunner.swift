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

/// C1 supervised exec runner — plan REV12 §3.5/§3.6 (spawn-level, no actor
/// integration). Wraps the qualified bounded process mechanism with
/// process-group semantics (setsid), three-stage escalation (INT→TERM→KILL
/// with group signaling when useSession), concurrent draining, bounded caps,
/// waitid(WNOWAIT) pre-reap probe, ECHILD handling and /proc pgrp liveness
/// probe (live!=Z). Remaining deferred: §3.4 symlink interior, spill leases,
/// per-inode cache, boot identity, exec-error pipe, argv0/execPath split,
/// artifact preparation — C2 refinements; this slice focuses on the core
/// process lifecycle that PROC-01/06 certify store-free.

public struct ExecRunner: Sendable {
    public struct Result: Sendable {
        public var stdout: Data
        public var stderr: Data
        public var exitStatus: Int32
        public var truncated: Bool
        public var timedOut: Bool
        public var discardedStdoutBytes: Int
        public var discardedStderrBytes: Int
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

    public func run(
        args: ExecArguments,
        approvedDigest: String? = nil,
        timeout: TimeInterval = Double(ExecArguments.defaultTimeoutSecs)
    ) throws -> Result {
        // C1 store-free runner: executable identity is bound by C0 (approval/
        // reservation digest); this slice does not yet re-resolve and hash at
        // spawn. approvedDigest is accepted for forward-compat but not verified
        // here — C2 will re-run the anchored walk and compare. No silent
        // substitution is claimed beyond the C0 binding for this slice.
        let startNanos = NativeToolExecutor.monotonicNanos()

        // Resolve cwd if present
        var cwdFD: Int32? = nil
        if let cwd = args.cwd {
            // Cwd is workspace-relative, validated shape-only; existence/identity bound here.
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
            // For C1, cwd symlink targets that escape the root are .cwd failures.
            for comp in byteSplit(cwd).filter({ !$0.isEmpty }) {
                if comp == "." { continue }
                if comp == ".." { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "parent component in cwd") }
                let next = comp.withCString { openat(dirFD, $0, O_RDONLY | O_NOFOLLOW | O_DIRECTORY) }
                guard next >= 0 else { throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "cwd component \(comp): \(String(cString: strerror(errno)))") }
                if dirFD != rootFD { close(dirFD) }
                dirFD = next
            }
            // Hold the cwd fd for the child; dup it to keep it open after we close rootFD.
            // For the spawn, we need an fd that survives; dup it above stdio.
            let held = fcntl(dirFD, F_DUPFD, 3)
            if dirFD != rootFD { close(dirFD) }
            guard held >= 0 else { throw ToolFailure.preDispatch(status: "failed", summary: "cwd fd lift failed") }
            cwdFD = held
        }

        // Prepare env: base + overlay, deny-set already checked at validation, re-check here.
        var childEnv = Self.baseEnv
        for (k, v) in args.env {
            if ExecEnvPolicy.isDenied(key: k) {
                if let fd = cwdFD { close(fd) }
                throw ToolFailure.preDispatch(status: "invalid-arguments", summary: "env key \(k) is denied")
            }
            childEnv[k] = v
        }

        // C1: approvedDigest verification deferred — see docstring above.
        // The executable path is used directly; the C2 slice will re-resolve
        // via the anchored walk, qualify, hash and compare before exec.
        _ = approvedDigest // accepted for API compat, verified in C2

        let stdoutCap = 32 * 1024 * 1024
        let stderrCap = 32 * 1024 * 1024
        let result: NativeToolExecutor.BoundedRunResult
        do {
            result = try NativeToolExecutor.runBounded(
                executablePath: args.executable,
                args: Array(args.argv.dropFirst()),
                stdoutCap: stdoutCap,
                stderrCap: stderrCap,
                timeout: timeout,
                env: childEnv,
                cwdFD: cwdFD,
                execPath: nil,
                useSession: true)
        } catch {
            if let fd = cwdFD { close(fd) }
            throw error
        }
        if let fd = cwdFD { close(fd) }

        let durationMs = (NativeToolExecutor.monotonicNanos() - startNanos) / 1_000_000
        return Result(
            stdout: result.stdout, stderr: result.stderr, exitStatus: result.status,
            truncated: result.truncated, timedOut: result.timedOut,
            discardedStdoutBytes: result.stdoutTruncated ? 0 : 0, discardedStderrBytes: 0,
            durationMs: durationMs)
    }
}
