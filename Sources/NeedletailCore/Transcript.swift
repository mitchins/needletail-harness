/// M1-D authoritative conversation transcript (D1, ARCH §1). Canonical
/// history lives as ordered DurableRecords paged from the store — never
/// duplicated into SessionState (which keeps only its lastSequence
/// cursor). Transitions emit transcript records alongside existing ones
/// through the same store-append path; the transport's messageProvider
/// pages and maps them per request.

/// One ordered conversation element. Tool calls carry the VERBATIM native
/// arguments (never digests — digests must not feed execution, D2).
public enum TranscriptEntry: Sendable, Equatable {
    case user(String)
    case assistantText(String)
    case toolCall(NativeToolCall)
    case toolResponse(callID: String, text: String)
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
        }
    }
    flushAssistant()
    return messages
}

/// Pages the transcript from the store and maps it. Over-limit pages fail
/// honest (never silent truncation — unreachable at M1 turn budgets; the
/// bound exists so growth can never silently drop history).
public func loadTranscript(from store: SessionStore, limit: Int = 1024) throws -> [ChatMessage] {
    var cursor: UInt64 = 0
    var records: [SequencedRecord] = []
    while true {
        let (page, next) = try store.records(since: cursor, limit: limit)
        records.append(contentsOf: page.filter { if case .transcriptAppended = $0.record { return true } else { return false } })
        guard records.count <= limit else { throw TranscriptError.pageOverflow(limit: limit) }
        guard let following = next else { break }
        cursor = following
    }
    return try transcriptMessages(records)
}
