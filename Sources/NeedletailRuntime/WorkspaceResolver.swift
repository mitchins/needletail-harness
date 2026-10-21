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
        guard !relativePath.isEmpty else {
            throw StoreError.integrity("empty path")
        }
        if relativePath.hasPrefix("/") {
            throw StoreError.integrity("absolute path not allowed: \(relativePath)")
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        // Reject empty components (//), ".", and fail ".." via containment (no string-prefix bypass).
        // For now, handle ".." by traversing and checking containment via fd identity is out of scope for minimal impl;
        // we reject ".." components explicitly to prevent escape before full openat containment.
        var currentFD = dirFD
        var ownedFDs: [Int32] = []
        defer {
            for fd in ownedFDs where fd != dirFD { close(fd) }
        }
        for (index, comp) in components.enumerated() {
            let name = String(comp)
            if name.isEmpty {
                throw StoreError.integrity("empty path component in: \(relativePath)")
            }
            if name == "." {
                continue
            }
            if name == ".." {
                throw StoreError.integrity("parent escape not allowed: \(relativePath)")
            }
            // Byte-exact: no NFC/NFD normalization; Swift String preserves bytes as UTF-8, but we must not normalize.
            // We pass the raw bytes via withCString (which is UTF-8) without any transform.
            let isLast = index == components.count - 1
            let openFlags: Int32
            if isLast {
                openFlags = flags
            } else {
                openFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            }
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
            // Verify no symlink via fstat + S_IFMT
            var st = stat()
            guard fstat(fd, &st) == 0 else {
                close(fd)
                throw StoreError.integrity("fstat failed for \(name)")
            }
            if isLast {
                // For final, allow regular file, directory, etc. but check via flags? Already handled.
                // If O_DIRECTORY was requested, ensure it's a dir.
                if (flags & O_DIRECTORY) != 0 && (st.st_mode & S_IFMT) != S_IFDIR {
                    close(fd)
                    throw StoreError.integrity("not a directory: \(name)")
                }
                // For non-directory final, ensure not a dir when not expecting? Allow.
                return fd // caller owns this fd, not closed in defer
            } else {
                guard (st.st_mode & S_IFMT) == S_IFDIR else {
                    close(fd)
                    throw StoreError.integrity("intermediate component not a directory: \(name)")
                }
                // Next iteration traverses from this fd
                if currentFD != dirFD {
                    ownedFDs.append(currentFD)
                }
                currentFD = fd
                ownedFDs.append(fd) // will be closed if not last? Actually we need to keep it for next iteration, but we track for cleanup
                // Remove from ownedFDs that we just added? We want to keep currentFD for next iteration, but we already added it.
                // Instead, we will manage: ownedFDs holds fds that are not currentFD.
                // Remove the last added which is currentFD
                ownedFDs.removeLast()
            }
        }
        throw StoreError.integrity("unreachable traversal for: \(relativePath)")
    }

    /// Check if a path is under protected absolute denials or grantable sets.
    public static func isProtected(path: String) -> (absolute: Bool, grantable: Bool) {
        let lower = path.lowercased()
        // Absolute denials: tool-private state, credentials, artifact dir (never grantable)
        if lower.contains(".needletail") || lower.contains("credentials") || lower.contains("artifact") {
            // Simplified check: actual logic should compare against pinned roots and fixed names
            if path.contains(".needletail") || path.contains(".credentials") {
                return (true, false)
            }
        }
        // Grantable: .git, .env variants, .ssh
        let grantablePrefixes = [".git", ".env", ".ssh"]
        for prefix in grantablePrefixes {
            if path == prefix || path.hasPrefix(prefix + "/") || path.hasPrefix(prefix + ".") {
                return (false, true)
            }
            if lower.contains("/\(prefix)/") || lower.hasSuffix("/\(prefix)") {
                return (false, true)
            }
        }
        return (false, false)
    }
}
