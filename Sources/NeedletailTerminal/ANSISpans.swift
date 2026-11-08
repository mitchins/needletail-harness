import Foundation
import NeedletailPresentation

/// M4-C ANSI span writer (ours — per DEPENDENCIES.md, no framework).
///
/// Encodes `RenderedLine` spans to SGR bytes ONLY when `caps.color` is
/// true. Plain mode returns the sanitized text unchanged (identical
/// semantics, zero ANSI bytes). The sanitizer runs BEFORE this stage,
/// so SGR is emitted only around already-safe spans — renderer output
/// itself never introduces control operations.
public enum ANSISpans {
    /// SGR open/close for one role. `nil` open ⇒ unstyled passthrough.
    public static func sgr(for role: StyleRole) -> (open: String, close: String)? {
        switch role {
        case .normal, .composerText, .candidate:
            return nil
        case .status:
            return ("\u{1B}[36m", "\u{1B}[0m")
        case .candidateSelected:
            return ("\u{1B}[7m", "\u{1B}[0m")
        case .errorNotice:
            return ("\u{1B}[31;1m", "\u{1B}[0m")
        case .heading:
            return ("\u{1B}[1;4m", "\u{1B}[0m")
        case .strong:
            return ("\u{1B}[1m", "\u{1B}[0m")
        case .emphasis:
            return ("\u{1B}[3m", "\u{1B}[0m")
        case .code:
            return ("\u{1B}[33m", "\u{1B}[0m")
        case .codeBlock:
            return ("\u{1B}[36m", "\u{1B}[0m")
        case .listMarker, .taskCheckbox:
            return ("\u{1B}[2m", "\u{1B}[0m")
        case .filePath:
            return ("\u{1B}[4m", "\u{1B}[0m")
        case .quote:
            return ("\u{1B}[2;3m", "\u{1B}[0m")
        case .diffAdd:
            return ("\u{1B}[32m", "\u{1B}[0m")
        case .diffDel:
            return ("\u{1B}[31m", "\u{1B}[0m")
        case .diffHunk:
            return ("\u{1B}[36;1m", "\u{1B}[0m")
        case .toolReceipt:
            return ("\u{1B}[32;1m", "\u{1B}[0m")
        case .warning:
            return ("\u{1B}[33;1m", "\u{1B}[0m")
        }
    }

    /// Encodes one line. Adjacent same-role spans merge into one SGR
    /// region (bounded output, no SGR spam).
    public static func encode(_ line: RenderedLine, caps: TerminalCaps) -> String {
        guard caps.color else { return line.plainText }
        var out = ""
        var index = line.spans.startIndex
        while index < line.spans.endIndex {
            let role = line.spans[index].role
            var text = line.spans[index].text
            var next = line.spans.index(after: index)
            while next < line.spans.endIndex, line.spans[next].role == role {
                text += line.spans[next].text
                next = line.spans.index(after: next)
            }
            if let sgr = sgr(for: role) {
                out += sgr.open + text + sgr.close
            } else {
                out += text
            }
            index = next
        }
        return out
    }

    /// Encodes lines joined by LF with a trailing newline (terminal
    /// record convention). Empty input ⇒ empty output (no stray newline).
    public static func encodeLines(_ lines: [RenderedLine], caps: TerminalCaps) -> String {
        guard !lines.isEmpty else { return "" }
        return lines.map { encode($0, caps: caps) }.joined(separator: "\n") + "\n"
    }
}
