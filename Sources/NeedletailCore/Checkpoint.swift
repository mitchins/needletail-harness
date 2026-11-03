/// M3-C: two-phase checkpoint contract (SPEC §§7.1–7.3).
///
/// Phase A (capture): at a quiescent boundary the actor dials the provider
/// with the FULL native conversation plus a bounded checkpoint instruction;
/// tool execution is locally disabled — a tool proposal receives at most one
/// paired local denial + retry, a second tool-bearing response terminates
/// the attempt. The response text is a JSON `CheckpointDocument`.
///
/// Phase B (publish): the validated document, the harness-pinned user
/// constraints and a bounded recent-tail cut are committed atomically as a
/// `checkpointPublished` durable record + new `EpochDescriptor` (lineage via
/// `parentEpochID`). The ORIGINAL history is never truncated — the new
/// epoch's model-context projection (see `loadTranscriptProjection`) is
/// checkpoint context + the retained tail, while every old record stays in
/// the ledger.
import Foundation

/// One file reference from the model's checkpoint. `sha256` must match a
/// hash the harness itself recorded (read receipt / change-group member);
/// `observedSeq` when present must be within the durable stream.
public struct CheckpointFileRef: Sendable, Equatable, Codable {
    public let path: String
    public let sha256: String
    public let observedSeq: UInt64?

    public init(path: String, sha256: String, observedSeq: UInt64? = nil) {
        self.path = path
        self.sha256 = sha256
        self.observedSeq = observedSeq
    }

    private enum CodingKeys: String, CodingKey {
        case path, sha256
        /// The wire schema (SPEC §7.1) names this `observed_seq`; without
        /// the mapping the field silently decoded as nil and the
        /// observedSeq bound was unenforced.
        case observedSeq = "observed_seq"
    }
}

/// The prescribed checkpoint schema (SPEC §7.1). All arrays are bounded;
/// strings are bounded; the raw document is bounded before decoding.
///
/// Authority note: every field except the harness-pinned user constraints
/// (kept OUT of this document, carried in `CheckpointPublication`) and the
/// ledger-verified `currentFiles` hashes is a MODEL ASSERTION, unverified
/// by the harness — `completedWork` carries no evidence IDs by design, and
/// the projection renders model-asserted sections as such. Never treat
/// these lines as execution evidence.
public struct CheckpointDocument: Sendable, Equatable, Codable {
    public let taskGoal: String
    public let userConstraints: [String]
    public let completedWork: [String]
    public let currentFiles: [CheckpointFileRef]
    public let openQuestions: [String]
    public let failedAttempts: [String]
    public let nextActions: [String]
    public let uncertainties: [String]

    public static let maxBytes = 64 * 1_024
    public static let maxArrayEntries = 64
    public static let maxStringLength = 4 * 1_024

    public init(
        taskGoal: String, userConstraints: [String], completedWork: [String],
        currentFiles: [CheckpointFileRef], openQuestions: [String],
        failedAttempts: [String], nextActions: [String], uncertainties: [String]
    ) {
        self.taskGoal = taskGoal
        self.userConstraints = userConstraints
        self.completedWork = completedWork
        self.currentFiles = currentFiles
        self.openQuestions = openQuestions
        self.failedAttempts = failedAttempts
        self.nextActions = nextActions
        self.uncertainties = uncertainties
    }

    private enum CodingKeys: String, CodingKey {
        case taskGoal = "task_goal"
        case userConstraints = "user_constraints"
        case completedWork = "completed_work"
        case currentFiles = "current_files"
        case openQuestions = "open_questions"
        case failedAttempts = "failed_attempts"
        case nextActions = "next_actions"
        case uncertainties
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskGoal = try c.decode(String.self, forKey: .taskGoal)
        userConstraints = try c.decode([String].self, forKey: .userConstraints)
        completedWork = try c.decode([String].self, forKey: .completedWork)
        currentFiles = try c.decode([CheckpointFileRef].self, forKey: .currentFiles)
        openQuestions = try c.decode([String].self, forKey: .openQuestions)
        failedAttempts = try c.decode([String].self, forKey: .failedAttempts)
        nextActions = try c.decode([String].self, forKey: .nextActions)
        uncertainties = try c.decode([String].self, forKey: .uncertainties)
        try Self.bound(self)
    }

    /// Bounds enforced AFTER decode so a hand-built document cannot exceed
    /// them either (the model-facing contract and the harness-internal one
    /// are the same contract).
    static func bound(_ doc: CheckpointDocument) throws {
        guard !doc.taskGoal.isEmpty, doc.taskGoal.utf8.count <= Self.maxStringLength else {
            throw CheckpointError.bounds("task_goal must be non-empty and <= \(Self.maxStringLength) bytes")
        }
        for (name, array) in [("user_constraints", doc.userConstraints),
                              ("completed_work", doc.completedWork),
                              ("current_files", doc.currentFiles.map(\.path)),
                              ("open_questions", doc.openQuestions),
                              ("failed_attempts", doc.failedAttempts),
                              ("next_actions", doc.nextActions),
                              ("uncertainties", doc.uncertainties)] {
            guard array.count <= Self.maxArrayEntries else {
                throw CheckpointError.bounds("\(name) exceeds \(Self.maxArrayEntries) entries")
            }
            for element in array where element.utf8.count > Self.maxStringLength {
                throw CheckpointError.bounds("\(name) entry exceeds \(Self.maxStringLength) bytes")
            }
        }
        for file in doc.currentFiles {
            let hexOK = file.sha256.count == 64 && file.sha256.allSatisfy { ch in
                (ch >= "0" && ch <= "9") || (ch >= "a" && ch <= "f")
            }
            guard hexOK else {
                throw CheckpointError.bounds("current_files sha256 must be 64 lowercase hex chars")
            }
        }
    }
}

public enum CheckpointError: Error, Equatable, Sendable {
    case bounds(String)
    case malformed(String)
    case fabricatedReference(String)
    case toolDuringCheckpoint(String)
}

/// Failure extracting the ledger facts a capture needs. Reasons carry
/// counts only — never prompt text, paths, or hashes.
public enum CheckpointFactsError: Error, Equatable, Sendable {
    /// The durable stream could not be read: fail closed, epoch unchanged.
    case ledgerUnreadable
    /// The retained tail would start with, contain, or end on an unmatched
    /// tool call (a crash between a read-only tool-call commit and its
    /// result leaves exactly this shape): reconcile first, never publish
    /// a context the provider would reject.
    case danglingToolCall
}

/// M3-C bounded tail cut (SPEC §7.2: a bounded recent tail, never a cut
/// of a `call` from its `result`). Pure over the ordered transcript
/// entries: returns the cut INDEX (entries[cut...] is the retained
/// suffix), or nil when capture must be refused (dangling/orphan tool
/// traffic). The bound caps the WORST case; short histories retain
/// everything. A cut landing inside a call/result group snaps BACKWARD
/// (longer tail, whole group) — group integrity is hard, the bound soft.
public enum CheckpointTailCut {
    /// Maximum retained transcript records before group snapping.
    public static let maxRecords = 64

    public static func compute(_ entries: [(seq: UInt64, entry: TranscriptEntry)]) -> Int? {
        // Index responses per callID (positions strictly increasing).
        var responsesByCall: [String: [Int]] = [:]
        for (i, e) in entries.enumerated() {
            if case .toolResponse(let callID, _) = e.entry {
                responsesByCall[callID, default: []].append(i)
            }
        }
        // Every call needs a LATER response; anything else is dangling.
        for (i, e) in entries.enumerated() {
            if case .toolCall(let call) = e.entry {
                let answered = (responsesByCall[call.callID] ?? []).contains(where: { $0 > i })
                if !answered { return nil }
            }
        }
        // Every response needs a PRECEDING call; an orphan is refused too
        // (a lone tool message is not a valid provider context either).
        for (i, e) in entries.enumerated() {
            if case .toolResponse(let callID, _) = e.entry {
                var hasCallBefore = false
                for j in 0..<i {
                    if case .toolCall(let call) = entries[j].entry, call.callID == callID {
                        hasCallBefore = true
                        break
                    }
                }
                if !hasCallBefore { return nil }
            }
        }
        var cut = max(0, entries.count - maxRecords)
        // Snap backward past straddling responses (a response in the suffix
        // whose call sits before the cut). Each step strictly decreases
        // the cut, so this terminates at a group boundary (or zero).
        while cut > 0 {
            var straddles = false
            for (i, e) in entries.enumerated() {
                if i >= cut { break }
                if case .toolCall(let call) = e.entry,
                   (responsesByCall[call.callID] ?? []).contains(where: { $0 >= cut }) {
                    straddles = true
                    break
                }
            }
            if !straddles { break }
            cut -= 1
        }
        return cut
    }
}

/// Durable publication: everything the new epoch's shorter projection needs,
/// committed in ONE record alongside `checkpointCommitted` + `epochOpened`.
/// The old history is never truncated; `retainedFromSeq` (inclusive) is the
/// tail cut, chosen at publish time on a call/result group boundary.
public struct CheckpointPublication: Sendable, Equatable, Codable {
    public let epoch: EpochDescriptor
    /// Validated checkpoint JSON (canonical form, bounded).
    public let checkpointJSON: String
    /// Harness-pinned exact user constraints — extracted from the ledger's
    /// FIRST user message by the actor, never taken from the model output.
    public let pinnedConstraints: [String]
    /// Inclusive tail start: transcript records with seq >= this value are
    /// in the new epoch's model context.
    public let retainedFromSeq: UInt64
    /// Last old-history sequence covered by the checkpoint summary.
    public let boundarySequence: UInt64

    public init(
        epoch: EpochDescriptor, checkpointJSON: String,
        pinnedConstraints: [String], retainedFromSeq: UInt64, boundarySequence: UInt64
    ) {
        self.epoch = epoch
        self.checkpointJSON = checkpointJSON
        self.pinnedConstraints = pinnedConstraints
        self.retainedFromSeq = retainedFromSeq
        self.boundarySequence = boundarySequence
    }
}

public enum CheckpointValidator {
    /// Bounded parse of the model's checkpoint text. Accepts a raw JSON
    /// object or a single fenced ```json block; nothing else. No request-
    /// level structured-output schema is used (SPEC §7.1).
    public static func parse(text: String) throws -> CheckpointDocument {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = trimmed
        if candidate.hasPrefix("```") {
            guard let firstNL = candidate.firstIndex(of: "\n") else {
                throw CheckpointError.malformed("fenced block without content")
            }
            candidate = String(candidate[candidate.index(after: firstNL)...])
            if let fenceEnd = candidate.range(of: "```", options: .backwards) {
                candidate = String(candidate[..<fenceEnd.lowerBound])
            }
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard candidate.hasPrefix("{") else {
            throw CheckpointError.malformed("checkpoint response is not a JSON object")
        }
        let rawData = Data(candidate.utf8)
        guard rawData.count <= CheckpointDocument.maxBytes else {
            throw CheckpointError.bounds("checkpoint document exceeds \(CheckpointDocument.maxBytes) bytes")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any],
              obj["task_goal"] != nil else {
            throw CheckpointError.malformed("checkpoint JSON missing task_goal or unparseable")
        }
        do {
            return try JSONDecoder().decode(CheckpointDocument.self, from: rawData)
        } catch let error as CheckpointError {
            throw error
        } catch {
            throw CheckpointError.malformed("checkpoint JSON failed bounded decode: \(String(describing: error).prefix(200))")
        }
    }

    /// Reference verification against the harness's own ledger: every
    /// current_files entry must name a (path, sha256) the harness recorded
    /// — read receipts plus change-group AFTER hashes only (a pre-change
    /// `beforeHash` is stale by definition and never qualifies as
    /// "current"). An observed sequence, when present, must sit inside the
    /// durable stream and name a receipt-bearing record. "The model said
    /// tests passed" never enters this ledger — execution evidence lives
    /// in operation results.
    public static func verify(
        _ doc: CheckpointDocument, knownFileHashes: Set<String>, maxSequence: UInt64,
        receiptSequences: Set<UInt64> = []
    ) throws {
        for file in doc.currentFiles {
            let key = "\(file.path)\u{1F}\(file.sha256)"
            guard knownFileHashes.contains(key) else {
                throw CheckpointError.fabricatedReference(
                    "current_files entry '\(file.path)' does not match any recorded (path, sha256) receipt")
            }
            if let seq = file.observedSeq {
                guard seq <= maxSequence else {
                    throw CheckpointError.fabricatedReference(
                        "current_files observedSeq \(seq) exceeds the durable stream")
                }
                if !receiptSequences.isEmpty, !receiptSequences.contains(seq) {
                    throw CheckpointError.fabricatedReference(
                        "current_files observedSeq \(seq) names no receipt-bearing record")
                }
            }
        }
    }

    /// Capture overlay builder (deterministic, testable): the FULL native
    /// history plus, on the single allowed retry, the fixed tool-denial
    /// note, plus the bounded checkpoint instruction. The overlay rides
    /// the request only — it is never persisted into the transcript.
    public static func captureOverlay(history: [ChatMessage], retryNote: String?) -> [ChatMessage] {
        var overlay = history
        if let note = retryNote { overlay.append(ChatMessage(role: .user, text: note)) }
        overlay.append(ChatMessage(role: .user, text: instruction))
        return overlay
    }

    /// Fixed bounded checkpoint instruction appended to the branch overlay
    /// (never persisted into the active transcript).
    public static let instruction = """
        Produce a continuation checkpoint for this conversation as ONE JSON object with exactly these keys:
        {"task_goal": string, "user_constraints": [string], "completed_work": [string], "current_files": [{"path": string, "sha256": string, "observed_seq": number?}], "open_questions": [string], "failed_attempts": [string], "next_actions": [string], "uncertainties": [string]}
        Rules: list under current_files ONLY files you saw in read receipts or change receipts of this conversation, with their EXACT sha256 from those receipts. Output ONLY the JSON object. Do not call tools.
        """

    /// Fixed single-shot denial + retry note (SPEC §7.1: one paired local
    /// denial; a second tool-bearing response terminates the attempt).
    public static let toolDenialRetry = """
        [checkpoint notice] Your previous response proposed a tool call. Tool execution is disabled for checkpoint generation. Return ONLY the checkpoint JSON object now, with no tool calls.
        """
}
