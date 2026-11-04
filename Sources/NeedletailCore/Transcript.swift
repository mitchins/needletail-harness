import Foundation

/// M1-D authoritative conversation transcript (D1, ARCH §1). Canonical
/// history lives as ordered DurableRecords paged from the store — never
/// duplicated into SessionState (which keeps only its lastSequence
/// cursor). Transitions emit transcript records alongside existing ones
/// through the same store-append path; the transport's messageProvider
/// pages and maps them per request.

/// One ordered conversation element. Tool calls carry the VERBATIM native
/// arguments (never digests — digests must not feed execution, D2).
public enum TranscriptEntry: Sendable, Equatable, Codable {
    case user(String)
    case assistantText(String)
    case toolCall(NativeToolCall)
    case toolResponse(callID: String, text: String)
    /// M2-D D2: model-visible workspace-change notice (see
    /// WorkspaceChangeNotice, O-3). Committed atomically with the undo
    /// disposition it reports — a notice never precedes its results.
    case workspaceChangeNotice(WorkspaceChangeNotice)
}

public enum TranscriptError: Error, Sendable, Equatable, CustomStringConvertible {
    case pageOverflow(limit: Int)

    public var description: String {
        switch self {
        case .pageOverflow(let limit):
            return "pageOverflow: transcript exceeds the \(limit)-record page; refusing rather than truncating."
        }
    }
}

/// Pure mapping: ordered transcript records → wire messages. Assistant text
/// and its tool calls merge into ONE assistant message (native shape);
/// each tool response becomes a role=tool message paired by call ID.
/// Non-transcript records never leak into the request.
public func transcriptMessages(_ records: [SequencedRecord]) throws -> [ChatMessage] {
    var messages: [ChatMessage] = []
    var pendingText = ""
    var pendingCalls: [NativeToolCall] = []
    func flushAssistant() {
        if !pendingText.isEmpty || !pendingCalls.isEmpty {
            messages.append(ChatMessage(
                role: .assistant, text: pendingText,
                toolCalls: pendingCalls.isEmpty ? nil : pendingCalls))
            pendingText = ""
            pendingCalls = []
        }
    }
    for sequenced in records {
        guard case .transcriptAppended(let entry) = sequenced.record else { continue }
        switch entry {
        case .user(let text):
            flushAssistant()
            messages.append(ChatMessage(role: .user, text: text))
        case .assistantText(let text):
            pendingText += text
        case .toolCall(let call):
            pendingCalls.append(call)
        case .toolResponse(let callID, let text):
            flushAssistant()
            messages.append(ChatMessage(role: .tool, text: text, toolCallID: callID))
        case .workspaceChangeNotice(let notice):
            // O-3: the notice is model context, not user or tool text — an
            // assistant-role message carrying the bounded rendered notice.
            // It is committed with the disposition, so replay carries it
            // exactly once and it always precedes the next provider request.
            flushAssistant()
            messages.append(ChatMessage(role: .assistant, text: renderWorkspaceNotice(notice)))
        }
    }
    flushAssistant()
    return messages
}

/// Pages the transcript from the store and maps it. Over-limit pages fail
/// honest (never silent truncation — unreachable at M1 turn budgets; the
/// bound exists so growth can never silently drop history).
public func loadTranscript(from store: SessionStore, session: SessionID, limit: Int = 1024) throws -> [ChatMessage] {
    var cursor: UInt64 = 0
    var records: [SequencedRecord] = []
    while true {
        let (page, next) = try store.records(session: session, since: cursor, limit: limit)
        records.append(contentsOf: page.filter { if case .transcriptAppended = $0.record { return true } else { return false } })
        guard records.count <= limit else { throw TranscriptError.pageOverflow(limit: limit) }
        guard let following = next else { break }
        cursor = following
    }
    return try transcriptMessages(records)
}

/// M3-C: production message projection for the ACTIVE epoch. Without a
/// checkpoint publication this is exactly `loadTranscript` (identity
/// behavior for every pre-M3-C session). After a `checkpointPublished`
/// record the projection is the SHORTER new-epoch context: the validated
/// checkpoint block (full document fields; harness-bound vs
/// model-asserted lines marked in the text) followed by the bounded
/// retained tail (records with seq >= retainedFromSeq — the last
/// `CheckpointTailCut.maxRecords` transcript records snapped backward to
/// a completed call/result group boundary at publish time, so a tool call
/// is never split from its response and no unmatched call is retained).
/// The complete original history stays in the ledger — only the MODEL
/// CONTEXT is shorter.
public func loadTranscriptProjection(from store: SessionStore, session: SessionID, limit: Int = 1024) throws -> [ChatMessage] {
    var cursor: UInt64 = 0
    var records: [SequencedRecord] = []
    var publication: CheckpointPublication? = nil
    while true {
        let (page, next) = try store.records(session: session, since: cursor, limit: limit)
        for sequenced in page {
            switch sequenced.record {
            case .transcriptAppended:
                records.append(sequenced)
            case .checkpointPublished(let p):
                publication = p
            default:
                break
            }
        }
        guard let following = next else { break }
        cursor = following
    }
    guard let published = publication else {
        // No checkpoint: the full-history limit stands (identity behavior
        // with loadTranscript — over-limit histories fail honest).
        guard records.count <= limit else { throw TranscriptError.pageOverflow(limit: limit) }
        return try transcriptMessages(records)
    }
    // Shorter context: checkpoint block + retained tail. The tail starts at
    // the published cut (a completed call/result group boundary by
    // construction), so a tool call is never split from its response.
    let tail = records.filter { $0.sequence.value >= published.retainedFromSeq }
    // The limit now guards the SELECTED active tail, not the preserved
    // full history: the ledger keeps every pre-checkpoint record, but the
    // model context is the bounded tail.
    guard tail.count <= limit else { throw TranscriptError.pageOverflow(limit: limit) }
    var messages: [ChatMessage] = []
    messages.append(ChatMessage(role: .user, text: checkpointBlock(
        checkpointJSON: published.checkpointJSON,
        pinnedConstraints: published.pinnedConstraints)))
    messages.append(contentsOf: try transcriptMessages(tail))
    return messages
}

/// Renders the full validated checkpoint document as the new epoch's
/// context block. Authority is explicit in the text: the harness-pinned
/// user constraints and the verified file hashes are harness-bound; every
/// other line is the model's own untrusted summary (never execution
/// evidence). A tampered stored document falls back to the goal + pins
/// rather than failing the projection.
private func checkpointBlock(checkpointJSON: String, pinnedConstraints: [String]) -> String {
    var context = "[checkpoint context — earlier conversation summarized; harness-bound lines are the user constraints pinned by this session and file hashes verified against execution receipts; all other lines are the model's own untrusted summary, never execution evidence]\n"
    guard let doc = try? CheckpointValidator.parse(text: checkpointJSON) else {
        context += "task_goal: \(documentGoal(checkpointJSON))\n"
        if !pinnedConstraints.isEmpty {
            context += "user constraints (harness-pinned, exact):\n"
            for constraint in pinnedConstraints {
                context += "- \(constraint)\n"
            }
        }
        return context
    }
    context += "task_goal: \(doc.taskGoal)\n"
    if !pinnedConstraints.isEmpty {
        context += "user constraints (harness-pinned, exact):\n"
        for constraint in pinnedConstraints {
            context += "- \(constraint)\n"
        }
    }
    if !doc.completedWork.isEmpty {
        context += "completed_work (model-asserted, unverified):\n"
        for item in doc.completedWork {
            context += "- \(item)\n"
        }
    }
    if !doc.currentFiles.isEmpty {
        context += "current_files (hashes verified against receipts):\n"
        for file in doc.currentFiles {
            if let seq = file.observedSeq {
                context += "- \(file.path) (sha256: \(file.sha256), observed_seq: \(seq))\n"
            } else {
                context += "- \(file.path) (sha256: \(file.sha256))\n"
            }
        }
    }
    if !doc.openQuestions.isEmpty {
        context += "open_questions (model-asserted):\n"
        for item in doc.openQuestions {
            context += "- \(item)\n"
        }
    }
    if !doc.failedAttempts.isEmpty {
        context += "failed_attempts (model-asserted):\n"
        for item in doc.failedAttempts {
            context += "- \(item)\n"
        }
    }
    if !doc.nextActions.isEmpty {
        context += "next_actions (model-asserted):\n"
        for item in doc.nextActions {
            context += "- \(item)\n"
        }
    }
    if !doc.uncertainties.isEmpty {
        context += "uncertainties (model-asserted):\n"
        for item in doc.uncertainties {
            context += "- \(item)\n"
        }
    }
    return context
}

/// Extracts the task_goal string from a published checkpoint JSON. A
/// malformed stored document falls back to a bounded marker (the record was
/// validated at publish time; this only guards against tampering).
private func documentGoal(_ checkpointJSON: String) -> String {
    guard let data = checkpointJSON.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let goal = obj["task_goal"] as? String, !goal.isEmpty else {
        return "(checkpoint summary unavailable)"
    }
    return goal
}
