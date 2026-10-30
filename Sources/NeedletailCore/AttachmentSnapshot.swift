/// M2-D D1: immutable structured file-attachment snapshots for queued
/// operator messages (plan REV3 §D1; UX-MENTION-09/10/11/12, UX-QUEUE-08/10).
///
/// A snapshot binds ONE explicitly operator-selected file to the queue
/// entry that carries it: resolved identity (device/inode) + content hash
/// + byte range + bounded excerpt (≤4 KiB, counted toward the 64 KiB queue
/// text budget) + capture epoch/route-grant provenance + explicit content
/// classification. NO full-byte artifact refs: hash + identity + excerpt
/// suffice for staleness, and the read tool fetches further content.
///
/// Snapshots are immutable values. They are NEVER silently refreshed:
/// dispatch revalidates identity + content + grant against a fresh
/// observation, and any mismatch holds the queue head (HoldReason
/// `.staleAttachment`) until the operator replaces or withdraws the
/// attachment. Snapshots are created ONLY by the authorized capture path
/// (Runtime); the transition never parses `@` substrings out of text.
///
/// Durability: snapshots ride on `QueueEntry` (queueAdmitted/queueUpdated
/// records), so reopen replay preserves them; freshness observations are
/// event-scoped and never replayed (revalidation happens after reopen).

/// M2-D D1 budget constants (plan R-2/O-4, I-8): excerpt cap per selected
/// attachment; excerpts count toward the queue text budget.
public let maxAttachmentExcerptBytes = 4 * 1_024
/// Full-content read + hash bound for capture/validation (parity with the
/// read tool's 32 MiB limit: anything the read tool can read, capture can
/// hash; anything larger refuses at capture, never half-admits).
public let maxAttachmentCaptureBytes = 32 * 1_024 * 1_024

/// 1-based inclusive line range selected by the operator (`#L10-L30`).
public struct AttachmentLineRange: Sendable, Equatable, Codable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    /// Validity against the observed line count at capture/validation
    /// time (MENTION-08: exact 1-based boundaries or visible failure).
    public func isValid(totalLines: Int) -> Bool {
        start >= 1 && start <= end && end <= totalLines
    }
}

/// Route/consent provenance frozen at capture: which endpoint family and
/// sealing the operator's selection was admitted under. Compared at
/// dispatch against the live epoch (local→cloud needs explicit re-consent;
/// sealing travels with the entry).
public struct AttachmentRouteGrant: Sendable, Equatable, Codable {
    public let alias: String
    public let locality: Locality
    public let sealed: Bool

    public init(alias: String, locality: Locality, sealed: Bool) {
        self.alias = alias
        self.locality = locality
        self.sealed = sealed
    }
}

/// Explicit content classification: either a bounded excerpt is admitted
/// into model context, or the snapshot is identity/metadata only and no
/// file bytes travel (binary, unreadable-as-text, or otherwise
/// non-excerptable content never smuggles bytes into the prompt).
public enum AttachmentContent: Sendable, Equatable {
    /// Bounded excerpt admitted: at most 4 KiB; `truncated` is true
    /// whenever the excerpt does not contain the entire file content.
    case included(excerpt: String, truncated: Bool)
    /// Identity + hash + manifest only; `reason` names why no bytes
    /// travel (e.g. "non-UTF8 content: identity only").
    case metadataOnly(reason: String)

    /// Excerpt bytes accountable to the queue text budget (0 when no
    /// excerpt travels).
    public var excerptBytes: Int {
        switch self {
        case .included(let excerpt, _): return excerpt.utf8.count
        case .metadataOnly: return 0
        }
    }
}

extension AttachmentContent: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, excerpt, truncated, reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "included":
            self = .included(
                excerpt: try container.decode(String.self, forKey: .excerpt),
                truncated: try container.decode(Bool.self, forKey: .truncated))
        case "metadataOnly":
            self = .metadataOnly(reason: try container.decode(String.self, forKey: .reason))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "unknown AttachmentContent kind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .included(let excerpt, let truncated):
            try container.encode("included", forKey: .kind)
            try container.encode(excerpt, forKey: .excerpt)
            try container.encode(truncated, forKey: .truncated)
        case .metadataOnly(let reason):
            try container.encode("metadataOnly", forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }
}

public struct AttachmentSnapshot: Sendable, Equatable, Codable {
    /// Canonical workspace-relative path (byte-exact; never absolute,
    /// never containing `..` — enforced at capture).
    public let path: String
    /// Granted-root identity that admitted the file ("workspace" or the
    /// read-root path string).
    public let grantedRoot: String
    /// Resolved file identity at capture.
    public let device: UInt64
    public let inode: UInt64
    /// Byte count at capture.
    public let size: Int
    /// Lowercase hex SHA-256 of the EXACT captured bytes.
    public let contentHash: String
    /// Operator-selected line range (nil = whole file).
    public let lineRange: AttachmentLineRange?
    /// Line count at capture (0 when uncountable, e.g. binary).
    public let totalLines: Int
    public let content: AttachmentContent
    /// Epoch that admitted the selection (re-consent anchor).
    public let captureEpochID: EpochID
    /// Route/consent provenance at capture (privacy anchor).
    public let routeGrant: AttachmentRouteGrant
    /// Operator intent that produced the selection (e.g. "mention").
    public let intent: String

    public init(
        path: String, grantedRoot: String, device: UInt64, inode: UInt64,
        size: Int, contentHash: String, lineRange: AttachmentLineRange?,
        totalLines: Int, content: AttachmentContent, captureEpochID: EpochID,
        routeGrant: AttachmentRouteGrant, intent: String
    ) {
        self.path = path
        self.grantedRoot = grantedRoot
        self.device = device
        self.inode = inode
        self.size = size
        self.contentHash = contentHash
        self.lineRange = lineRange
        self.totalLines = totalLines
        self.content = content
        self.captureEpochID = captureEpochID
        self.routeGrant = routeGrant
        self.intent = intent
    }
}

/// Point-in-time freshness evidence for ONE snapshot, gathered by the
/// authorized validator (Runtime filesystem read; scripted in tests) and
/// carried on the dispatch-triggering event. Event-scoped: never stored,
/// never replayed — reopen drops it and the next dispatch revalidates.
public struct AttachmentObservation: Sendable, Equatable, Codable {
    /// Binds to `AttachmentSnapshot.contentHash`.
    public let snapshotHash: String
    public let device: UInt64
    public let inode: UInt64
    public let size: Int
    public let contentHash: String
    public let totalLines: Int
    /// False when the file is gone, unreadable, denied, or not a regular
    /// file; `denyReason` names the cause.
    public let readable: Bool
    public let denyReason: String?

    public init(
        snapshotHash: String, device: UInt64, inode: UInt64, size: Int,
        contentHash: String, totalLines: Int, readable: Bool, denyReason: String? = nil
    ) {
        self.snapshotHash = snapshotHash
        self.device = device
        self.inode = inode
        self.size = size
        self.contentHash = contentHash
        self.totalLines = totalLines
        self.readable = readable
        self.denyReason = denyReason
    }
}

/// Dispatch-time verdict for one snapshot (pure; I-1/I-2 enforcement).
public enum AttachmentVerdict: Sendable, Equatable {
    case fresh
    /// Refusal: hold the head with the reason, never dispatch, never
    /// refresh. `staleAttachment` selects HoldReason.staleAttachment;
    /// anything else is a queue error hold.
    case stale(fileStale: Bool, reason: String)
}

/// Pure dispatch gate for one snapshot (D1 owns ALL attachment validation).
/// Checks, in order: observation presence → readability → identity →
/// content → line-range validity → sealed consistency → route → epoch /
/// locality consent. The FIRST failure wins; only full agreement is fresh.
public func attachmentVerdict(
    snapshot: AttachmentSnapshot, observation: AttachmentObservation?,
    currentEpochID: EpochID, currentLocality: Locality,
    route: Route, consentEpochID: EpochID?, entrySealed: Bool
) -> AttachmentVerdict {
    guard let observation else {
        return .stale(fileStale: false, reason: "attachment '\(snapshot.path)' has no freshness evidence; revalidation required")
    }
    guard observation.snapshotHash == snapshot.contentHash else {
        return .stale(fileStale: false, reason: "attachment '\(snapshot.path)' evidence does not match the snapshot; revalidation required")
    }
    guard observation.readable else {
        return .stale(fileStale: true, reason: "attachment '\(snapshot.path)' unreadable at dispatch (\(observation.denyReason ?? "unknown")); replace or withdraw")
    }
    if observation.device != snapshot.device || observation.inode != snapshot.inode {
        return .stale(fileStale: true, reason: "attachment '\(snapshot.path)' replaced (identity changed); replace or withdraw")
    }
    if observation.size != snapshot.size || observation.contentHash != snapshot.contentHash {
        return .stale(fileStale: true, reason: "attachment '\(snapshot.path)' modified (content changed); replace or withdraw")
    }
    if let range = snapshot.lineRange, !range.isValid(totalLines: observation.totalLines) {
        return .stale(fileStale: true, reason: "attachment '\(snapshot.path)' line range \(range.start)-\(range.end) no longer valid (\(observation.totalLines) lines); replace or withdraw")
    }
    if entrySealed {
        // Defense in depth: admission refuses sealed attachments outright;
        // a sealed entry carrying snapshots is a corrupt state, not a
        // dispatchable one.
        return .stale(fileStale: false, reason: "sealed entries cannot dispatch file attachments")
    }
    if case .denied(let denial) = route {
        return .stale(fileStale: false, reason: "attachment '\(snapshot.path)' dispatch refused: route \(denial.message)")
    }
    let consented = consentEpochID == currentEpochID
    if snapshot.captureEpochID != currentEpochID, !consented {
        return .stale(fileStale: false, reason: "attachment '\(snapshot.path)' captured under a prior epoch; retarget to re-consent before dispatch")
    }
    if snapshot.routeGrant.locality == .local, currentLocality == .cloud, !consented {
        return .stale(fileStale: false, reason: "attachment '\(snapshot.path)' captured local; cloud dispatch requires explicit re-consent (retarget at the cloud epoch)")
    }
    return .fresh
}

/// Composes the model-context text for a dispatched entry: the operator
/// text plus one manifest + excerpt block per snapshot. Entries without
/// attachments compose to their text byte-identically (existing transcript
/// expectations are unaffected). Large files are NEVER claimed in full:
/// the manifest states exact bounds, truncation, and that further content
/// requires the read tool.
public func composeDispatchText(text: String, attachments: [AttachmentSnapshot]) -> String {
    guard !attachments.isEmpty else { return text }
    var blocks = [text]
    for snapshot in attachments {
        var header = "[attached file: \(snapshot.path) (\(snapshot.size) bytes, sha256:\(snapshot.contentHash)"
        if let range = snapshot.lineRange {
            header += ", lines \(range.start)-\(range.end) of \(snapshot.totalLines)"
        } else {
            header += ", \(snapshot.totalLines) lines"
        }
        header += ", captured \(snapshot.intent)]"
        switch snapshot.content {
        case .included(let excerpt, let truncated):
            if truncated {
                header += "\n(excerpt: first \(excerpt.utf8.count) of \(snapshot.size) bytes shown; full content NOT included — use the read tool for more)"
            } else {
                header += "\n(excerpt: complete file content shown)"
            }
            blocks.append(header + "\n" + excerpt)
        case .metadataOnly(let reason):
            header += "\n(no bytes included: \(reason) — use the read tool for content)"
            blocks.append(header)
        }
    }
    return blocks.joined(separator: "\n")
}

/// Validator seam (Core declares, Runtime implements against the real
/// filesystem, tests inject scripted or temp-fs validators). Never throws:
/// every failure mode becomes an unreadable observation, so dispatch can
/// only hold — never crash — on validator trouble.
public protocol AttachmentValidator: Sendable {
    func validate(entryID: String, snapshots: [AttachmentSnapshot]) async -> [AttachmentObservation]
}
