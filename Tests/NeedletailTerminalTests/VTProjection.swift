import Foundation

/// M4-D D3 test-only VT screen projection (spec ¶871/¶1134: "a small
/// known VT screen fixture" / "bounded tested VT projection" — never a
/// production renderer, never a new dependency). Tracks cursor row/col
/// over the sequences the harness emits, plus an OSC 0/2 title model.
/// Everything else is ignore-AND-record: `sawUnsupported` latches on
/// any unlisted sequence, and PTY-05/PTY-06 fail when it is set — the
/// projection can never silently misproject.
///
/// Deliberately NOT a full emulator: no scroll regions, no charset
/// switching effects, no wrap modeling (the harness repaints full
/// lines; assertions use absolute cursor addressing). SGR is tracked
/// only as "seen" (styling never moves the cursor).
///
/// `sawOutOfRange` latches when an ABSOLUTE cursor address targets a
/// cell outside the viewport (stale-width cursor math after a resize
/// parks the cursor off-screen). Printable overflow does NOT latch
/// (real terminals wrap; the projection does not model wrap).
/// Relative moves and scrolling clamp silently — they stay in range
/// by construction. PTY-05 fails when the flag is set.
struct VTProjection {
    var rows: Int
    var cols: Int
    /// 1-based cursor, like DEC reports.
    var cursorRow = 1
    var cursorCol = 1
    var title = ""
    var sawUnsupported = false
    var sawOutOfRange = false

    init(rows: Int = 24, cols: Int = 80) {
        self.rows = rows
        self.cols = cols
    }

    mutating func feed(_ text: String) {
        var scalars = Array(text.unicodeScalars)
        var i = scalars.startIndex
        while i < scalars.endIndex {
            let s = scalars[i]
            if s == "\u{1B}" {
                i = feedEscape(scalars: scalars, from: i)
            } else if s == "\u{07}" {
                // Bare BEL outside OSC: ignore (no projection effect).
                i = scalars.index(after: i)
            } else if s == "\r" {
                cursorCol = 1
                i = scalars.index(after: i)
            } else if s == "\n" {
                cursorRow = min(rows, cursorRow + 1)
                i = scalars.index(after: i)
            } else if s.value < 0x20 || s.value == 0x7F {
                // Other C0/C1: no cursor effect in the projection.
                i = scalars.index(after: i)
            } else {
                // Printable: advance one cell (no wrap modeling — the
                // harness repaints full lines; clamping keeps the
                // projection total without pretending wrap fidelity).
                cursorCol = min(cols + 1, cursorCol + 1)
                i = scalars.index(after: i)
            }
        }
        _ = scalars
    }

    /// Parses one escape sequence starting at `i` (which points at ESC).
    /// Returns the index just past the sequence.
    private mutating func feedEscape(scalars: [UnicodeScalar], from i: Int) -> Int {
        var j = scalars.index(after: i)
        guard j < scalars.endIndex else { sawUnsupported = true; return j }
        let first = scalars[j]
        if first == "[" {
            return feedCSI(scalars: scalars, from: scalars.index(after: j))
        }
        if first == "]" {
            return feedOSC(scalars: scalars, from: scalars.index(after: j))
        }
        if first == "(" || first == ")" || first == "#" {
            // Charset selects / line attributes: no cursor effect.
            var k = scalars.index(after: j)
            if k < scalars.endIndex { k = scalars.index(after: k) }
            return k
        }
        if first == "M" {
            // Reverse index: up one, same column.
            cursorRow = max(1, cursorRow - 1)
            return scalars.index(after: j)
        }
        if first == "=" || first == ">" {
            // Keypad mode: ignore.
            return scalars.index(after: j)
        }
        sawUnsupported = true
        return scalars.index(after: j)
    }

    private mutating func feedCSI(scalars: [UnicodeScalar], from i: Int) -> Int {
        // Collect parameter bytes (0x30-0x3F) then intermediates
        // (0x20-0x2F), then the final byte (0x40-0x7E).
        var j = i
        var params = ""
        while j < scalars.endIndex {
            let v = scalars[j].value
            if v >= 0x30 && v <= 0x3F {
                params.unicodeScalars.append(scalars[j])
                j = scalars.index(after: j)
            } else {
                break
            }
        }
        while j < scalars.endIndex {
            let v = scalars[j].value
            if v >= 0x20 && v <= 0x2F {
                j = scalars.index(after: j)
            } else {
                break
            }
        }
        guard j < scalars.endIndex else { sawUnsupported = true; return j }
        let final = scalars[j]
        let after = scalars.index(after: j)
        let fields = params.split(separator: ";", omittingEmptySubsequences: false)
        func n(_ index: Int, default def: Int) -> Int {
            guard index < fields.count, !fields[index].isEmpty else { return def }
            return Int(fields[index]) ?? def
        }
        switch final {
        case "A": cursorRow = max(1, cursorRow - max(1, n(0, default: 1)))
        case "B": cursorRow = min(rows, cursorRow + max(1, n(0, default: 1)))
        case "C": cursorCol = min(cols + 1, cursorCol + max(1, n(0, default: 1)))
        case "D": cursorCol = max(1, cursorCol - max(1, n(0, default: 1)))
        case "E": cursorRow = min(rows, cursorRow + max(1, n(0, default: 1))); cursorCol = 1
        case "F": cursorRow = max(1, cursorRow - max(1, n(0, default: 1))); cursorCol = 1
        case "G":
            let c = max(1, n(0, default: 1))
            if c > cols { sawOutOfRange = true }
            cursorCol = min(cols + 1, c)
        case "H", "f":
            let r = max(1, n(0, default: 1))
            let c = max(1, n(1, default: 1))
            if r > rows || c > cols { sawOutOfRange = true }
            cursorRow = min(rows, r)
            cursorCol = min(cols + 1, c)
        case "J", "K":
            break // Erase: no cursor movement.
        case "m":
            break // SGR styling: no cursor movement.
        case "h", "l":
            // Mode set/reset (bracketed paste ?2004, cursor ?25, etc.):
            // no cursor movement. Unknown private modes still move
            // nothing, so they are safe to ignore without latching.
            break
        case "~":
            // Bracketed-paste markers (200~/201~) and friends: no move.
            break
        default:
            sawUnsupported = true
        }
        return after
    }

    private mutating func feedOSC(scalars: [UnicodeScalar], from i: Int) -> Int {
        // OSC ... terminated by BEL or ESC\. Collect raw content.
        var j = i
        var content: [UnicodeScalar] = []
        while j < scalars.endIndex {
            let s = scalars[j]
            if s == "\u{07}" {
                j = scalars.index(after: j)
                break
            }
            if s == "\u{1B}", scalars.index(after: j) < scalars.endIndex,
               scalars[scalars.index(after: j)] == "\\" {
                j = scalars.index(scalars.index(after: j), offsetBy: 1, limitedBy: scalars.endIndex) ?? scalars.endIndex
                break
            }
            content.append(s)
            j = scalars.index(after: j)
        }
        let body = String(String.UnicodeScalarView(content))
        // OSC 0/2 set the window title (PTY-06 oracle); all other
        // operating-system commands are ignored without latching (they
        // move nothing on screen).
        if body.hasPrefix("0;") || body.hasPrefix("2;") {
            title = String(body.dropFirst(2))
        }
        return j
    }
}

/// M4-D D3 transcript allowlist scanner (PTY-06): every ESC byte in a
/// PTY transcript must belong to the harness-emitted set (owner SGR /
/// cursor addressing / erase / bracketed-paste toggles + the replxx
/// line editor's own sequences). Untrusted bytes are sanitized before
/// encoding, so an unlisted sequence is either a sanitizer leak (FAIL)
/// or a harness gap (extend the list with review + evidence).
enum VTAllowlist {
    /// Returns the first unlisted escape sequence, or nil when clean.
    static func violation(in transcript: String) -> String? {
        let scalars = Array(transcript.unicodeScalars)
        var i = scalars.startIndex
        while i < scalars.endIndex {
            guard scalars[i] == "\u{1B}" else {
                i = scalars.index(after: i)
                continue
            }
            let start = i
            var j = scalars.index(after: i)
            guard j < scalars.endIndex else { return "dangling ESC at end" }
            let first = scalars[j]
            j = scalars.index(after: j)
            if first == "[" {
                while j < scalars.endIndex {
                    let v = scalars[j].value
                    if (v >= 0x30 && v <= 0x3F) || (v >= 0x20 && v <= 0x2F) {
                        j = scalars.index(after: j)
                    } else {
                        break
                    }
                }
                guard j < scalars.endIndex else { return "dangling CSI at end" }
                let final = scalars[j]
                j = scalars.index(after: j)
                if !Self.allowedCSI(final) {
                    return "unlisted CSI ..." + String(String.UnicodeScalarView(scalars[start..<j]))
                }
            } else if first == "]" {
                // OSC: consume through BEL / ESC\.
                var done = false
                while j < scalars.endIndex, !done {
                    let s = scalars[j]
                    if s == "\u{07}" { j = scalars.index(after: j); done = true }
                    else if s == "\u{1B}" {
                        let k = scalars.index(after: j)
                        if k < scalars.endIndex, scalars[k] == "\\" {
                            j = scalars.index(after: k); done = true
                        } else {
                            j = scalars.index(after: j)
                        }
                    } else {
                        j = scalars.index(after: j)
                    }
                }
                return "OSC sequence (never harness-emitted): " + String(String.UnicodeScalarView(scalars[start..<j]))
            } else if first == "(" || first == ")" || first == "#" || first == "M" || first == "=" || first == ">" {
                if first == "(" || first == ")" || first == "#" {
                    if j < scalars.endIndex { j = scalars.index(after: j) }
                }
            } else {
                return "unlisted ESC byte: " + String(String.UnicodeScalarView(scalars[start..<j]))
            }
            i = j
            _ = start
        }
        return nil
    }

    /// Harness-emitted CSI finals: cursor (A-H, f), erase (J/K),
    /// styling (m), mode toggles (h/l), paste markers (~).
    private static func allowedCSI(_ final: UnicodeScalar) -> Bool {
        switch final {
        case "A", "B", "C", "D", "E", "F", "G", "H", "f", "J", "K", "m", "h", "l", "~":
            return true
        default:
            return false
        }
    }
}
