/// H2 — terminal-safe display boundary (CFG diagnostics contract +
/// presentation-safety spirit; TOOL-12/TERM grade, M1-A scope). Operator-
/// supplied names (aliases, model IDs, credential references, field paths)
/// may contain terminal control bytes smuggled through JSON `\u` escapes.
/// The data model keeps the exact bytes; every diagnostic rendering passes
/// through `terminalSafe`, which rewrites each control scalar as a visible
/// `\u{hex}` escape. Newlines become `\u{a}`, so hostile input can neither
/// execute sequences nor forge log lines.
public func terminalSafe(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.count)
    for scalar in text.unicodeScalars {
        if scalar.properties.generalCategory == .control {
            out += "\\u{\(String(scalar.value, radix: 16))}"
        } else {
            out.unicodeScalars.append(scalar)
        }
    }
    return out
}
