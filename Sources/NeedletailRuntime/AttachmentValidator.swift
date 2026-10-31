import Foundation
import NeedletailCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// M2-D D1: production `AttachmentValidator` — re-reads each snapshot's
/// file through the authorized capture machinery and reports point-in-time
/// freshness. Never throws: every failure mode becomes an unreadable
/// observation (dispatch then holds fail-closed; see `attachmentVerdict`).
///
/// The observation is bound to the snapshot by content hash; a replaced
/// file (same path, new identity) or modified file (same identity, new
/// bytes) both surface as stale at dispatch. TOCTOU note: the observation
/// reflects the file at validation time, and the transition commits the
/// dispatch in the same actor turn that stamped the result — a mutation in
/// the microsecond window between validation I/O and commit is NOT caught.
/// That residual is inherent to check-then-act on a live filesystem; the
/// capture atomicity (read + re-stat + re-hash) narrows it to one syscall
/// window, and reopen never replays observations (the next dispatch
/// revalidates).
public struct FilesystemAttachmentValidator: AttachmentValidator, Sendable {
    private let capture: AttachmentCaptureService

    public init(resolver: WorkspaceResolver, approvedPaths: [String] = []) {
        self.capture = AttachmentCaptureService(resolver: resolver, approvedPaths: approvedPaths)
    }

    public func validate(entryID: String, snapshots: [AttachmentSnapshot]) async -> [AttachmentObservation] {
        snapshots.map { observe($0) }
    }

    private func observe(_ snapshot: AttachmentSnapshot) -> AttachmentObservation {
        func unreadable(_ reason: String) -> AttachmentObservation {
            AttachmentObservation(
                snapshotHash: snapshot.contentHash, device: 0, inode: 0, size: -1,
                contentHash: "", totalLines: 0, readable: false, denyReason: reason)
        }
        /// Operator-visible cause for a failed open/stat/read: removal,
        /// denial, and substitution each name themselves (the hold message
        /// carries this reason, so precision here is debuggability).
        func cause(_ error: Error) -> String {
            guard let capture = error as? AttachmentCaptureError else {
                return "open refused: \(error)"
            }
            switch capture {
            case .notFound: return "removed"
            case .deniedPath(let detail): return "denied: \(detail)"
            case .symlinkEscape: return "symlink encountered (no-follow)"
            case .specialFile: return "not a regular file"
            case .overSizeLimit(let size): return "over size limit (\(size) bytes)"
            case .changedDuringCapture: return "changed during read"
            case .invalidRange(let detail): return "invalid range: \(detail)"
            case .unreadable(let detail): return "unreadable: \(detail)"
            }
        }
        let fd: Int32
        do {
            (fd, _) = try capture.openAttachment(snapshot.path)
        } catch {
            return unreadable(cause(error))
        }
        defer { close(fd) }
        let identity: AttachmentFileIdentity
        do {
            identity = try capture.identity(of: fd)
        } catch {
            return unreadable(cause(error))
        }
        let bytes: Data
        do {
            bytes = try capture.readAttachmentBytes(
                fd: fd, expectedSize: identity.size, relativePath: snapshot.path)
        } catch {
            return unreadable(cause(error))
        }
        let after: AttachmentFileIdentity
        do {
            after = try capture.identity(of: fd)
        } catch {
            return unreadable("re-stat refused: \(error)")
        }
        guard identity == after, bytes.count == identity.size else {
            return unreadable("changed during validation read")
        }
        let hash = NativeToolExecutor.sha256Hex(bytes)
        let totalLines: Int
        if String(data: bytes, encoding: .utf8) != nil {
            totalLines = AttachmentCaptureService.countLines([UInt8](bytes))
        } else {
            totalLines = 0
        }
        return AttachmentObservation(
            snapshotHash: snapshot.contentHash, device: identity.device,
            inode: identity.inode, size: identity.size, contentHash: hash,
            totalLines: totalLines, readable: true)
    }
}
