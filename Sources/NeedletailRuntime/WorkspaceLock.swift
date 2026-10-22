import Foundation
import NeedletailCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// B1 nonblocking workspace lock at `.needletail/lock`.
/// Private workspace lock, flock LOCK_NB, one lock per mutating batch,
/// retained through the last commit, contention fails before mutation.
public struct WorkspaceLock: Sendable {
    public static let lockDirName = ".needletail"
    public static let lockFileName = "lock"

    /// Acquire the workspace lock nonblocking. Returns a retained fd that
    /// must be closed to release. Throws StoreError.integrity on failure
    /// or contention (typed `failed` in executor).
    public static func acquire(workspace: WorkspaceResolver.PinnedRoot) throws -> Int32 {
        // Revalidate workspace root before each lock acquisition
        let wsFD = try WorkspaceResolver(workspace: workspace.path, readRoots: []).validatedWorkspaceFD()
        defer { close(wsFD) }

        // Ensure .needletail directory exists safely, not via unguarded path
        let dirFD = try ensureLockDirectory(workspaceFD: wsFD)

        // Open lock file (create if needed, 0600) and try nonblocking flock
        let lockFD = lockDirName.withCString { _ in
            // Actually we need to open "lock" inside dirFD
            "lock".withCString { name in
                openat(dirFD, name, O_RDWR | O_CREAT | O_CLOEXEC, mode_t(0o600))
            }
        }
        // Close dirFD after opening lock file
        close(dirFD)
        guard lockFD >= 0 else {
            throw StoreError.integrity("cannot open lock file: \(String(cString: strerror(errno)))")
        }
        // Ensure 0600
        _ = fchmod(lockFD, mode_t(0o600))
        #if canImport(Glibc)
        let ret = flock(lockFD, LOCK_EX | LOCK_NB)
        #else
        let ret = flock(lockFD, LOCK_EX | LOCK_NB)
        #endif
        if ret != 0 {
            let err = errno
            close(lockFD)
            if err == EWOULDBLOCK || err == EAGAIN {
                throw StoreError.integrity("workspace lock contention (busy)")
            }
            throw StoreError.integrity("flock failed: \(String(cString: strerror(err)))")
        }
        return lockFD
    }

    public static func release(_ fd: Int32) {
        if fd >= 0 {
            #if canImport(Glibc)
            flock(fd, LOCK_UN)
            #else
            flock(fd, LOCK_UN)
            #endif
            close(fd)
        }
    }

    private static func ensureLockDirectory(workspaceFD: Int32) throws -> Int32 {
        // Try to open existing .needletail with O_DIRECTORY|O_NOFOLLOW
        let fd = ".needletail".withCString { name in
            openat(workspaceFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        if fd >= 0 {
            return fd
        }
        let err = errno
        if err != ENOENT {
            throw StoreError.integrity("lock dir open failed: \(String(cString: strerror(err)))")
        }
        // Create directory safely via mkdirat
        let ret = ".needletail".withCString { name in
            mkdirat(workspaceFD, name, mode_t(0o700))
        }
        if ret != 0 && errno != EEXIST {
            throw StoreError.integrity("cannot create .needletail: \(String(cString: strerror(errno)))")
        }
        // Re-open and verify
        let fd2 = ".needletail".withCString { name in
            openat(workspaceFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd2 >= 0 else {
            throw StoreError.integrity("lock dir re-open failed: \(String(cString: strerror(errno)))")
        }
        var st = stat()
        guard fstat(fd2, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            close(fd2)
            throw StoreError.integrity(".needletail is not a directory")
        }
        // Ensure 0700
        _ = fchmod(fd2, mode_t(0o700))
        return fd2
    }
}
