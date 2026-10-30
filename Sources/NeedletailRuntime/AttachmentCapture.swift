import Foundation
import SystemPackage
import NeedletailCore
import Crypto
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// M2-D D1: authorized atomic capture of file-attachment snapshots
/// (plan REV3 §D1). Resolves the operator-selected workspace-relative path
/// through the SAME containment machinery as the read tool (revalidated
/// root fd + `openat` chain with `O_NOFOLLOW` on every component), applies
/// the SAME protected/grant gate, then reads + re-stats + re-hashes:
/// any identity/content change during capture refuses (or re-captures
/// once) instead of publishing a torn snapshot.
///
/// Capture never persists file bytes: the snapshot carries identity +
/// hash + a ≤4 KiB excerpt. The read tool fetches further content.
///
/// Layering: this service performs I/O (Runtime); the snapshot type and
/// all validation verdicts are pure Core. Tests drive the exposed steps
/// (`openAttachment` / `readAttachmentBytes` / `finalizeCapture`) against
/// a real temporary filesystem with injected mutations — deterministic
/// fault injection without mocks.
public enum AttachmentCaptureError: Error, Sendable, Equatable {
    /// Absolute path, parent escape, NUL, or unresolvable traversal.
    case deniedPath(String)
    /// Symlink encountered anywhere (no-follow), or root replaced.
    case symlinkEscape(String)
    /// FIFO, socket, device, or directory.
    case specialFile(String)
    case notFound(String)
    /// Larger than `maxAttachmentCaptureBytes` (parity with the read tool).
    case overSizeLimit(Int)
    /// Identity or content changed between read and re-verify (after one
    /// re-capture attempt). Never a torn snapshot.
    case changedDuringCapture(String)
    /// Reversed, zero-based, or out-of-bounds line range (or a range on
    /// non-text content).
    case invalidRange(String)
    case unreadable(String)
}

/// (device, inode, size) from `fstat` — the identity half of a snapshot.
public struct AttachmentFileIdentity: Sendable, Equatable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int

    public init(device: UInt64, inode: UInt64, size: Int) {
        self.device = device
        self.inode = inode
        self.size = size
    }
}

public struct AttachmentCaptureService: Sendable {
    public let resolver: WorkspaceResolver
    /// Ambient approvals (empty in headless capture: a grantable path
    /// without approval is denied at capture — the operator approves
    /// through the tool flow, never through capture).
    public let approvedPaths: [String]

    public init(resolver: WorkspaceResolver, approvedPaths: [String] = []) {
        self.resolver = resolver
        self.approvedPaths = approvedPaths
    }

    // MARK: - One-shot capture (production path)

    public func capture(
        relativePath: String, lineRange: AttachmentLineRange?, intent: String,
        epochID: EpochID, routeGrant: AttachmentRouteGrant
    ) throws -> AttachmentSnapshot {
        // Atomicity is read + re-read + re-hash, not stat alone: a
        // same-inode, same-size content swap between two fstats is
        // stat-invisible, so the bytes themselves are re-read and
        // re-hashed and the digests must agree. On a mid-capture change,
        // re-capture once (a racing writer may settle); a second mismatch
        // refuses. A torn snapshot can never publish.
        var lastError: AttachmentCaptureError?
        for _ in 0..<2 {
            let (fd, grantedRoot) = try openAttachment(relativePath)
            defer { close(fd) }
            let before = try identity(of: fd)
            let bytes = try readAttachmentBytes(fd: fd, expectedSize: before.size, relativePath: relativePath)
            do {
                let hash = Self.sha256Hex(bytes)
                try verifyStable(fd: fd, relativePath: relativePath, expectedHash: hash, expectedSize: before.size)
                let after = try identity(of: fd)
                return try finalizeCapture(
                    relativePath: relativePath, lineRange: lineRange, intent: intent,
                    epochID: epochID, routeGrant: routeGrant, grantedRoot: grantedRoot,
                    before: before, after: after, bytes: bytes)
            } catch let error as AttachmentCaptureError {
                lastError = error
                continue
            }
        }
        throw lastError ?? .changedDuringCapture(relativePath)
    }

    // MARK: - Exposed steps (fault-injection seams; each testable alone)

    /// Opens the path under the first root that resolves it
    /// (workspace, then read roots). Returns the fd (caller closes) and
    /// the granting root identity. Throws on denied/special/missing paths
    /// before any byte is read.
    public func openAttachment(_ relativePath: String) throws -> (fd: Int32, grantedRoot: String) {
        switch ToolValidator.protectedClassification(for: relativePath) {
        case .absoluteDenied:
            throw AttachmentCaptureError.deniedPath("absolute protected path denied: \(relativePath)")
        case .grantable where !ToolValidator.isApprovedPath(relativePath, approvedPaths: approvedPaths):
            throw AttachmentCaptureError.deniedPath("grantable protected path requires approval: \(relativePath)")
        case .grantable, .unprotected:
            break
        }
        var lastError: Error?
        if resolver.workspaceRoot != nil {
            do {
                let dirFD = try resolver.validatedWorkspaceFD()
                defer { close(dirFD) }
                let fd = try resolver.openRelative(
                    relativePath, from: dirFD,
                    flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                return (fd, "workspace")
            } catch {
                lastError = error
            }
        }
        for root in resolver.readRoots {
            do {
                let dirFD = try resolver.revalidatedFD(for: root)
                defer { close(dirFD) }
                let fd = try resolver.openRelative(
                    relativePath, from: dirFD,
                    flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                return (fd, root.path.string)
            } catch {
                lastError = error
                continue
            }
        }
        throw mapOpenError(lastError, relativePath: relativePath)
    }

    public func identity(of fd: Int32) throws -> AttachmentFileIdentity {
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            throw AttachmentCaptureError.unreadable("fstat failed: \(String(cString: strerror(errno)))")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw AttachmentCaptureError.specialFile("not a regular file")
        }
        return AttachmentFileIdentity(
            device: UInt64(st.st_dev), inode: UInt64(st.st_ino), size: Int(st.st_size))
    }

    /// Reads exactly the stabilized size; growth mid-read fails closed
    /// (mirrors the read tool — never silently truncates).
    public func readAttachmentBytes(fd: Int32, expectedSize: Int, relativePath: String) throws -> Data {
        guard expectedSize <= maxAttachmentCaptureBytes else {
            throw AttachmentCaptureError.overSizeLimit(expectedSize)
        }
        var bytes = Data()
        bytes.reserveCapacity(expectedSize)
        var remaining = expectedSize
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while remaining > 0 {
            let n = buf.withUnsafeMutableBytes { raw -> Int in
#if canImport(Glibc)
                Glibc.read(fd, raw.baseAddress!, min(remaining, 64 * 1024))
#else
                Darwin.read(fd, raw.baseAddress!, min(remaining, 64 * 1024))
#endif
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw AttachmentCaptureError.unreadable("read failed: \(String(cString: strerror(errno)))")
            }
            if n == 0 { break } // shrank mid-read: caught by re-stat below
            bytes.append(contentsOf: buf.prefix(n))
            remaining -= n
        }
        if bytes.count > expectedSize {
            throw AttachmentCaptureError.changedDuringCapture("\(relativePath): grew during capture")
        }
        return bytes
    }

    /// Re-reads the file from the start and re-hashes: the digests must
    /// agree. Catches same-inode, same-size content swaps that fstat
    /// cannot see (the stat comparison in `finalizeCapture` catches
    /// replacement/removal/size change; this catches content change).
    public func verifyStable(fd: Int32, relativePath: String, expectedHash: String, expectedSize: Int) throws {
        lseek(fd, 0, SEEK_SET)
        let reread = try readAttachmentBytes(fd: fd, expectedSize: expectedSize, relativePath: relativePath)
        guard reread.count == expectedSize,
              Self.sha256Hex(reread) == expectedHash else {
            throw AttachmentCaptureError.changedDuringCapture(relativePath)
        }
    }

    public static func sha256Hex(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Pure assembly (no I/O): refuses torn reads (before != after),
    /// slices + bounds the excerpt, hashes the exact bytes.
    public func finalizeCapture(
        relativePath: String, lineRange: AttachmentLineRange?, intent: String,
        epochID: EpochID, routeGrant: AttachmentRouteGrant, grantedRoot: String,
        before: AttachmentFileIdentity, after: AttachmentFileIdentity, bytes: Data
    ) throws -> AttachmentSnapshot {
        guard before == after, bytes.count == before.size else {
            throw AttachmentCaptureError.changedDuringCapture(relativePath)
        }
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let raw = [UInt8](bytes)
        guard let text = String(data: bytes, encoding: .utf8) else {
            // Binary: identity only. A line range on non-text content is
            // a visible failure, not a silent whole-file excerpt.
            if lineRange != nil {
                throw AttachmentCaptureError.invalidRange("\(relativePath): line range on non-UTF8 content")
            }
            return AttachmentSnapshot(
                path: relativePath, grantedRoot: grantedRoot,
                device: before.device, inode: before.inode, size: before.size,
                contentHash: hash, lineRange: nil, totalLines: 0,
                content: .metadataOnly(reason: "non-UTF8 content: identity only"),
                captureEpochID: epochID, routeGrant: routeGrant, intent: intent)
        }
        let totalLines = Self.countLines(raw)
        let ranged: String
        if let range = lineRange {
            guard range.isValid(totalLines: totalLines) else {
                throw AttachmentCaptureError.invalidRange(
                    "\(relativePath): range \(range.start)-\(range.end) outside 1...\(totalLines)")
            }
            ranged = Self.sliceLines(text, range: range)
        } else {
            ranged = text
        }
        let (excerpt, truncated) = Self.boundExcerpt(ranged, fullBytes: before.size)
        return AttachmentSnapshot(
            path: relativePath, grantedRoot: grantedRoot,
            device: before.device, inode: before.inode, size: before.size,
            contentHash: hash, lineRange: lineRange, totalLines: totalLines,
            content: .included(excerpt: excerpt, truncated: truncated),
            captureEpochID: epochID, routeGrant: routeGrant, intent: intent)
    }

    // MARK: - Line helpers (byte-exact newline scan; text already decoded)

    public static func countLines(_ bytes: [UInt8]) -> Int {
        guard !bytes.isEmpty else { return 0 }
        var count = bytes.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        if bytes.last != 0x0A { count += 1 }
        return count
    }

    public static func sliceLines(_ text: String, range: AttachmentLineRange) -> String {
        // Newline-preserving split so excerpt bytes stay exact.
        var lines: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "\n" { lines.append(current); current = "" }
        }
        if !current.isEmpty { lines.append(current) }
        let selected = lines[(range.start - 1)..<min(range.end, lines.count)]
        return selected.joined()
    }

    /// Bounds to `maxAttachmentExcerptBytes` on character boundaries
    /// (never splits a scalar). `truncated` is true whenever the excerpt
    /// does not contain the entire file content.
    public static func boundExcerpt(_ text: String, fullBytes: Int) -> (excerpt: String, truncated: Bool) {
        if text.utf8.count <= maxAttachmentExcerptBytes {
            return (text, text.utf8.count != fullBytes)
        }
        var excerpt = ""
        var used = 0
        for ch in text {
            let n = ch.utf8.count
            if used + n > maxAttachmentExcerptBytes { break }
            excerpt.append(ch)
            used += n
        }
        return (excerpt, true)
    }

    // MARK: - Error mapping

    private func mapOpenError(_ error: Error?, relativePath: String) -> AttachmentCaptureError {
        guard let error else {
            return .notFound("no configured root resolved: \(relativePath)")
        }
        if let capture = error as? AttachmentCaptureError { return capture }
        let message = String(describing: error)
        if message.contains("symlink") || message.contains("ELOOP") || message.contains("replaced") {
            return .symlinkEscape("\(relativePath): \(message)")
        }
        if message.contains("absolute") || message.contains("parent escape")
            || message.contains("NUL") || message.contains("empty path") || message.contains("empty component") {
            return .deniedPath("\(relativePath): \(message)")
        }
        // Not-found BEFORE special-file: "No such file or directory"
        // contains the word "directory".
        if message.contains("No such") || message.contains("not found") || message.contains("no such") {
            return .notFound("\(relativePath): \(message)")
        }
        if message.contains("FIFO") || message.contains("socket") || message.contains("device")
            || message.contains("is directory") || message.contains("not a directory")
            || message.contains("not a regular file") || message.contains("intermediate component") {
            return .specialFile("\(relativePath): \(message)")
        }
        if message.contains("Permission denied") || message.contains("denied") {
            return .deniedPath("\(relativePath): \(message)")
        }
        if message.contains("failed") {
            return .notFound("\(relativePath): \(message)")
        }
        return .notFound("\(relativePath): \(message)")
    }
}
