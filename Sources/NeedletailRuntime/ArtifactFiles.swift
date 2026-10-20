import Foundation
import Crypto
import NeedletailCore
#if canImport(Glibc)
import Glibc
#endif
#if canImport(Darwin)
import Darwin
#endif

/// A4-1 artifact file helpers (SPEC §9.1): content addressing, path
/// confinement and directory durability. No generic filesystem
/// abstraction — every path this module touches is either generated
/// here (digests, tmp names) or rejected by `resolveArtifactPath`.

/// SHA-256 of the exact bytes, lowercase hex. swift-crypto is the pinned,
/// pre-authorized digest provider (DEPENDENCIES.md); Core must not import
/// Crypto, so the digest lives here with the store that needs it.
func artifactSHA256Hex(_ bytes: Data) -> String {
    let digest = SHA256.hash(data: bytes)
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// Tmp-file prefix inside the managed root. A tmp file with no committed
/// reference is an interrupted publication, reported — never attached.
let artifactTmpPrefix = ".tmp-"

/// Confinement gate: every artifact path resolves to exactly
/// `root/name` with a benign `name`. Traversal (`/`, `..`, absolute),
/// empty and NUL-containing names fail closed with `.integrity`.
/// Callers never pass user-supplied paths here — digests are validated
/// (64 lowercase hex) before resolve, tmp names are generated — but the
/// gate holds regardless.
func resolveArtifactPath(root: String, name: String) throws -> String {
    guard !name.isEmpty,
          !name.hasPrefix("/"),
          !name.contains("/"),
          !name.contains("\0"),
          name != ".",
          name != ".."
    else {
        throw StoreError.integrity("artifact path escapes the managed root: \(name)")
    }
    return root + "/" + name
}

/// Best-effort directory durability ("where supported"): fsync the
/// containing directory so the rename itself survives a crash. Declined
/// (ENOSYS/EINVAL/EOPNOTSUPP) on mounts that cannot sync directories;
/// genuine I/O failures fail closed — a rename that may not be durable
/// must not be silently treated as durable.
func syncArtifactDirectory(atPath path: String) throws {
#if canImport(Glibc)
    let fd: Int32 = path.withCString { Glibc.open($0, Glibc.O_RDONLY) }
    guard fd >= 0 else {
        throw StoreError.integrity("artifact directory sync failed: cannot open \(path)")
    }
    defer { Glibc.close(fd) }
    if Glibc.fsync(fd) != 0 {
        let err = errno
        if err == Glibc.EINVAL || err == Glibc.ENOSYS || err == Glibc.EOPNOTSUPP { return }
        throw StoreError.integrity("artifact directory sync failed: errno \(err)")
    }
#elseif canImport(Darwin)
    let fd: Int32 = path.withCString { Darwin.open($0, Darwin.O_RDONLY) }
    guard fd >= 0 else {
        throw StoreError.integrity("artifact directory sync failed: cannot open \(path)")
    }
    defer { Darwin.close(fd) }
    if Darwin.fsync(fd) != 0 {
        let err = errno
        if err == Darwin.EINVAL || err == Darwin.ENOSYS || err == Darwin.EOPNOTSUPP { return }
        throw StoreError.integrity("artifact directory sync failed: errno \(err)")
    }
#else
    throw StoreError.integrity("artifact directory sync is unsupported on this platform")
#endif
}

/// Orphan-scan report: `orphaned` are final-named files with no committed
/// reference (renamed but never referenced — NOT completed artifacts,
/// never auto-attached, never silently deleted);
/// `interrupted` are tmp leftovers whose write/rename never finished.
public struct ArtifactOrphans: Sendable, Equatable {
    public let orphaned: [String]
    public let interrupted: [String]

    public init(orphaned: [String], interrupted: [String]) {
        self.orphaned = orphaned
        self.interrupted = interrupted
    }
}

/// Fail-closed snapshot read of a regular file (S1 pattern, shared with
/// `readBoundedFile`): opens `O_RDONLY | O_NOFOLLOW | O_NONBLOCK`,
/// requires `fstat` `S_ISREG`, and copies at most `bound + 1` bytes into
/// memory — never follows symlinks, never mmaps (no SIGBUS on
/// truncation), never hangs on FIFOs, never reads unbounded. Short reads,
/// overruns and I/O errors are typed `.integrity`, never partial bytes.
func readBoundedFD(_ fd: Int32, bound: Int) throws -> Data {
    var bytes = Data()
    var chunk = [UInt8](repeating: 0, count: 8192)
    while true {
        let readCount = chunk.withUnsafeMutableBytes { pointer in
            read(fd, pointer.baseAddress, pointer.count)
        }
        guard readCount >= 0 else {
            throw StoreError.integrity("artifact file cannot be read")
        }
        if readCount == 0 { break }
        guard bytes.count + readCount <= bound + 1 else {
            throw StoreError.integrity("artifact file exceeds its bound")
        }
        bytes.append(contentsOf: chunk.prefix(readCount))
    }
    return bytes
}

/// Opens `path` for a snapshot read and checks it is a regular file.
/// Symlinks (including swaps planted before the open), FIFOs, sockets,
/// devices and directories fail closed here, before any byte is read.
func openRegularFile(atPath path: String) throws -> Int32 {
    let fd: Int32 = path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
    guard fd >= 0 else {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil {
            throw StoreError.integrity("artifact path is a symlink; refusing escape: \(path)")
        }
        throw StoreError.integrity("artifact file absent or unreadable: \(path)")
    }
    var status = stat()
    guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
        close(fd)
        throw StoreError.integrity("artifact path is not a regular file: \(path)")
    }
    return fd
}

/// Closes an artifact file descriptor. The wrapper exists because bare
/// `close` collides with `GRDBSessionStore.close()` inside store methods.
func closeArtifactFD(_ fd: Int32) {
    close(fd)
}
