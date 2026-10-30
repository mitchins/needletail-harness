import Foundation

/// M2-D D2: native change groups, durable inverse journal, eligibility
/// preflight, workspace notices and rewind lineage (plan REV3 §D2).
///
/// This is NOT a transaction manager: it compensates eligible native
/// `edit`/`write` operations file by file, or truthfully refuses. Shell
/// execution, arbitrary filesystem changes and historical conversation
/// effects are never ledger-undoable (the exec disclaimer is a notice,
/// not a flow).
///
/// Identity contract (O-2, fixed): a stable undo command ID names the
/// operator's undo; the original change-group ID names the batch; every
/// inverse carries an operation ID derived as
/// `undo/<command>/<group>/<original-op>` — the literal `undo` first
/// component keeps derived IDs out of every other namespace (minted IDs
/// never equal the bare component `undo`, and regular tool operation IDs
/// are `<effect>/<call>` with no such prefix, so the reconciler can
/// classify them without ambiguity); write-ahead inverse intents and
/// durable inverse results reuse `operationIntent`/`operationResult` (the
/// existing outcome classifier then carries crash recovery with no new
/// machinery: intent without a result is unknown and held); the final
/// disposition is an explicit `undoDisposition` record. Journals are
/// append-only — successful journals are never removed (duplicate
/// commands return the recorded disposition, never a second inverse).

/// SHA-256 of zero bytes: the canonical "legitimately empty" marker.
/// A member whose beforeHash equals this with no preimage artifact is a
/// proven-empty original (zero-byte file or, for creates, no file) — NOT
/// a missing preimage (which fails closed).
public let emptySHA256Hex = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

/// File state expectation: exact identity + content + mode. Current state
/// must equal this for an inverse to proceed (UNDO-02/UNDO-11: hash,
/// dev/ino, mode revalidation; any divergence refuses, never overwrites).
/// Size is intentionally absent: hash equality over the exact bytes
/// implies the size, so no separate bound can disagree.
public struct UndoFileState: Sendable, Equatable, Codable {
    public let device: UInt64
    public let inode: UInt64
    public let hash: String
    /// Octal mode string as reported by the executor (e.g. "644").
    public let mode: String

    public init(device: UInt64, inode: UInt64, hash: String, mode: String) {
        self.device = device
        self.inode = inode
        self.hash = hash
        self.mode = mode
    }

    public func matches(device: UInt64, inode: UInt64, hash: String, mode: String) -> Bool {
        device == self.device && inode == self.inode
            && hash == self.hash && mode == self.mode
    }
}

/// One native mutation captured at batch completion. Only successful,
/// durably completed native `edit`/`write` calls become members;
/// unmatched, unknown, tainted or non-native members are excluded at
/// recording time (they are held by the outcome classifier instead).
public struct ChangeGroupMember: Sendable, Equatable, Codable {
    /// Original operation + call IDs (the durable `operationResult` for
    /// this mutation carries the same IDs).
    public let operationID: OperationID
    public let callID: String
    /// Canonical workspace-relative path + granting root identity.
    public let path: String
    public let grantedRoot: String
    /// True when the file did not exist before (create inverse = delete
    /// the exact created file; no preimage exists by construction).
    public let created: Bool
    /// Exact before/after content hashes (beforeHash nil only for creates).
    public let beforeHash: String?
    public let afterHash: String
    /// Original file identity where applicable (nil for creates).
    public let deviceBefore: UInt64?
    public let inodeBefore: UInt64?
    /// Preserved mode string (edit/replace) or created mode (create).
    public let modeBefore: String?
    /// Content-addressed preimage digest (nil for creates and proven-empty
    /// originals — see `emptyOriginal`).
    public let preimageDigest: String?
    /// True when the original was legitimately zero-byte (beforeHash ==
    /// emptySHA256Hex, no artifact expected). Inverse restores empty —
    /// no bytes needed. False + nil preimageDigest on a non-create means
    /// a MISSING preimage (fail closed at preflight).
    public let emptyOriginal: Bool
    /// Post-commit identity captured at the native mutation boundary
    /// (never inferred later from a reopened path).
    public let deviceAfter: UInt64
    public let inodeAfter: UInt64
    public let modeAfter: String
    /// Original result provenance (status + summary, operator-visible).
    public let receiptStatus: String
    public let receiptSummary: String

    public init(
        operationID: OperationID, callID: String, path: String, grantedRoot: String,
        created: Bool, beforeHash: String?, afterHash: String,
        deviceBefore: UInt64?, inodeBefore: UInt64?, modeBefore: String?,
        preimageDigest: String?, emptyOriginal: Bool,
        deviceAfter: UInt64, inodeAfter: UInt64, modeAfter: String,
        receiptStatus: String, receiptSummary: String
    ) {
        self.operationID = operationID
        self.callID = callID
        self.path = path
        self.grantedRoot = grantedRoot
        self.created = created
        self.beforeHash = beforeHash
        self.afterHash = afterHash
        self.deviceBefore = deviceBefore
        self.inodeBefore = inodeBefore
        self.modeBefore = modeBefore
        self.preimageDigest = preimageDigest
        self.emptyOriginal = emptyOriginal
        self.deviceAfter = deviceAfter
        self.inodeAfter = inodeAfter
        self.modeAfter = modeAfter
        self.receiptStatus = receiptStatus
        self.receiptSummary = receiptSummary
    }

    /// Post-commit expectation the current file must equal for this
    /// member's inverse to proceed. Size is implied by the hash comparison
    /// at the executor; the recorded size travels on the observation.
    public var expectedPost: (device: UInt64, inode: UInt64, hash: String, mode: String) {
        (deviceAfter, inodeAfter, afterHash, modeAfter)
    }
}

public struct ChangeGroup: Sendable, Equatable, Codable {
    /// Stable group identity (`chg-<sequence>` minted at batch completion).
    public let groupID: String
    /// The provider run + effect that dispatched the batch (provenance).
    public let runID: RunID
    public let effectID: EffectID
    /// Members in batch order (inverses apply in REVERSE order).
    public let members: [ChangeGroupMember]
    /// True when the batch also carried exec proposals (shell effects are
    /// never ledger-undoable — the notice carries the disclaimer).
    public let hadExecProposals: Bool
    /// True when the batch also carried read/search/consult proposals
    /// (informational only — they never constrain undo).
    public let hadReadProposals: Bool

    public init(
        groupID: String, runID: RunID, effectID: EffectID,
        members: [ChangeGroupMember], hadExecProposals: Bool, hadReadProposals: Bool
    ) {
        self.groupID = groupID
        self.runID = runID
        self.effectID = effectID
        self.members = members
        self.hadExecProposals = hadExecProposals
        self.hadReadProposals = hadReadProposals
    }
}

/// Per-inverse operation: restore a verified preimage, or delete an
/// exactly-verified created file. Directories are never removed.
public enum UndoInverseKind: Sendable, Equatable, Codable {
    /// Restore `preimageDigest` bytes over the file at `path`, which must
    /// currently equal `expect` (revalidated at commit, immediately
    /// before the write).
    case restore(preimageDigest: String, expect: UndoFileState)
    /// Delete the file at `path`, which must currently equal `expect`
    /// (exact created-file identity + content). Never recursive.
    case removeCreated(expect: UndoFileState)
}

public struct UndoInverse: Sendable, Equatable, Codable {
    /// Derived inverse operation ID (`<undo-command>/<original-op>`).
    public let inverseID: String
    public let undoCommandID: String
    public let groupID: String
    public let path: String
    public let grantedRoot: String
    public let kind: UndoInverseKind
    /// Mode to restore on a replace/edit inverse (the original receipt's
    /// preserved mode); nil for removeCreated.
    public let restoreMode: String?

    public init(
        inverseID: String, undoCommandID: String, groupID: String,
        path: String, grantedRoot: String, kind: UndoInverseKind, restoreMode: String? = nil
    ) {
        self.inverseID = inverseID
        self.undoCommandID = undoCommandID
        self.groupID = groupID
        self.path = path
        self.grantedRoot = grantedRoot
        self.kind = kind
        self.restoreMode = restoreMode
    }
}

public enum UndoInverseOutcome: Sendable, Equatable {
    /// The inverse committed and its post-condition verified.
    case applied(detail: String)
    /// Precondition failed (divergence, missing preimage, special file):
    /// NOTHING was mutated. The chain continues past refused inverses.
    case refused(reason: String)
    /// I/O failure with unclear mutation state: NOTHING further runs;
    /// the inverse holds as unknown and the queue holds with it.
    case failed(error: String, possiblyMutated: Bool)
}

/// One member's settled file result, recorded in the disposition.
public struct UndoFileOutcome: Sendable, Equatable, Codable {
    /// The derived inverse operation ID (exact journal key for the
    /// unknown-hold markers on reconciliation).
    public let inverseID: String
    public let path: String
    /// applied | refused | failed | unknown
    public let result: String
    public let detail: String
    /// Content hashes of the undone mutation (Major 4): the notice and
    /// export carry the exact reversible set — `beforeHash` nil means the
    /// member created the file (no before image exists).
    public let beforeHash: String?
    public let afterHash: String

    public init(inverseID: String, path: String, result: String, detail: String, beforeHash: String?, afterHash: String) {
        self.inverseID = inverseID
        self.path = path
        self.result = result
        self.detail = detail
        self.beforeHash = beforeHash
        self.afterHash = afterHash
    }

    /// Backward-compatible decode: rows written before hashes were
    /// recorded (D2 review delta) carry neither key — they decode with an
    /// empty after-image and no before-image, never fail (RecordCodecTests
    /// pins this with a stripped legacy row).
    private enum CodingKeys: String, CodingKey {
        case inverseID, path, result, detail, beforeHash, afterHash
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inverseID = try container.decode(String.self, forKey: .inverseID)
        path = try container.decode(String.self, forKey: .path)
        result = try container.decode(String.self, forKey: .result)
        detail = try container.decode(String.self, forKey: .detail)
        beforeHash = try container.decodeIfPresent(String.self, forKey: .beforeHash)
        afterHash = try container.decodeIfPresent(String.self, forKey: .afterHash) ?? ""
    }
}

public enum UndoDispositionOutcome: String, Sendable, Equatable, Codable {
    /// Every inverse applied and verified.
    case completed
    /// At least one inverse applied and at least one refused/failed —
    /// never an atomicity claim (UNDO-05).
    case partial
    /// No inverse ran (preflight conflict, missing preimage, quiescence
    /// refusal, superseded duplicate is NOT recorded — it returns the
    /// recorded one).
    case refused
    /// An inverse is unknown (possibly mutated): no further inverses ran;
    /// the operation and the queue hold until explicit reconciliation.
    case needsReconciliation
}

/// Authoritative final state of one undo command (O-2: never removed).
public struct UndoDispositionRecord: Sendable, Equatable, Codable {
    public let undoCommandID: String
    public let groupID: String
    public let outcome: UndoDispositionOutcome
    public let fileOutcomes: [UndoFileOutcome]
    /// Operator-visible reason (refusals, partials, reconciliation holds).
    public let reason: String
    public let atMillis: UInt64

    public init(
        undoCommandID: String, groupID: String, outcome: UndoDispositionOutcome,
        fileOutcomes: [UndoFileOutcome], reason: String, atMillis: UInt64
    ) {
        self.undoCommandID = undoCommandID
        self.groupID = groupID
        self.outcome = outcome
        self.fileOutcomes = fileOutcomes
        self.reason = reason
        self.atMillis = atMillis
    }
}

/// Current-file evidence for one inverse, gathered by the composed
/// validator (Runtime filesystem read; scripted in tests). Event-scoped:
/// never stored, never replayed.
public struct UndoValidationNeed: Sendable, Equatable, Codable {
    /// Binds the observation to the inverse (paths repeat inside chained
    /// groups — the inverse ID is the unique key).
    public let inverseID: String
    public let path: String

    public init(inverseID: String, path: String) {
        self.inverseID = inverseID
        self.path = path
    }
}

public struct UndoFileObservation: Sendable, Equatable, Codable {
    public let inverseID: String
    public let device: UInt64
    public let inode: UInt64
    public let size: Int
    public let hash: String
    public let mode: String
    /// False when the file is gone, unreadable, denied, a symlink, or a
    /// special file; `denyReason` names the cause (`removed`, `symlink`,
    /// `special …`, `denied: …`).
    public let readable: Bool
    public let denyReason: String?

    public init(
        inverseID: String, device: UInt64, inode: UInt64, size: Int,
        hash: String, mode: String, readable: Bool, denyReason: String? = nil
    ) {
        self.inverseID = inverseID
        self.device = device
        self.inode = inode
        self.size = size
        self.hash = hash
        self.mode = mode
        self.readable = readable
        self.denyReason = denyReason
    }
}

/// Preflight verdict for one member (pure).
public enum UndoPreflightVerdict: Sendable, Equatable {
    case eligible
    /// The whole group refuses when any member conflicts (I-4, UNDO-04).
    case conflict(reason: String)
}

/// Pure per-member preflight: the current file must equal the recorded
/// post-commit state (identity + hash + mode), the needed preimage must
/// be available, and the file must be a verifiable regular file. The
/// FIRST conflict wins; only unanimous eligibility proceeds.
public func undoPreflight(
    member: ChangeGroupMember, observation: UndoFileObservation?,
    preimageAvailable: Bool
) -> UndoPreflightVerdict {
    guard let observation else {
        return .conflict(reason: "\(member.path): no freshness evidence; revalidation required")
    }
    guard observation.readable else {
        return .conflict(reason: "\(member.path): unreadable at preflight (\(observation.denyReason ?? "unknown")); refusing")
    }
    let expect = member.expectedPost
    if observation.device != expect.device || observation.inode != expect.inode {
        return .conflict(reason: "\(member.path): identity changed (replaced); refusing — no wrong-file overwrite")
    }
    if observation.hash != expect.hash {
        return .conflict(reason: "\(member.path): content changed (hash mismatch); refusing — no overwrite of later work")
    }
    if observation.mode != expect.mode {
        return .conflict(reason: "\(member.path): mode changed; refusing")
    }
    if !member.created, !member.emptyOriginal, member.preimageDigest == nil {
        return .conflict(reason: "\(member.path): preimage missing with no empty-original proof; failing closed")
    }
    if !member.created, !member.emptyOriginal, member.preimageDigest != nil, !preimageAvailable {
        return .conflict(reason: "\(member.path): preimage unavailable; failing closed")
    }
    return .eligible
}

/// Reverse-chain rule: when one group touches the same path several
/// times, undo proceeds in reverse ONLY if every later member's
/// beforeHash equals the earlier member's afterHash (a provable chain —
/// each inverse's output satisfies the next inverse's expectation).
/// Otherwise the group refuses (never treat intermediate postimages as
/// independent current states).
///
/// Scope note (plan REV3 §D2: "or refuse the group"): the chain rule is a
/// structural gate, not a success promise. Preflight compares EVERY
/// member against the single live file, so same-path multi-touch groups
/// refuse on exact-identity divergence even when hashes link — no due row
/// (UNDO-01..05/07/10/11) requires same-path multi-touch to succeed, and
/// refusal beats a guessed-overwrite every time. Pinned by
/// `samePathCreateEditRefuses` (State) at the transition tier.
public func undoChainLinks(members: [ChangeGroupMember]) -> Bool {
    var byPath: [String: [ChangeGroupMember]] = [:]
    for member in members {
        byPath[member.path, default: []].append(member)
    }
    for chain in byPath.values where chain.count > 1 {
        for pair in zip(chain, chain.dropFirst()) {
            guard let before = pair.1.beforeHash, before == pair.0.afterHash else {
                return false
            }
        }
    }
    return true
}

/// Session quiescence for undo/rewind entry (SPEC §6 ¶924, strengthened):
/// no in-flight tool AND no active provider stream AND no unresolved
/// outcome AND no deliveryUnknown AND no pending approval AND no
/// cancellation cleanup AND no admission/checkpoint in flight AND no undo
/// already active. Queued (held or not) operator work is allowed — it
/// simply cannot dispatch while undo is active.
///
/// The deliveryUnknown leg has two shapes: a live `activeRequest` (any
/// non-nil request blocks) and a RECONSTRUCTED unknown delivery (a queue
/// entry in `.heldUnknown` — a dispatch whose outcome never arrived).
/// The latter carries no unresolved marker (the dispatch intent is
/// non-mutating and callID-less by design), so it is checked explicitly:
/// a possibly-live remote turn may still produce tool effects, and undo
/// never compensates underneath one.
public func undoQuiescent(_ state: SessionState) -> Bool {
    guard !state.phase.hasActiveRun else { return false }
    switch state.phase {
    case .idle, .failed, .completed, .interrupted:
        break
    case .admitting, .requesting, .streaming, .validatingTools, .authorising,
         .executing, .cancelling, .checkpointing, .undoing:
        return false
    }
    guard state.unresolvedOperations.isEmpty else { return false }
    guard state.pendingApproval == nil else { return false }
    guard state.activeRequest == nil else { return false }
    guard !state.queue.contains(where: { $0.state == .heldUnknown }) else { return false }
    return true
}

/// Model-visible workspace notice (O-3, fixed): a dedicated transcript
/// element with durable origin (undo command + group IDs) and per-file
/// outcome references, bounded for the prompt. Always names the exec
/// exclusion (UNDO-06): shell-produced effects are never ledger-undoable.
public struct WorkspaceChangeNotice: Sendable, Equatable, Codable {
    public let undoCommandID: String
    public let groupID: String
    public let outcome: UndoDispositionOutcome
    /// Bounded per-file results (capped at notice construction).
    public let files: [UndoFileOutcome]
    /// True when the undone batch carried exec proposals (the disclaimer
    /// names the exclusion explicitly).
    public let hadExecProposals: Bool
    public let reason: String

    public init(
        undoCommandID: String, groupID: String, outcome: UndoDispositionOutcome,
        files: [UndoFileOutcome], hadExecProposals: Bool, reason: String
    ) {
        self.undoCommandID = undoCommandID
        self.groupID = groupID
        self.outcome = outcome
        self.files = files
        self.hadExecProposals = hadExecProposals
        self.reason = reason
    }
}

public let maxNoticeFiles = 20

/// Bounded live mirror of recorded dispositions (SessionState-side only).
/// The durable log is never pruned — only this in-memory projection caps
/// length, oldest-first, so duplicate detection stays bounded.
public let maxUndoDispositions = 64

/// Numeric suffix of a minted undo command ID (`undo-<n>` → n, else 0).
/// Reseed pruning keeps the highest (newest) commands; lexicographic
/// order would drop `undo-9` before `undo-10`.
public func undoCommandSequence(_ commandID: String) -> UInt64 {
    guard commandID.hasPrefix("undo-"),
          let n = UInt64(commandID.dropFirst("undo-".count)) else {
        return 0
    }
    return n
}

/// Workspace-relative path containment for undo membership and inverse
/// commit. The ledger never touches absolute paths, parent escapes, NUL
/// bytes or empty paths — a member failing this check is excluded at
/// record time, and an inverse failing it is refused without mutation.
public func undoPathContained(_ path: String) -> Bool {
    guard !path.isEmpty, !path.contains("\0") else { return false }
    if path.hasPrefix("/") { return false }
    for component in path.split(separator: "/", omittingEmptySubsequences: false) {
        if component.isEmpty || component == "." || component == ".." {
            return false
        }
    }
    return true
}

/// Builds one change group from a completed batch's proven-done native
/// `edit`/`write` outcomes. Only successful, started, done-classified
/// outcomes with a workspace-relative path, an after-hash, post-commit
/// identity and (for replaces) a before-hash become members; everything
/// else — unknown/held/tainted/mismatched, non-native, pathless or
/// identity-less results — is excluded here and stays governed by the
/// outcome classifier instead. Partial batches therefore contribute only
/// proven-done members (UNDO-01/07). Returns nil when no member qualifies
/// (no empty groups are ever recorded).
public func buildChangeGroup(
    groupID: String, runID: RunID, effectID: EffectID,
    proposals: [ToolProposal], outcomes: [String: ToolCallOutcome],
    doneCallIDs: Set<String>
) -> ChangeGroup? {
    var members: [ChangeGroupMember] = []
    var hadExec = false
    var hadRead = false
    for proposal in proposals {
        switch proposal.tool {
        case "exec": hadExec = true
        case "read", "search", "consult": hadRead = true
        default: break
        }
        guard proposal.tool == "edit" || proposal.tool == "write" else { continue }
        guard doneCallIDs.contains(proposal.callID) else { continue }
        guard let outcome = outcomes[proposal.callID],
              outcome.status == "success", outcome.started != false,
              let path = outcome.path, undoPathContained(path),
              let afterHash = outcome.afterHash,
              let deviceAfter = outcome.deviceAfter, let inodeAfter = outcome.inodeAfter,
              let modeAfter = outcome.mode,
              let grantedRoot = outcome.grantedRoot, !grantedRoot.isEmpty
        else { continue }
        let created = outcome.created ?? false
        if !created {
            // Replaces require a before-hash: a replace with no proven
            // original cannot be restored (fail closed at record time —
            // it never becomes an inverse).
            guard outcome.beforeHash != nil,
                  outcome.deviceBefore != nil, outcome.inodeBefore != nil,
                  outcome.mode != nil
            else { continue }
        }
        let beforeHash = outcome.beforeHash
        let emptyOriginal = !created && beforeHash == emptySHA256Hex
        members.append(ChangeGroupMember(
            operationID: operationID(effectID: effectID, callID: proposal.callID),
            callID: proposal.callID, path: path, grantedRoot: grantedRoot,
            created: created, beforeHash: beforeHash, afterHash: afterHash,
            deviceBefore: outcome.deviceBefore, inodeBefore: outcome.inodeBefore,
            modeBefore: outcome.mode,
            preimageDigest: outcome.artifactID, emptyOriginal: emptyOriginal,
            deviceAfter: deviceAfter, inodeAfter: inodeAfter, modeAfter: modeAfter,
            receiptStatus: outcome.status, receiptSummary: outcome.summary))
    }
    guard !members.isEmpty else { return nil }
    return ChangeGroup(
        groupID: groupID, runID: runID, effectID: effectID,
        members: members, hadExecProposals: hadExec, hadReadProposals: hadRead)
}

/// In-flight undo command (live only — never persisted; crash recovery
/// rebuilds authority from the durable journal, never from this).
public struct PendingUndo: Sendable, Equatable {
    public let commandID: String
    public let group: ChangeGroup
    public let preimagesAvailable: [String: Bool]
    /// Inverses in run order (reverse batch order); `nextIndex` is the
    /// first not-yet-committed inverse. At most one inverse is in flight.
    public let inverses: [UndoInverse]
    public let nextIndex: Int
    public let fileOutcomes: [UndoFileOutcome]
    /// Phase to restore when the disposition commits (the quiescent
    /// phase the command entered from — idle or a terminal receipt).
    public let entryPhase: SessionPhase
    /// True for a dry-run preview (no phase change, no records beyond the
    /// event marker, no mutation ever).
    public let isPreview: Bool

    public init(
        commandID: String, group: ChangeGroup,
        preimagesAvailable: [String: Bool], inverses: [UndoInverse],
        nextIndex: Int = 0, fileOutcomes: [UndoFileOutcome] = [],
        entryPhase: SessionPhase = .idle, isPreview: Bool = false
    ) {
        self.commandID = commandID
        self.group = group
        self.preimagesAvailable = preimagesAvailable
        self.inverses = inverses
        self.nextIndex = nextIndex
        self.fileOutcomes = fileOutcomes
        self.entryPhase = entryPhase
        self.isPreview = isPreview
    }

    public func advancing(outcome: UndoFileOutcome) -> PendingUndo {
        PendingUndo(
            commandID: commandID, group: group,
            preimagesAvailable: preimagesAvailable, inverses: inverses,
            nextIndex: nextIndex + 1,
            fileOutcomes: fileOutcomes + [outcome],
            entryPhase: entryPhase, isPreview: isPreview)
    }
}

/// Derives the recorded disposition outcome from settled file results:
/// any unknown holds the queue; unanimous applied completes; any
/// applied-or-failed attempt is partial (never an atomicity claim); only
/// a unanimous refusal (nothing attempted beyond preflight) refuses.
public func undoDispositionOutcome(for fileOutcomes: [UndoFileOutcome]) -> UndoDispositionOutcome {
    guard !fileOutcomes.isEmpty else { return .refused }
    if fileOutcomes.contains(where: { $0.result == "unknown" }) {
        return .needsReconciliation
    }
    if fileOutcomes.allSatisfy({ $0.result == "applied" }) {
        return .completed
    }
    if fileOutcomes.allSatisfy({ $0.result == "refused" }) {
        return .refused
    }
    return .partial
}

/// Renders the notice for model context: outcome, per-file results with
/// the exact before/after hashes undone (the reversible set, Major 4),
/// bounded, and the exec-exclusion disclaimer. No credentials, no raw
/// payloads — paths are workspace-relative by construction.
public func renderWorkspaceNotice(_ notice: WorkspaceChangeNotice) -> String {
    var lines = ["[workspace notice: undo \(notice.undoCommandID) \(notice.outcome.rawValue)]"]
    for file in notice.files.prefix(maxNoticeFiles) {
        let before = file.beforeHash ?? "none(created)"
        lines.append("\(file.result): \(file.path) before=\(before) after=\(file.afterHash)")
    }
    if notice.files.count > maxNoticeFiles {
        lines.append("…and \(notice.files.count - maxNoticeFiles) more files")
    }
    if !notice.reason.isEmpty {
        lines.append(notice.reason)
    }
    lines.append("shell-produced effects are never ledger-undoable")
    return lines.joined(separator: "\n")
}

/// Rewind lineage fork (record only — no file mutation, no branch switch,
/// no history rewrite). A fork selects an existing turn/epoch boundary;
/// the parent conversation is preserved and the divergence is labeled
/// honestly (the historical filesystem is NOT reconstructed, so the
/// workspace is reported as unverified against the boundary).
public struct LineageBoundary: Sendable, Equatable, Codable {
    /// The epoch the boundary belongs to (must equal the live epoch —
    /// forks never cross epochs).
    public let epochID: EpochID
    /// Last durable sequence included in the forked-from history (must not
    /// exceed the live lastSequence).
    public let throughSequence: UInt64

    public init(epochID: EpochID, throughSequence: UInt64) {
        self.epochID = epochID
        self.throughSequence = throughSequence
    }
}

public struct LineageFork: Sendable, Equatable, Codable {
    public let forkID: String
    public let sessionID: SessionID
    public let parentEpochID: EpochID
    public let boundary: LineageBoundary
    /// Honest divergence label (always notes the workspace was not
    /// restored and is unverified against the boundary).
    public let divergenceNote: String
    public let atMillis: UInt64

    public init(
        forkID: String, sessionID: SessionID, parentEpochID: EpochID,
        boundary: LineageBoundary, divergenceNote: String, atMillis: UInt64
    ) {
        self.forkID = forkID
        self.sessionID = sessionID
        self.parentEpochID = parentEpochID
        self.boundary = boundary
        self.divergenceNote = divergenceNote
        self.atMillis = atMillis
    }
}

/// Validator seam (Core declares, Runtime implements): current-file
/// evidence for each inverse. Never throws — every failure mode becomes
/// an unreadable observation, so preflight can only refuse.
public protocol UndoFileValidator: Sendable {
    func validate(members: [UndoValidationNeed]) async -> [UndoFileObservation]
}

/// Inverse applier seam (Core declares, Runtime implements): performs ONE
/// filesystem inverse with commit-time revalidation. The outcome tells
/// the transition exactly what happened — no ambiguity is hidden.
public protocol UndoInverseApplier: Sendable {
    func apply(_ inverse: UndoInverse) async -> UndoInverseOutcome
}

/// Derived inverse operation ID: `undo/<command>/<group>/<original-op>`.
/// The literal `undo` first component is the journal discriminator (see
/// the identity contract above); the command and group ride along so
/// journal reconstruction needs no side table.
public func undoInverseID(undoCommandID: String, groupID: String, operationID: OperationID) -> String {
    "undo/\(undoCommandID)/\(groupID)/\(operationID.raw)"
}

/// Parses a derived inverse operation ID back into
/// (command, group, original-op). Nil for any other shape.
public func parseUndoInverseID(_ raw: String) -> (command: String, group: String, original: String)? {
    let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count >= 4, parts[0] == "undo" else { return nil }
    let command = String(parts[1])
    let group = String(parts[2])
    let original = parts[3...].joined(separator: "/")
    guard !command.isEmpty, !group.isEmpty, !original.isEmpty else { return nil }
    return (command, group, original)
}

/// Builds the reverse-order inverse list for a group (last change undone
/// first — required for provable reverse chains).
public func undoInverses(undoCommandID: String, group: ChangeGroup) -> [UndoInverse] {
    group.members.reversed().map { member in
        let kind: UndoInverseKind
        let restoreMode: String?
        let expect = UndoFileState(
            device: member.deviceAfter, inode: member.inodeAfter,
            hash: member.afterHash, mode: member.modeAfter)
        if member.created {
            kind = .removeCreated(expect: expect)
            restoreMode = nil
        } else if member.emptyOriginal {
            kind = .restore(preimageDigest: "", expect: expect)
            restoreMode = member.modeBefore
        } else {
            kind = .restore(preimageDigest: member.preimageDigest ?? "", expect: expect)
            restoreMode = member.modeBefore
        }
        return UndoInverse(
            inverseID: undoInverseID(
                undoCommandID: undoCommandID, groupID: group.groupID,
                operationID: member.operationID),
            undoCommandID: undoCommandID, groupID: group.groupID,
            path: member.path, grantedRoot: member.grantedRoot,
            kind: kind, restoreMode: restoreMode)
    }
}

/// Canonical validator needs for a group, in MEMBER order: each need/// carries the exact inverse ID that undoes its member (derived
/// deterministically, never positionally). Positional pairing of the
/// reversed inverse list against member order is a proven bug shape
/// (Major 1): member `i` is undone by `inverses[n-1-i]`, so every lookup
/// goes through this ID, never an index.
public func undoValidationNeeds(undoCommandID: String, group: ChangeGroup) -> [UndoValidationNeed] {
    group.members.map { member in
        UndoValidationNeed(
            inverseID: undoInverseID(
                undoCommandID: undoCommandID, groupID: group.groupID,
                operationID: member.operationID),
            path: member.path)
    }
}

/// Resolves the group member an inverse undoes, via the derived operation
/// ID (never positionally — see undoValidationNeeds).
public func memberForInverse(group: ChangeGroup, inverseID: String) -> ChangeGroupMember? {
    guard let parsed = parseUndoInverseID(inverseID) else { return nil }
    return group.members.first(where: { $0.operationID.raw == parsed.original })
}

// MARK: - Durable journal reconciliation (pure)

/// Reconciled undo journal for one command: write-ahead intents, durable
/// results, and the final disposition (if recorded).
public struct UndoJournalEntry: Sendable, Equatable {
    public let undoCommandID: String
    public let groupID: String
    public let intents: [OperationRef]
    public let results: [String: (ref: OperationRef, outcome: String)]
    public let disposition: UndoDispositionRecord?

    public static func == (lhs: UndoJournalEntry, rhs: UndoJournalEntry) -> Bool {
        guard lhs.undoCommandID == rhs.undoCommandID,
              lhs.groupID == rhs.groupID,
              lhs.intents == rhs.intents,
              lhs.disposition == rhs.disposition,
              lhs.results.keys.sorted() == rhs.results.keys.sorted() else {
            return false
        }
        for key in lhs.results.keys {
            guard let l = lhs.results[key], let r = rhs.results[key],
                  l.ref == r.ref, l.outcome == r.outcome else {
                return false
            }
        }
        return true
    }

    public init(
        undoCommandID: String, groupID: String,
        intents: [OperationRef] = [],
        results: [String: (ref: OperationRef, outcome: String)] = [:],
        disposition: UndoDispositionRecord? = nil
    ) {
        self.undoCommandID = undoCommandID
        self.groupID = groupID
        self.intents = intents
        self.results = results
        self.disposition = disposition
    }
}

/// Pure journal reconstruction from a session-scoped record stream.
/// Inverse intents/results reuse operation records, so
/// `reconcileOperations` already classifies them (intent-only mutating ⇒
/// unknown + held); this function additionally groups them per undo
/// command and attaches dispositions for idempotency + notice recovery.
/// Unknown inverse refs are returned separately so resume can seed them
/// as held recovery markers (no inverse ever re-executes on reopen).
public func reconcileUndoJournal(_ records: [DurableRecord]) -> (entries: [String: UndoJournalEntry], unknownInverses: [OperationRef]) {
    var intents: [String: [OperationRef]] = [:]
    var intentGroup: [String: String] = [:]
    var results: [String: [String: (ref: OperationRef, outcome: String)]] = [:]
    var resultGroup: [String: String] = [:]
    var dispositions: [String: UndoDispositionRecord] = [:]
    for record in records {
        switch record {
        case .operationIntent(let ref):
            // Derived inverse intent: `undo/<cmd>/<group>/<op>`. The
            // `undo` first component is the discriminator (regular tool
            // intents are `<effect>/<call>` and never match). Inverse refs
            // carry the inverse ID as their callID, so the durable
            // classifier pairs them exactly like tool operations:
            // intent-only mutating ⇒ unknown + held; intent + done ⇒ done.
            if let parsed = parseUndoInverseID(ref.operationID.raw),
               ref.mutating {
                intents[parsed.command, default: []].append(ref)
                intentGroup[parsed.command] = parsed.group
            }
        case .operationResult(let ref, let outcome):
            if let parsed = parseUndoInverseID(ref.operationID.raw),
               ref.mutating {
                results[parsed.command, default: [:]][ref.operationID.raw] = (ref, outcome)
                resultGroup[parsed.command] = parsed.group
            }
        case .undoDisposition(let disposition):
            dispositions[disposition.undoCommandID] = disposition
        default:
            continue
        }
    }
    var entries: [String: UndoJournalEntry] = [:]
    let commands = Set(intents.keys).union(results.keys).union(dispositions.keys)
    for cmd in commands {
        let group = intentGroup[cmd] ?? resultGroup[cmd] ?? dispositions[cmd]?.groupID ?? ""
        entries[cmd] = UndoJournalEntry(
            undoCommandID: cmd, groupID: group,
            intents: intents[cmd] ?? [], results: results[cmd] ?? [:],
            disposition: dispositions[cmd])
    }
    // Unknown inverses: intent without a done result (durable recovery
    // evidence — the inverse may have executed). A result in `.unknown`
    // state is unknown; so is a MUTATING result whose outcome string is an
    // explicit unknowability claim (`unknown: …`) even when recorded done —
    // pre-fix rows wrote exactly that shape, and the string is durable
    // evidence no state enum can overrule.
    var unknownInverses: [OperationRef] = []
    for entry in entries.values {
        for intent in entry.intents {
            if let result = entry.results[intent.operationID.raw] {
                if result.ref.state == .unknown {
                    unknownInverses.append(result.ref)
                } else if result.ref.mutating && result.outcome.hasPrefix("unknown:") {
                    // Pre-fix / writer-bug shape: the outcome string claims
                    // unknowability the state enum does not. The recovery
                    // marker claims unknown (it is), keyed by the same ID
                    // resume dedupes against.
                    unknownInverses.append(OperationRef(
                        operationID: result.ref.operationID, callID: result.ref.callID,
                        state: .unknown, mutating: true))
                }
            } else {
                unknownInverses.append(OperationRef(
                    operationID: intent.operationID, callID: intent.callID,
                    state: .unknown, mutating: true))
            }
        }
    }
    return (entries, unknownInverses)
}

/// Reconstructs change groups in first-recorded order (for drivers that
/// must present eligible groups without live state).
public func reconcileChangeGroups(_ records: [DurableRecord]) -> [ChangeGroup] {
    var groups: [ChangeGroup] = []
    for record in records {
        if case .changeGroup(let group) = record {
            if !groups.contains(where: { $0.groupID == group.groupID }) {
                groups.append(group)
            }
        }
    }
    return groups
}

/// A settled-but-undispositioned journal awaiting driver-stamped recovery
/// (crash boundary 5: every inverse has a durable result, but the
/// disposition + notice were never committed). The file outcomes rebuild
/// deterministically from the durable results + group members — the same
/// mapping `handleUndoFinalize` enforces, so recovery and the transition
/// can never disagree on what settled.
public struct PendingUndoFinalize: Sendable, Equatable {
    public let undoCommandID: String
    public let group: ChangeGroup
    public let fileOutcomes: [UndoFileOutcome]

    public init(undoCommandID: String, group: ChangeGroup, fileOutcomes: [UndoFileOutcome]) {
        self.undoCommandID = undoCommandID
        self.group = group
        self.fileOutcomes = fileOutcomes
    }
}

/// What one `recoverUndoJournal` sweep settled: recovered journals now
/// have a durable disposition + notice; unrecovered journals were found
/// but their finalize was refused (or the sweep could not run them) —
/// they must not be mistaken for "nothing pending."
public struct UndoRecoveryReport: Sendable, Equatable {
    public let recovered: [UndoDispositionRecord]
    public let unrecovered: [PendingUndoFinalize]

    public init(recovered: [UndoDispositionRecord], unrecovered: [PendingUndoFinalize]) {
        self.recovered = recovered
        self.unrecovered = unrecovered
    }
}

/// Finds crash-boundary-5 journals in a session-scoped record stream:
/// entries with at least one intent, every intent settled with a
/// non-unknown result, and no disposition recorded. Entries with unknown
/// results are NOT finalizable (they need reconciliation, not a
/// disposition); entries with a disposition are already answered.
public func pendingUndoFinalizations(_ records: [DurableRecord]) -> [PendingUndoFinalize] {
    let (entries, _) = reconcileUndoJournal(records)
    let groups = reconcileChangeGroups(records)
    var groupsByID: [String: ChangeGroup] = [:]
    for group in groups {
        groupsByID[group.groupID] = group
    }
    var pending: [PendingUndoFinalize] = []
    for entry in entries.values.sorted(by: { $0.undoCommandID < $1.undoCommandID }) {
        guard entry.disposition == nil, !entry.intents.isEmpty else { continue }
        guard let group = groupsByID[entry.groupID] else { continue }
        var outcomes: [UndoFileOutcome] = []
        var complete = true
        for member in group.members {
            let inverseID = undoInverseID(
                undoCommandID: entry.undoCommandID, groupID: group.groupID,
                operationID: member.operationID)
            guard let result = entry.results[inverseID], result.ref.state == .done else {
                complete = false
                break
            }
            let outcome = result.outcome
            let status: String
            if outcome.hasPrefix("applied:") {
                status = "applied"
            } else if outcome.hasPrefix("refused:") {
                status = "refused"
            } else if outcome.hasPrefix("failed:") {
                status = "failed"
            } else {
                complete = false
                break
            }
            outcomes.append(UndoFileOutcome(
                inverseID: inverseID, path: member.path,
                result: status, detail: outcome,
                beforeHash: member.beforeHash, afterHash: member.afterHash))
        }
        guard complete, !outcomes.isEmpty else { continue }
        pending.append(PendingUndoFinalize(
            undoCommandID: entry.undoCommandID, group: group, fileOutcomes: outcomes))
    }
    return pending
}
