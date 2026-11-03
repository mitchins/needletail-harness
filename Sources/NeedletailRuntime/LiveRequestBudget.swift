import Foundation
import NeedletailCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// M3-C durable pre-send live-request budget (ticket constraint: a
/// separate 12-request M3-C allowance, enforced BEFORE any provider
/// byte is sent, fail-closed in every direction).
///
/// The counter lives in the resolved state directory next to the
/// production store, so it survives process death: a crash between
/// consume and send still consumes the unit (conservative — the
/// fail-closed direction), and re-running can never reset it. A
/// missing file starts at zero; a corrupt/unparseable/unwritable
/// counter REFUSES (never silently reset, never silently bypassed).
///
/// Cross-process atomicity: `consume` holds an `flock(LOCK_EX)` lock
/// file across the whole read-modify-write, so two concurrent
/// `run --checkpoint` processes in one state directory cannot both
/// consume the same unit and jointly exceed the allowance. (Writer
/// ownership fences sessions, but `run` mints a fresh session per
/// process — the lock is what makes the cap hard.)
/// The single-flight actor (`max_in_flight: 1`) serializes provider
/// invocations inside one process; the lock covers the rest.
public struct LiveRequestBudget: Sendable {
    public let fileURL: URL
    public let limit: Int

    public init(fileURL: URL, limit: Int) {
        self.fileURL = fileURL
        self.limit = limit
    }

    /// Pre-send budget limit selection (pure, deterministic): checkpoint
    /// runs take the fixed 12-request M3-C allowance, raised to
    /// NEEDLETAIL_REQUEST_BUDGET when explicitly set higher (M3-D T08
    /// needs up to 45; the checkpoint allowance never shrinks below 12).
    /// Other runs take NEEDLETAIL_REQUEST_BUDGET when it parses to a
    /// positive integer, else unbudgeted (nil).
    public static func limit(checkpoint: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) -> Int? {
        let env = environment["NEEDLETAIL_REQUEST_BUDGET"].flatMap(Int.init)
        if checkpoint {
            if let value = env, value > 12 { return value }
            return 12
        }
        guard let value = env, value > 0 else { return nil }
        return value
    }

    public enum BudgetError: Error, Equatable, Sendable {
        /// Budget exhausted: no request may be sent. Carries counts only
        /// (no prompts, no routes, no secrets — safe for stderr).
        case exhausted(used: Int, limit: Int)
        /// Counter file unreadable, unwritable, or unparseable: fail
        /// closed, never reset, never bypass.
        case counterUnreadable(String)
    }

    /// Consume one unit BEFORE sending. Returns the new used count.
    /// Throws `.exhausted` (send nothing) or `.counterUnreadable`
    /// (send nothing) — the caller must treat any throw as "do not
    /// dial". Holds the lock across read-modify-write-fsync; fsyncs
    /// the file and its directory so the "crash-conservative" claim
    /// holds past process death (not just process crash).
    @discardableResult
    public func consume() throws -> Int {
        let lockURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(fileURL.lastPathComponent + ".lock")
        let lockFD = lockURL.path.withCString { cpath in
            open(cpath, O_CREAT | O_RDWR, mode_t(0o600))
        }
        guard lockFD >= 0 else {
            throw BudgetError.counterUnreadable("live-request budget lock is not acquirable; refusing to send")
        }
        defer { close(lockFD) }
        guard flock(lockFD, LOCK_EX) == 0 else {
            throw BudgetError.counterUnreadable("live-request budget lock failed; refusing to send")
        }
        defer { flock(lockFD, LOCK_UN) }
        let used: Int
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let data = try? Data(contentsOf: fileURL),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let stored = obj["used"] as? Int, stored >= 0 else {
                throw BudgetError.counterUnreadable("live-request budget counter is corrupt; refusing to send")
            }
            used = stored
        } else {
            used = 0
        }
        guard used < limit else {
            throw BudgetError.exhausted(used: used, limit: limit)
        }
        let next = used + 1
        let payload = try JSONSerialization.data(
            withJSONObject: ["used": next, "limit": limit], options: [.sortedKeys])
        do {
            try payload.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            try Self.fsync(fileURL: fileURL)
        } catch let error as BudgetError {
            throw error
        } catch {
            throw BudgetError.counterUnreadable("live-request budget counter is not writable; refusing to send")
        }
        return next
    }

    /// Fsync the counter file and its parent directory (the atomic
    /// rename is what must survive power loss).
    private static func fsync(fileURL: URL) throws {
        var ok = true
        fileURL.path.withCString { cpath in
            let fd = open(cpath, O_RDONLY)
            if fd < 0 { ok = false; return }
            defer { close(fd) }
            if GlibcOrDarwin.fsync(fd) != 0 { ok = false }
        }
        if !ok { throw BudgetError.counterUnreadable("live-request budget fsync failed; refusing to send") }
        let dirPath = fileURL.deletingLastPathComponent().path
        var dirOK = true
        dirPath.withCString { cpath in
            let fd = open(cpath, O_RDONLY)
            if fd < 0 { dirOK = false; return }
            defer { close(fd) }
            if GlibcOrDarwin.fsync(fd) != 0 { dirOK = false }
        }
        if !dirOK { throw BudgetError.counterUnreadable("live-request budget directory fsync failed; refusing to send") }
    }

    /// Non-mutating inspection for receipts (never used as a gate —
    /// the gate is `consume`, so check and send cannot race).
    public func inspect() -> Int? {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stored = obj["used"] as? Int else { return nil }
        return stored
    }
}

/// M3 adjudication fix: the durable budget report line. Pure format
/// function (no I/O) so the scorer contract is unit-tested without live
/// inference traffic: `budget: used=N limit=M tag=T` when a durable
/// counter exists, `budget: unbudgeted tag=T` otherwise. The scorer
/// parses this line as the crash-safe spend superset (every pre-send
/// consume, including attempts whose responses never paired).
public func budgetReportLine(used: Int?, limit: Int?, tag: String) -> String {
    if let used, let limit {
        return "budget: used=\(used) limit=\(limit) tag=\(terminalSafe(tag))"
    }
    return "budget: unbudgeted tag=\(terminalSafe(tag))"
}

/// One spelling for `fsync` across the two supported Libcs.
private enum GlibcOrDarwin {
    @discardableResult
    static func fsync(_ fd: Int32) -> Int32 {
#if canImport(Glibc)
        Glibc.fsync(fd)
#elseif canImport(Darwin)
        Darwin.fsync(fd)
#else
        return -1
#endif
    }
}
