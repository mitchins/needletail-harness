import Foundation
import NeedletailCore
import SystemPackage
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// M2-D D2: production undo evidence + compensation over the workspace.
///
/// Two seams, both fail-closed and both descriptor-relative (O_NOFOLLOW on
/// every open, revalidated workspace root per traversal — the same
/// containment story as the native executor):
///
/// - `FilesystemUndoValidator`: point-in-time current-file evidence for
///   preflight. Never throws: every failure mode becomes an unreadable
///   observation, so preflight can only refuse.
/// - `FilesystemUndoApplier`: exactly one filesystem inverse with
///   commit-time revalidation. The outcome tells the transition exactly
///   what happened — no ambiguity is hidden, and a second call for the
///   same inverse never happens (the journal owns idempotency; the
///   applier owns honesty).
///
/// Both are conservative by construction: symlinks, special files,
/// out-of-root paths, root mismatches and identity/hash/mode drift all
/// refuse (validator) or refuse-before-mutation (applier) without touching
/// unrelated data.
public struct FilesystemUndoValidator: UndoFileValidator, Sendable {
    private let resolver: WorkspaceResolver

    public init(resolver: WorkspaceResolver) {
        self.resolver = resolver
    }

    public func validate(members: [UndoValidationNeed]) async -> [UndoFileObservation] {
        members.map { observe($0) }
    }

    private func observe(_ need: UndoValidationNeed) -> UndoFileObservation {
        func unreadable(device: UInt64 = 0, inode: UInt64 = 0, _ reason: String) -> UndoFileObservation {
            UndoFileObservation(
                inverseID: need.inverseID, device: device, inode: inode,
                size: -1, hash: "", mode: "", readable: false, denyReason: reason)
        }
        guard undoPathContained(need.path) else {
            return unreadable("path escapes workspace; refusing")
        }
        let dirFD: Int32
        do {
            dirFD = try resolver.validatedWorkspaceFD()
        } catch {
            return unreadable("workspace unavailable: \(error)")
        }
        defer { close(dirFD) }
        let fd: Int32
        do {
            fd = try resolver.openRelative(need.path, from: dirFD, flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        } catch {
            return unreadable(Self.cause(error))
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            return unreadable("stat failed: \(String(cString: strerror(errno)))")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            return unreadable(device: UInt64(st.st_dev), inode: UInt64(st.st_ino), "not a regular file")
        }
        let bytes: Data
        do {
            bytes = try NativeToolExecutor.readBoundedEdit(fd: fd)
        } catch let e as StoreError {
            if case .quotaExceeded = e {
                return unreadable(device: UInt64(st.st_dev), inode: UInt64(st.st_ino), "over size limit")
            }
            return unreadable(device: UInt64(st.st_dev), inode: UInt64(st.st_ino), "read failed: \(e)")
        } catch {
            return unreadable(device: UInt64(st.st_dev), inode: UInt64(st.st_ino), "read failed: \(error)")
        }
        var after = stat()
        guard fstat(fd, &after) == 0 else {
            return unreadable("re-stat refused")
        }
        guard after.st_dev == st.st_dev, after.st_ino == st.st_ino,
              after.st_size == st.st_size, Int(after.st_size) == bytes.count
        else {
            return unreadable(
                device: UInt64(st.st_dev), inode: UInt64(st.st_ino),
                "changed during validation read")
        }
        return UndoFileObservation(
            inverseID: need.inverseID,
            device: UInt64(st.st_dev), inode: UInt64(st.st_ino),
            size: bytes.count, hash: NativeToolExecutor.sha256Hex(bytes),
            mode: String(format: "%o", st.st_mode & 0o7777),
            readable: true)
    }

    private static func cause(_ error: Error) -> String {
        let text = "\(error)"
        if text.contains("symlink") { return "symlink encountered (no-follow)" }
        if text.contains("ENOENT") || text.contains("No such file") { return "removed" }
        return "open refused: \(error)"
    }
}

/// M2-D D2: production inverse applier. Exactly one inverse per call:
///
/// restore — revalidates the live file against the recorded post-commit
///   expectation (identity + content + mode) on a freshly opened fd,
///   fetches the verified preimage (or empty for proven-empty originals),
///   installs it via same-dir tmp + atomic rename under the preserved mode,
///   then post-verifies the installed bytes. Directories are never touched.
/// removeCreated — revalidates the exact created identity and unlinks it
///   (never recursive, never a directory).
///
/// No shell, no `git`, no fuzzy reverse patch: compensation only, and only
/// when the live file is provably the file the ledger recorded.
public struct FilesystemUndoApplier: UndoInverseApplier, Sendable {
    private let resolver: WorkspaceResolver
    private let store: any SessionStore
    private let session: SessionID
    private let writer: WriterIdentity

    public init(
        resolver: WorkspaceResolver, store: any SessionStore,
        session: SessionID, writer: WriterIdentity
    ) {
        self.resolver = resolver
        self.store = store
        self.session = session
        self.writer = writer
    }

    public func apply(_ inverse: UndoInverse) async -> UndoInverseOutcome {
        guard undoPathContained(inverse.path) else {
            return .refused(reason: "\(inverse.path): path escapes workspace; refusing")
        }
        guard resolver.workspaceRoot?.path.string == inverse.grantedRoot else {
            return .refused(reason: "\(inverse.path): granting root mismatch (expected \(inverse.grantedRoot)); refusing cross-workspace inverse")
        }
        let dirFD: Int32
        do {
            dirFD = try resolver.validatedWorkspaceFD()
        } catch {
            return .failed(error: "workspace unavailable: \(error)", possiblyMutated: false)
        }
        defer { close(dirFD) }
        switch inverse.kind {
        case .restore(let digest, let expect):
            return applyRestore(
                inverse: inverse, digest: digest, expect: expect, dirFD: dirFD)
        case .restoreMissing:
            // The preimage for this restore does not exist (never a
            // proven-empty original — that carries an empty digest with
            // `emptyOriginal`). There are no bytes to restore, so the
            // inverse never runs: refuse without touching the file.
            return .refused(reason: "\(inverse.path): preimage missing with no empty-original proof; failing closed")
        case .removeCreated(let expect):
            return applyRemoveCreated(inverse: inverse, expect: expect, dirFD: dirFD)
        }
    }

    // MARK: - Restore

    /// Commit gate: re-opens `fileName` under `parentFD` and verifies the
    /// live file still equals the held-open state (`held`, itself already
    /// verified against `expect`) in BOTH identity and current content
    /// hash. Returns nil when the commit may proceed; otherwise returns
    /// the exact outcome to report. Nothing is mutated on any return path
    /// (clean failures and refusals alike).
    ///
    /// The re-open (never the held fd: an open descriptor keeps its
    /// inode) closes the replacement/deletion window down to the
    /// re-read→commit gap, which user space cannot close further; a
    /// non-cooperating writer racing exactly there is a documented
    /// residual. O_NONBLOCK throughout so a swapped-in FIFO/special file
    /// fails closed instead of blocking.
    static func reverifyCommitTarget(
        parentFD: Int32, fileName: String, held: stat, expect: UndoFileState
    ) -> UndoInverseOutcome? {
        let fd: Int32 = fileName.withCString { name in
            openat(parentFD, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else {
            return .refused(reason: "commit revalidation: target unavailable (\(String(cString: strerror(errno)))); refusing")
        }
        defer { close(fd) }
        var fresh = stat()
        guard fstat(fd, &fresh) == 0,
              (fresh.st_mode & S_IFMT) == S_IFREG,
              fresh.st_dev == held.st_dev, fresh.st_ino == held.st_ino else {
            return .refused(reason: "commit revalidation: target replaced; refusing — no overwrite of later work")
        }
        let current: Data
        do {
            current = try NativeToolExecutor.readBoundedEdit(fd: fd)
        } catch {
            return .failed(error: "commit revalidation read failed: \(error)", possiblyMutated: false)
        }
        guard NativeToolExecutor.sha256Hex(current) == expect.hash else {
            return .refused(reason: "commit revalidation: content changed (hash mismatch); refusing — no overwrite of later work")
        }
        return nil
    }

    private func applyRestore(
        inverse: UndoInverse, digest: String, expect: UndoFileState, dirFD: Int32
    ) -> UndoInverseOutcome {
        // Commit-time revalidation on a FRESH open (never the validator's
        // observation): identity, content and mode must equal the recorded
        // post-commit expectation, or nothing runs.
        let fd: Int32
        do {
            fd = try resolver.openRelative(inverse.path, from: dirFD, flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        } catch {
            return .refused(reason: "\(inverse.path): revalidation open refused (\(error)); nothing mutated")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            return .refused(reason: "\(inverse.path): not a regular file at commit; nothing mutated")
        }
        guard UInt64(st.st_dev) == expect.device, UInt64(st.st_ino) == expect.inode else {
            return .refused(reason: "\(inverse.path): identity changed (replaced); refusing — no wrong-file overwrite")
        }
        let currentMode = String(format: "%o", st.st_mode & 0o7777)
        guard currentMode == expect.mode else {
            return .refused(reason: "\(inverse.path): mode changed; refusing")
        }
        let current: Data
        do {
            current = try NativeToolExecutor.readBoundedEdit(fd: fd)
        } catch {
            return .failed(error: "revalidation read failed: \(error)", possiblyMutated: false)
        }
        guard NativeToolExecutor.sha256Hex(current) == expect.hash else {
            return .refused(reason: "\(inverse.path): content changed (hash mismatch); refusing — no overwrite of later work")
        }
        // Verified preimage (hash-checked) or proven-empty.
        let want: Data
        if digest.isEmpty {
            want = Data()
        } else {
            let stored: Data?
            do {
                stored = try store.artifactRecord(session: session, digest: digest)
            } catch {
                return .failed(error: "preimage fetch failed: \(error)", possiblyMutated: false)
            }
            guard let bytes = stored, NativeToolExecutor.sha256Hex(bytes) == digest else {
                return .failed(error: "preimage unavailable or corrupt for \(inverse.path)", possiblyMutated: false)
            }
            want = bytes
        }
        let wantHash = NativeToolExecutor.sha256Hex(want)
        let modeBits: mode_t
        if let restore = inverse.restoreMode, let parsed = UInt32(restore, radix: 8) {
            modeBits = mode_t(parsed & 0o7777)
        } else if inverse.restoreMode == nil {
            modeBits = st.st_mode & 0o7777
        } else {
            return .failed(error: "unparseable restore mode \(inverse.restoreMode ?? "")", possiblyMutated: false)
        }
        let (dirPath, fileName) = NativeToolExecutor.splitParentLeaf(inverse.path)
        let parentFD: Int32
        let ownsParentFD: Bool
        if dirPath.isEmpty || dirPath == "." {
            parentFD = dirFD
            ownsParentFD = false
        } else {
            do {
                parentFD = try resolver.openRelative(dirPath, from: dirFD, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            } catch {
                return .failed(error: "parent unavailable: \(error)", possiblyMutated: false)
            }
            ownsParentFD = true
        }
        defer { if ownsParentFD { close(parentFD) } }
        // Same-dir tmp, checked write, mode preserve, fsync — then a final
        // revalidation of the TARGET NAME immediately before rename (see
        // reverifyCommitTarget): the path is re-opened and both identity
        // AND current content hash must still match. This closes the
        // replacement/deletion window and the same-inode rewrite window
        // down to the re-read→rename gap (one syscall pair wide, user
        // space cannot close it further); a non-cooperating writer racing
        // exactly there is a documented residual.
        let tmpName = "." + UUID().uuidString + ".tmp"
        let tmpFD = tmpName.withCString { name in
            openat(parentFD, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        }
        guard tmpFD >= 0 else {
            return .failed(error: "tmp create failed: \(String(cString: strerror(errno)))", possiblyMutated: false)
        }
        var committed = false
        defer {
            close(tmpFD)
            if !committed {
                _ = tmpName.withCString { unlinkat(parentFD, $0, 0) }
            }
        }
        var offset = 0
        let total = want.count
        while offset < total {
            let n = want.withUnsafeBytes { raw -> Int in
#if canImport(Glibc)
                Glibc.write(tmpFD, raw.baseAddress!.advanced(by: offset), total - offset)
#else
                Darwin.write(tmpFD, raw.baseAddress!.advanced(by: offset), total - offset)
#endif
            }
            if n < 0 {
                if errno == EINTR { continue }
                return .failed(error: "tmp write failed: \(String(cString: strerror(errno)))", possiblyMutated: false)
            }
            if n == 0 {
                return .failed(error: "tmp short write", possiblyMutated: false)
            }
            offset += n
        }
        guard fchmod(tmpFD, modeBits) == 0, fsync(tmpFD) == 0 else {
            return .failed(error: "tmp mode/sync failed: \(String(cString: strerror(errno)))", possiblyMutated: false)
        }
        // Final revalidation of the TARGET NAME immediately before rename:
        // re-open the path (never trust the held fd — an open descriptor
        // keeps its inode, so fstat on it cannot detect replacement or
        // deletion) and require both the just-verified identity AND the
        // current content hash. O_NONBLOCK for the swapped-in-FIFO case.
        // Any divergence aborts with the target untouched.
        if let stop = Self.reverifyCommitTarget(parentFD: parentFD, fileName: fileName, held: st, expect: expect) {
            return stop
        }
        let renameRet = fileName.withCString { old in
            tmpName.withCString { tmp in
                renameat(parentFD, tmp, parentFD, old)
            }
        }
        guard renameRet == 0 else {
            return .failed(error: "rename failed: \(String(cString: strerror(errno)))", possiblyMutated: false)
        }
        committed = true
        // Directory sync: the rename entry is durable only after the
        // parent syncs. A failure here does not undo the rename — it is
        // reported in the receipt (same contract as the executor), never
        // hidden, never converted into a false unknown.
        var durabilityNote = ""
        if fsync(parentFD) != 0 {
            durabilityNote = " (directory sync failed: \(String(cString: strerror(errno))); durability weakened)"
        }
        // Post-verify the installed bytes: open fresh, hash must equal the
        // preimage hash. A post-commit read failure is AMBIGUOUS (the rename
        // succeeded, the proof did not) — unknown, hold, never a claim.
        let verifyFD: Int32 = fileName.withCString { name in
            openat(parentFD, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard verifyFD >= 0 else {
            return .failed(error: "post-commit open failed (rename succeeded, unverifiable)", possiblyMutated: true)
        }
        defer { close(verifyFD) }
        let installed: Data
        do {
            installed = try NativeToolExecutor.readBoundedEdit(fd: verifyFD)
        } catch {
            return .failed(error: "post-commit read failed (rename succeeded, unverifiable)", possiblyMutated: true)
        }
        guard NativeToolExecutor.sha256Hex(installed) == wantHash else {
            return .failed(error: "post-commit hash mismatch (rename succeeded, content unverified)", possiblyMutated: true)
        }
        return .applied(detail: "restored \(inverse.path) (\(installed.count) bytes)\(durabilityNote)")
    }

    // MARK: - Remove created

    private func applyRemoveCreated(
        inverse: UndoInverse, expect: UndoFileState, dirFD: Int32
    ) -> UndoInverseOutcome {
        let fd: Int32
        do {
            fd = try resolver.openRelative(inverse.path, from: dirFD, flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        } catch {
            return .refused(reason: "\(inverse.path): revalidation open refused (\(error)); nothing mutated")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            return .refused(reason: "\(inverse.path): stat failed; nothing mutated")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            // Directories (or anything non-regular) are NEVER removed.
            return .refused(reason: "\(inverse.path): not a regular file; refusing delete")
        }
        guard UInt64(st.st_dev) == expect.device, UInt64(st.st_ino) == expect.inode else {
            return .refused(reason: "\(inverse.path): identity changed (replaced); refusing — no wrong-file delete")
        }
        guard String(format: "%o", st.st_mode & 0o7777) == expect.mode else {
            return .refused(reason: "\(inverse.path): mode changed; refusing")
        }
        let current: Data
        do {
            current = try NativeToolExecutor.readBoundedEdit(fd: fd)
        } catch {
            return .failed(error: "revalidation read failed: \(error)", possiblyMutated: false)
        }
        guard NativeToolExecutor.sha256Hex(current) == expect.hash else {
            return .refused(reason: "\(inverse.path): content changed (hash mismatch); refusing — no delete of later work")
        }
        let (dirPath, fileName) = NativeToolExecutor.splitParentLeaf(inverse.path)
        let parentFD: Int32
        let ownsParentFD: Bool
        if dirPath.isEmpty || dirPath == "." {
            parentFD = dirFD
            ownsParentFD = false
        } else {
            do {
                parentFD = try resolver.openRelative(dirPath, from: dirFD, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            } catch {
                return .failed(error: "parent unavailable: \(error)", possiblyMutated: false)
            }
            ownsParentFD = true
        }
        defer { if ownsParentFD { close(parentFD) } }
        // Re-check the NAME (not the held fd) one last time before unlink:
        // re-open with no-follow and require the just-verified identity
        // AND the current content hash. O_NONBLOCK for the swapped-in-FIFO
        // case. Any divergence aborts with nothing unlinked.
        if let stop = Self.reverifyCommitTarget(parentFD: parentFD, fileName: fileName, held: st, expect: expect) {
            return stop
        }
        guard fileName.withCString({ unlinkat(parentFD, $0, 0) }) == 0 else {
            if errno == ENOENT {
                return .refused(reason: "\(inverse.path): already removed; nothing mutated")
            }
            return .failed(error: "unlink failed: \(String(cString: strerror(errno)))", possiblyMutated: false)
        }
        // Verify the unlink landed: the name must be gone. (If it somehow
        // persists, the mutation state is unclear — unknown, hold.)
        // O_NONBLOCK for the swapped-in-FIFO case.
        let probe: Int32 = fileName.withCString { name in
            openat(parentFD, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        if probe >= 0 {
            close(probe)
            return .failed(error: "unlink unverifiable (name persists)", possiblyMutated: true)
        }
        // Directory sync: the unlink entry is durable only after the parent
        // syncs. A failure here does not resurrect the name — it is
        // reported in the receipt (same contract as the executor), never
        // hidden, never converted into a false unknown.
        var detail = "removed created file \(inverse.path)"
        if fsync(parentFD) != 0 {
            detail += " (directory sync failed: \(String(cString: strerror(errno))); durability weakened)"
        }
        return .applied(detail: detail)
    }
}
