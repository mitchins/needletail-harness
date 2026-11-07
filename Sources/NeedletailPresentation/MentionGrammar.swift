import Foundation
import NeedletailCore

/// B1 mention grammar (UX-MENTION-01/02/08). Pure, scalar-indexed,
/// no I/O. A mention opens at an `@` that starts the text or follows
/// whitespace/`(` — never inside a word (emails), never after a
/// backslash (escaped `\@` stays literal).
public struct MentionQuery: Sendable, Equatable {
    /// Scalar index of the `@`.
    public var at: Int
    public var query: String
    public init(at: Int, query: String) {
        self.at = at
        self.query = query
    }
}

/// Derives the live mention query before `cursor` (a Unicode-scalar
/// offset into `text`), or nil when the cursor is not inside a
/// trigger span. The query runs from after `@` to the cursor and
/// must contain no whitespace; `@` alone is an empty query (list).
public func mentionQuery(text: String, cursor: Int) -> MentionQuery? {
    let scalars = Array(text.unicodeScalars)
    guard cursor >= 0, cursor <= scalars.count else { return nil }
    var at: Int? = nil
    var i = cursor - 1
    while i >= 0 {
        let s = scalars[i]
        if s == "@" {
            let prevIsBoundary: Bool = {
                if i == 0 { return true }
                let p = scalars[i - 1]
                if p == "\\" { return false }
                // ASCII boundary set (documented contract): start of text,
                // space/tab/newline, or open paren. Anything else — word
                // characters (emails), slashes, punctuation — is literal.
                return p == " " || p == "\n" || p == "\t" || p == "("
            }()
            if prevIsBoundary {
                at = i
                break
            }
            return nil
        }
        if s == "\n" || s == " " || s == "\t" { return nil }
        i -= 1
    }
    guard let found = at else { return nil }
    let query = String(String.UnicodeScalarView(scalars[(found + 1)..<cursor]))
    return MentionQuery(at: found, query: query)
}

/// Parses a `#L10` / `#L10-L30` range suffix. Lines are 1-based;
/// reversed, zero, or absurd (>1M) ranges return nil (UX-MENTION-08).
public func parseMentionRange(_ suffix: String) -> ClosedRange<Int>? {
    guard suffix.hasPrefix("#L") else { return nil }
    let body = String(suffix.dropFirst(2))
    let segments = body.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
    guard segments.count == 1 || segments.count == 2 else { return nil }
    func line(_ s: String) -> Int? {
        let t = s.hasPrefix("L") ? String(s.dropFirst()) : s
        guard let v = Int(t), v >= 1, v <= 1_000_000 else { return nil }
        return v
    }
    guard let start = line(segments[0]) else { return nil }
    if segments.count == 1 { return start...start }
    guard let end = line(segments[1]), end >= start else { return nil }
    return start...end
}

public let maxPreviewLines = 8
public let maxPreviewBytes = 4 * 1_024

/// Sanitizes preview lines for display: `terminalSafe` each line,
/// cap at 8 lines / 4 KiB total. Returns the kept lines and whether
/// anything was dropped (UX-MENTION-06). No provider request.
public func sanitizePreview(_ lines: [String]) -> (kept: [String], truncated: Bool) {
    var kept: [String] = []
    var bytes = 0
    for line in lines {
        let safe = terminalSafe(line)
        if kept.count >= maxPreviewLines || bytes + safe.utf8.count > maxPreviewBytes {
            return (kept, true)
        }
        kept.append(safe)
        bytes += safe.utf8.count
    }
    return (kept, false)
}
