/// H2 — terminal-safe display boundary (CFG diagnostics contract +
/// presentation-safety spirit; TOOL-12/TERM grade, M1-A scope). Operator-
/// supplied names (aliases, model IDs, credential references, field paths)
/// may contain terminal control bytes smuggled through JSON `\u` escapes.
/// The data model keeps the exact bytes; every diagnostic rendering passes
/// through `terminalSafe`, which rewrites each control scalar as a visible
/// `\u{hex}` escape. Newlines become `\u{a}`, so hostile input can neither
/// execute sequences nor forge log lines.
///
/// TOOL-12: Unicode format (Cf) scalars — bidirectional overrides and
/// isolates (U+202A–202E, U+2066–2069), direction marks (U+200E/200F,
/// U+061C), and zero-width marks (U+200B–200D, U+FEFF) — are additionally
/// neutralized to U+FFFD. These are invisible by definition: left in
/// place they reorder displayed text (bidi) or hide content (zero-width),
/// forging operator-visible output without touching stored bytes. Cc
/// keeps the historical `\u{hex}` rendering (CFG-02/05 pin it); Cf has
/// no visible rendering to preserve, so U+FFFD (the contract replacement)
/// marks the redaction visibly. Display boundary only — stored bytes and
/// export semantics are unchanged.
public func terminalSafe(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.count)
    for scalar in text.unicodeScalars {
        switch scalar.properties.generalCategory {
        case .control:
            out += "\\u{\(String(scalar.value, radix: 16))}"
        case .format:
            out.unicodeScalars.append(Unicode.Scalar(0xFFFD)!)
        default:
            out.unicodeScalars.append(scalar)
        }
    }
    return out
}
