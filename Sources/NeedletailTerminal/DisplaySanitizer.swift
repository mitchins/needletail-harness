/// M4-C display sanitizer (NeedletailTerminal pre-emit boundary).
///
/// `terminalSafe` (Core) stays the store/projection boundary. This is the
/// SEPARATE pre-emit boundary for RAW tap bytes only: content the adapter
/// renders with ANSI styling. ZWJ-bearing text must never pass through
/// `render()`/`terminalSafe` (which maps all Cf to U+FFFD).
///
/// Every adapter writer path sanitizes BEFORE the emit call:
/// `TerminalOutputOwner` sanitizes `emitText`/progress text and only
/// accepts pre-sanitized spans for `emit` (rendered frames arrive via
/// `terminalSafe`; tap blocks via this sanitizer in the renderer).
/// `LineEditorSession.emit` requires sanitized input — the owner is
/// the only production caller and only ever hands it sanitized bytes
/// (encoded spans, sanitized progress/clears); asserted by the
/// pipeline tests on the final byte stream.
///
/// Policy (deny-by-default on Cf): the ONLY preserved Cf scalar is ZWJ
/// (U+200D, keeps emoji sequences joinable to the cluster-safe wrapper).
/// Every other Cf (U+00AD, U+0600–0605, U+2060–2069 incl. word joiner,
/// U+206A–206F, U+FFF9–FFFB, tags U+E0020–E007F, bidi U+202A–202E,
/// direction marks U+200E/200F/U+061C, ZWSP/ZWNJ/BOM, …) becomes U+FFFD.
/// Combining marks (Mn/Mc/Me) are not Cf and pass through untouched.
///
/// Additionally neutralized: all C0/C1 controls EXCEPT LF (U+000A, the
/// line boundary) — each becomes a visible `\u{hex}` escape, incl. NUL
/// → `\u{0}` (also fixes `LineEditorSession.emit`'s `strlen`
/// truncation, since no NUL ever reaches the emit path) and CR →
/// `\u{d}` (CR is rejected visibly, never a carriage return). ESC
/// (U+001B) → `\u{1b}`, which neutralizes every ESC-introduced
/// sequence (CSI/OSC/DCS/SOS/PM/APC) by removing its introducer.
/// TAB expands to the next 8-stop (SPEC ¶805). DEL → `\u{7f}`.
///
/// Links render text-first (`text (url)`), never OSC-8 — enforced by
/// the renderer, which never emits hyperlink sequences at all.
public func displaySafe(_ text: String, tabWidth: Int = 8) -> String {
    var out = ""
    out.reserveCapacity(text.count)
    var column = 0
    for scalar in text.unicodeScalars {
        let v = scalar.value
        switch v {
        case 0x0A:
            // LF: the only preserved control — the line boundary.
            out.unicodeScalars.append(scalar)
            column = 0
        case 0x09:
            // TAB → spaces to next stop (SPEC ¶805 expansion).
            let next = ((column / tabWidth) + 1) * tabWidth
            let spaces = next - column
            for _ in 0 ..< spaces { out.append(" ") }
            column = next
        case 0x200D:
            // ZWJ: the single preserved Cf scalar.
            out.unicodeScalars.append(scalar)
        case 0x2028, 0x2029:
            // Zl/Zp line/paragraph separators disturb line layout:
            // visible, never structural.
            out += "\\u{\(String(v, radix: 16))}"
        default:
            switch scalar.properties.generalCategory {
            case .control:
                out += "\\u{\(String(v, radix: 16))}"
            case .format:
                // Deny-by-default: every non-ZWJ Cf → replacement.
                out.unicodeScalars.append(Unicode.Scalar(0xFFFD)!)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        // Column tracks the current visual line for TAB stops. Newline
        // resets above; other scalars advance by one (grapheme-cluster
        // width stays the M4-B rule — wcwidth is out of scope).
        if v != 0x0A, v != 0x09 {
            column += 1
        }
    }
    return out
}
