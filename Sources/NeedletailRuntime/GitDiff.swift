import Foundation
import NeedletailCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// B5 TOOL-10: operator-side `needletail diff` core. NOT a model capability
/// (no `ToolCapabilities` bit; model-invoked `diff` is denied at dispatch
/// validation — `unknown tool diff` — tested).
///
/// Fixed argv, sanitized environment (LANG + TZ ONLY — every `GIT_*`
/// variable is scrubbed by replacing the whole environment), absolute
/// pinned `git` (same provisioning model as rg: absolute path, symlink
/// reject, dev/ino identity, regular, non-writable, root-or-owner,
/// executable, `--version` sanity), fchdir-pinned worktree cwd (no
/// pathname TOCTOU), dirty worktrees supported natively, bounded
/// stdout/stderr with oversized output publishable to a 0600 create-new
/// file. Missing/unexecutable git is a typed denial, never a crash.
public enum GitDiff {
    /// Fixed argv per REV25 §4/B5 (global flags before the subcommand,
    /// diff-level flags after — the SET is fixed and pinned by tests):
    /// `--no-color --no-ext-diff --no-textconv --no-pager
    /// --no-optional-locks` + `diff`.
    public static let fixedArgv = ["--no-pager", "--no-optional-locks", "diff", "--no-color", "--no-ext-diff", "--no-textconv"]
    /// Minimal environment allowlist: LANG + TZ only. The child inherits
    /// nothing else — GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE,
    /// GIT_OBJECT_DIRECTORY, GIT_EXTERNAL_DIFF, GIT_CONFIG_PARAMETERS and
    /// every other ambient variable are scrubbed by construction.
    public static let sanitizedEnv: [String: String] = ["LANG": "C.UTF-8", "TZ": "UTC"]
    public static let maxStdoutBytes = 1 * 1024 * 1024
    public static let maxStderrBytes = 64 * 1024
    public static let defaultTimeoutSeconds: TimeInterval = 120

    public enum Failure: Error, Sendable, Equatable {
        /// No usable git (nil path, PATH lookup miss, absent/unexecutable
        /// pin). The CLI reports this as unavailable; never a crash.
        case missingGit(String)
        /// Deterministic pre-dispatch denial: non-absolute pin, symlink,
        /// replacement, permissions, bad version output, bad workspace.
        case denied(String)
        /// git ran and failed (not-a-repo, bad flags, killed, ...).
        case failed(String)
        case timedOut
    }

    public struct Output: Sendable, Equatable {
        /// Bounded stdout bytes (exactly what git emitted, cut at the cap).
        public let stdout: Data
        /// Bounded stderr bytes.
        public let stderr: Data
        /// True iff stdout hit the cap (caller notes truncation + --output).
        public let truncated: Bool
        public init(stdout: Data, stderr: Data, truncated: Bool) {
            self.stdout = stdout
            self.stderr = stderr
            self.truncated = truncated
        }
    }

    /// Runs `git diff` with cwd pinned to the validated workspace directory.
    /// - Parameters:
    ///   - workspace: directory the diff runs in (must exist, be a real
    ///     directory, not a symlink; held open across the run).
    ///   - gitPath: absolute path to the git executable (nil → missingGit).
    ///   - timeout: wall-clock budget (default 120 s).
    public static func run(workspace: URL, gitPath: String?, timeout: TimeInterval = defaultTimeoutSeconds) throws -> Output {
        let gitFD = try qualifiedGitFD(gitPath: gitPath)
        defer { close(gitFD) }
        let dirFD = try validatedDirFD(workspace: workspace)
        defer { close(dirFD) }
        let gitExec = NativeToolExecutor.fdProcPath(gitFD)
        // Version sanity (presence + shape; no floor — the fixed flags are
        // long-stable and a failure is loud, never silent).
        let version = try NativeToolExecutor.runBounded(
            executablePath: gitExec, args: ["--version"],
            stdoutCap: 4096, stderrCap: 4096, timeout: 10,
            env: sanitizedEnv, cwdFD: dirFD)
        if version.timedOut {
            throw Failure.denied("git version check timed out")
        }
        let versionText = String(data: version.stdout, encoding: .utf8) ?? ""
        guard versionText.hasPrefix("git version") else {
            throw Failure.denied("git version check failed")
        }
        let run = try NativeToolExecutor.runBounded(
            executablePath: gitExec, args: fixedArgv,
            stdoutCap: maxStdoutBytes, stderrCap: maxStderrBytes, timeout: timeout,
            env: sanitizedEnv, cwdFD: dirFD)
        if run.timedOut {
            throw Failure.timedOut
        }
        guard run.status == 0 else {
            let detail = String(data: run.stderr.prefix(512), encoding: .utf8) ?? "exit \(run.status)"
            throw Failure.failed("git diff failed: \(detail)")
        }
        return Output(stdout: run.stdout, stderr: run.stderr, truncated: run.stdoutTruncated)
    }

    // MARK: - Workspace pinning

    static func validatedDirFD(workspace: URL) throws -> Int32 {
        var lst = stat()
        guard lstat(workspace.path, &lst) == 0 else {
            throw Failure.denied("workspace not found: \(workspace.path)")
        }
        if (lst.st_mode & S_IFMT) == S_IFLNK {
            throw Failure.denied("workspace is a symlink: \(workspace.path)")
        }
        let fd = workspace.path.withCString { cstr in
            open(cstr, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else {
            throw Failure.denied("workspace unavailable: \(workspace.path)")
        }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            close(fd)
            throw Failure.denied("workspace is not a directory: \(workspace.path)")
        }
        guard UInt64(st.st_dev) == UInt64(lst.st_dev) && UInt64(st.st_ino) == UInt64(lst.st_ino) else {
            close(fd)
            throw Failure.denied("workspace replaced during qualification")
        }
        return fd
    }

    // MARK: - Git provisioning (same model as rg)

    static func qualifiedGitFD(gitPath: String?) throws -> Int32 {
        guard let git = gitPath else {
            throw Failure.missingGit("git is not provisioned (pass --git ABSOLUTE-PATH)")
        }
        guard git.hasPrefix("/") else {
            throw Failure.denied("git must be an absolute path")
        }
        var lst = stat()
        guard lstat(git, &lst) == 0 else {
            throw Failure.missingGit("git not found at \(git)")
        }
        if (lst.st_mode & S_IFMT) == S_IFLNK {
            throw Failure.denied("git is a symlink")
        }
        let fd = git.withCString { cstr in
            open(cstr, O_RDONLY | O_NOFOLLOW)
        }
        guard fd >= 0 else {
            throw Failure.denied("git open failed (symlink or replaced)")
        }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            close(fd)
            throw Failure.denied("git fstat failed")
        }
        guard UInt64(st.st_dev) == UInt64(lst.st_dev) && UInt64(st.st_ino) == UInt64(lst.st_ino) else {
            close(fd)
            throw Failure.denied("git replaced during qualification")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw Failure.denied("git is not a regular file")
        }
        if (st.st_mode & 0o002) != 0 {
            close(fd)
            throw Failure.denied("git is world-writable")
        }
        if (st.st_mode & 0o020) != 0 {
            close(fd)
            throw Failure.denied("git is group-writable")
        }
        let uid = getuid()
        if st.st_uid != 0 && st.st_uid != uid {
            close(fd)
            throw Failure.denied("git not owned by root or current user")
        }
        if (st.st_mode & 0o111) == 0 {
            close(fd)
            throw Failure.denied("git is not executable")
        }
        // Lift above stdio (kept inheritable: the /proc/self/fd path must
        // resolve inside the child after exec). Failure fails closed.
        if fd >= 0 && fd <= 2 {
            let n = fcntl(fd, F_DUPFD, 3)
            guard n >= 0 else {
                close(fd)
                throw Failure.denied("git fd lift failed")
            }
            close(fd)
            return n
        }
        return fd
    }

    // MARK: - Artifact publication (existing storage pattern)

    /// Writes diff bytes to a 0600 create-new file (never overwrites,
    /// never follows symlinks). Mirrors the session-export artifact
    /// discipline for operator-readable output.
    public static func writeOutput(_ bytes: Data, toFileAtPath path: String) throws {
        let fd = path.withCString { cstr in
            open(cstr, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard fd >= 0 else {
            if errno == EEXIST {
                throw Failure.failed("refusing to overwrite existing output at \(path)")
            }
            throw Failure.failed("output unwritable: \(path)")
        }
        defer { close(fd) }
        var offset = 0
        let total = bytes.count
        while offset < total {
            let n = bytes.withUnsafeBytes { raw -> Int in
                write(fd, raw.baseAddress!.advanced(by: offset), total - offset)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw Failure.failed("output write failed: \(path)")
            }
            if n == 0 { throw Failure.failed("output short write: \(path)") }
            offset += n
        }
        guard fsync(fd) == 0 else {
            throw Failure.failed("output sync failed: \(path)")
        }
    }
}
