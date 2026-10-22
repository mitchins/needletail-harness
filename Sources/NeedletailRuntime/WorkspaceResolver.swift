import SystemPackage
import Foundation
import NeedletailCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// REV25 B1: descriptor-relative workspace resolver with re-open validation.
/// Pins workspace + read roots as (path, dev, ino) at startup, re-opens
/// the configured root path per traversal, fstats the fresh fd and compares
/// dev/ino to pinned identity — mismatch (root replaced, symlink-swapped)
/// → fail closed before any descent — then traverses from the freshly
/// validated fd via openat chain (O_NOFOLLOW on every component).
public struct WorkspaceResolver: Sendable {
    public struct PinnedRoot: Sendable {
        public let path: FilePath
        public let device: UInt64
        public let inode: UInt64
        public let isWorkspace: Bool

        public init(path: FilePath, device: UInt64, inode: UInt64, isWorkspace: Bool) {
            self.path = path
            self.device = device
            self.inode = inode
            self.isWorkspace = isWorkspace
        }
    }

    public let workspaceRoot: PinnedRoot?
    public let readRoots: [PinnedRoot]

    public init(workspace: FilePath?, readRoots: [FilePath]) throws {
        if let ws = workspace {
            self.workspaceRoot = try Self.pin(path: ws, isWorkspace: true)
        } else {
            self.workspaceRoot = nil
        }
        self.readRoots = try readRoots.map { try Self.pin(path: $0, isWorkspace: false) }
    }

    private static func pin(path: FilePath, isWorkspace: Bool) throws -> PinnedRoot {
        // Reject NUL in path
        if path.string.utf8.contains(0) {
            throw StoreError.integrity("root path contains NUL: \(path.string)")
        }
        let fd = path.string.withCString { cstr in
            open(cstr, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else {
            throw StoreError.integrity("root cannot be opened (not a directory or symlink): \(path.string): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            throw StoreError.integrity("root fstat failed: \(path.string)")
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            throw StoreError.integrity("root is not a directory: \(path.string)")
        }
        return PinnedRoot(path: path, device: UInt64(st.st_dev), inode: UInt64(st.st_ino), isWorkspace: isWorkspace)
    }

    /// Re-open and revalidate the pinned root before each traversal.
    /// Returns a fresh fd that the caller must close, or throws if the
    /// root was replaced/symlink-swapped.
    public func validatedWorkspaceFD() throws -> Int32 {
        guard let pinned = workspaceRoot else {
            throw StoreError.integrity("workspace not configured")
        }
        return try revalidatedFD(for: pinned)
    }

    public func revalidatedFD(for pinned: PinnedRoot) throws -> Int32 {
        if pinned.path.string.utf8.contains(0) {
            throw StoreError.integrity("root path contains NUL")
        }
        let fd = pinned.path.string.withCString { cstr in
            open(cstr, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else {
            throw StoreError.integrity("root re-open failed (symlink or replaced): \(pinned.path.string): \(String(cString: strerror(errno)))")
        }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            close(fd)
            throw StoreError.integrity("root revalidated fstat failed: \(pinned.path.string)")
        }
        guard UInt64(st.st_dev) == pinned.device && UInt64(st.st_ino) == pinned.inode else {
            close(fd)
            throw StoreError.integrity("root identity mismatch (replaced): \(pinned.path.string)")
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            close(fd)
            throw StoreError.integrity("root is not a directory after revalidation: \(pinned.path.string)")
        }
        return fd
    }

    /// Descriptor-relative traversal: open `relativePath` (e.g. "a/b/c") relative to `dirFD` via openat chain,
    /// no-follow on every component, byte-exact (no normalization), case-sensitive.
    /// Returns an fd for the final component (caller must close), or throws.
    public func openRelative(_ relativePath: String, from dirFD: Int32, flags: Int32, mode: mode_t = 0) throws -> Int32 {
        // Check NUL byte
        if relativePath.utf8.contains(0) {
            throw StoreError.integrity("path contains NUL: \(relativePath)")
        }
        guard !relativePath.isEmpty else {
            throw StoreError.integrity("empty path")
        }
        if relativePath.hasPrefix("/") {
            throw StoreError.integrity("absolute path not allowed: \(relativePath)")
        }
        // Split preserving empty components to detect //, trailing /
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        // Reject empty due to // or trailing slash
        // Note: leading slash already rejected, but // inside yields empty
        var currentFD = dirFD
        var toClose: [Int32] = []
        defer {
            for fd in toClose { close(fd) }
            if currentFD != dirFD {
                // If we exit via throw, currentFD is an intermediate that was not yet moved to toClose
                // Check if it's already in toClose to avoid double close
                if !toClose.contains(currentFD) {
                    close(currentFD)
                }
            }
        }
        for (index, compSub) in components.enumerated() {
            let name = String(compSub)
            if name.isEmpty {
                throw StoreError.integrity("empty path component in: \(relativePath)")
            }
            if name == "." {
                continue
            }
            if name == ".." {
                throw StoreError.integrity("parent escape not allowed: \(relativePath)")
            }
            if name.utf8.contains(0) {
                throw StoreError.integrity("component contains NUL: \(name)")
            }
            // Byte-exact: no NFC/NFD normalization; Swift String preserves UTF-8, we pass raw via withCString without transform
            let isLast = index == components.count - 1
            let baseFlags: Int32 = isLast ? flags : (O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            // Always add NONBLOCK to avoid FIFO hang, and ensure NOFOLLOW on final as well
            let openFlags = baseFlags | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            let fd = name.withCString { cstr in
                openat(currentFD, cstr, openFlags, mode)
            }
            guard fd >= 0 else {
                let err = errno
                if err == ELOOP {
                    throw StoreError.integrity("symlink encountered (no-follow): \(relativePath) component \(name)")
                }
                throw StoreError.integrity("openat failed for \(relativePath) component \(name): \(String(cString: strerror(err)))")
            }
            var st = stat()
            guard fstat(fd, &st) == 0 else {
                close(fd)
                throw StoreError.integrity("fstat failed for \(name)")
            }
            let fileType = st.st_mode & S_IFMT
            if isLast {
                // Deny unsafe file types
                if fileType == S_IFIFO {
                    close(fd)
                    throw StoreError.integrity("FIFO denied: \(name)")
                }
                if fileType == S_IFSOCK {
                    close(fd)
                    throw StoreError.integrity("socket denied: \(name)")
                }
                if fileType == S_IFBLK || fileType == S_IFCHR {
                    close(fd)
                    throw StoreError.integrity("device denied: \(name)")
                }
                // Directory handling: if caller expects directory, ensure directory
                if (flags & O_DIRECTORY) != 0 {
                    if fileType != S_IFDIR {
                        close(fd)
                        throw StoreError.integrity("not a directory: \(name)")
                    }
                } else {
                    // Inappropriate directory access: tool expects file but path is directory
                    if fileType == S_IFDIR {
                        close(fd)
                        throw StoreError.integrity("is directory: \(name)")
                    }
                }
                // Hardlinks are treated as regular files (indistinguishable)
                // Remove currentFD from toClose tracking if it was there (we are returning final fd, not closing current)
                // But we need to ensure toClose will not close the returned fd
                return fd
            } else {
                guard fileType == S_IFDIR else {
                    close(fd)
                    throw StoreError.integrity("intermediate component not a directory: \(name)")
                }
                // Advance: keep new fd as current, close old if not dirFD
                if currentFD != dirFD {
                    toClose.append(currentFD)
                }
                currentFD = fd
                // Do not append new fd to toClose yet; it becomes current
            }
        }
        throw StoreError.integrity("unreachable traversal for: \(relativePath)")
    }

    /// Convenience: resolve a path string for a given tool, selecting appropriate root,
    /// validating protected paths, and opening descriptor-relative. Returns fd or throws ToolFailure.
    public func resolveForTool(path: String, tool: String) throws -> Int32 {
        // First check protected paths
        let (absolute, grantable) = Self.isProtected(path: path)
        if absolute {
            throw StoreError.integrity("absolute protected path denied: \(path)")
        }
        // For mutating tools, require workspace
        let isMutating = tool != "read" && tool != "search" && tool != "consult"
        let isRead = tool == "read" || tool == "search"
        if isMutating {
            guard let _ = workspaceRoot else {
                throw StoreError.integrity("workspace not configured for mutating tool \(tool)")
            }
            let dirFD = try validatedWorkspaceFD()
            defer { close(dirFD) }
            // Flags depend on tool: edit/write need to open file for write, read needs read
            // Use O_RDONLY for read, O_RDWR for edit? But resolver just opens; actual operation will reopen with appropriate flags.
            // Here we just verify containment can be traversed; we open with O_RDONLY|O_NOFOLLOW to check existence without mutating.
            // For final component, use appropriate flags: for read we allow file, for edit/write we will check later.
            // To avoid TOCTOU, we open the final with O_RDONLY|O_NOFOLLOW first to validate, then caller will use fd.
            // Simplified: open with O_RDONLY|O_NOFOLLOW|O_CLOEXEC
            let fd = try openRelative(path, from: dirFD, flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            return fd // caller must close
        } else if isRead {
            // Read/search may use workspace or read root
            var lastError: Error?
            // Try workspace first if exists
            if let ws = workspaceRoot {
                do {
                    let dirFD = try revalidatedFD(for: ws)
                    defer { close(dirFD) }
                    let fd = try openRelative(path, from: dirFD, flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    return fd
                } catch {
                    lastError = error
                }
            }
            for root in readRoots {
                do {
                    let dirFD = try revalidatedFD(for: root)
                    defer { close(dirFD) }
                    let fd = try openRelative(path, from: dirFD, flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    return fd
                } catch {
                    lastError = error
                    continue
                }
            }
            throw lastError ?? StoreError.integrity("read path not found in any root: \(path)")
        } else {
            throw StoreError.integrity("unsupported tool \(tool)")
        }
    }

    /// Check if a path is under protected absolute denials or grantable sets.
    /// Absolute denials are never grantable. Grantable requires explicit per-batch approval.
    public static func isProtected(path: String) -> (absolute: Bool, grantable: Bool) {
        switch ToolValidator.protectedClassification(for: path) {
        case .absoluteDenied: return (true, false)
        case .grantable: return (false, true)
        case .unprotected: return (false, false)
        }
    }

    /// More precise protected check for a relative path string (byte-exact, no normalization)
    public static func protectedClassification(for path: String) -> ProtectedClassification {
        switch ToolValidator.protectedClassification(for: path) {
        case .absoluteDenied: return .absoluteDenied
        case .grantable: return .grantable
        case .unprotected: return .unprotected
        }
    }

    public enum ProtectedClassification: Sendable, Equatable {
        case absoluteDenied
        case grantable
        case unprotected
    }
}
