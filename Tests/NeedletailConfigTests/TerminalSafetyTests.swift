import Testing
import Foundation
import NeedletailCore

/// H2 — terminal-safe configuration diagnostics (CFG field-path/usefulness
/// contract + presentation-safety spirit; no catalogue renumbering).
/// Control bytes in operator-supplied names must render as visible escapes
/// at the display boundary while the data model keeps the exact bytes.
/// Given hostile names, when diagnostics render, then stdout/stderr carry
/// no executable terminal sequences. Forbidden: raw ESC/CSI/OSC/CR/BS/LF
/// in any diagnostic string; normalizing or dropping the stored value.
struct TerminalSafetyTests {
    /// ESC, CSI, OSC+ BEL, CR, backspace, LF, DEL, C1 — each must render
    /// visibly and never execute.
    static let hostileNames = [
        "x\u{1B}[2J",
        "y\u{1B}]0;title\u{07}",
        "z\r\noverwrite",
        "w\u{08}back",
        "v\u{7F}del",
        "u\u{85}c1",
    ]

    static func assertTerminalSafe(
        _ text: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let isControl = (v < 0x20) || (v >= 0x7F && v <= 0x9F)
            #expect(!isControl, "raw control U+\(String(format: "%04X", v)) must render visibly", sourceLocation: sourceLocation)
            #expect(scalar.properties.generalCategory != .format, "raw format U+\(String(format: "%04X", v)) must render visibly", sourceLocation: sourceLocation)
        }
    }

    /// TOOL-12: per-class neutralization. Each hostile scalar becomes exactly
    /// one U+FFFD; surrounding text is byte-identical.
    static let bidiOverrides: [UInt32] = [0x202A, 0x202B, 0x202C, 0x202D, 0x202E]
    static let bidiIsolates: [UInt32] = [0x2066, 0x2067, 0x2068, 0x2069]
    static let directionMarks: [UInt32] = [0x200E, 0x200F, 0x061C]
    static let zeroWidth: [UInt32] = [0x200B, 0x200C, 0x200D, 0xFEFF]

    private static let fffd = String(Unicode.Scalar(0xFFFD)!)

    private static func expectFFFD(_ value: UInt32, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let input = "a\(Unicode.Scalar(value)!)b"
        let out = terminalSafe(input)
        #expect(out == "a" + Self.fffd + "b", "\(label) U+\(String(format: "%04X", value)) must become U+FFFD, got \(out.debugDescription)", sourceLocation: sourceLocation)
    }

    @Test("CFG-02 diagnostics escape terminal controls in paths and messages")
    func CFG_02_diagnosticsEscapeControls() throws {
        for nasty in Self.hostileNames {
            let error = ConfigError(
                path: "$.models[0].alias\(nasty)", kind: .duplicateKey,
                message: "duplicate model alias '\(nasty)'.",
                hint: "rename \(nasty).")
            Self.assertTerminalSafe(error.description)
            #expect(error.description.contains("duplicateKey"), "kind stays machine-readable")
            #expect(error.description.contains("$.models[0].alias"), "field path stays exact")
        }
    }

    @Test("CFG-05 hostile identities stay byte-exact while diagnostics escape")
    func CFG_05_hostileIdentitiesPreservedAndEscaped() throws {
        // Swift-level "\\u001b" becomes JSON-level \u001b, which decodes to
        // a raw ESC in the stored alias (strict JSON forbids raw controls,
        // so the escape form is the only way in).
        let nastyJSON = "m\\u001b[2Jodel"
        let nasty = "m\u{1B}[2Jodel"
        let snapshot = try ConfigTestHelpers.validateData(ConfigTestHelpers.configJSON(
            models: [ConfigTestHelpers.modelJSON(alias: nastyJSON, model: "id-\\u0007")],
            defaultModel: nastyJSON))
        // Data model preserves the exact bytes (lookup by the raw alias).
        let profile = try #require(snapshot.profiles[nasty], "stored alias must stay byte-exact")
        #expect(profile.alias == nasty && profile.modelID == "id-\u{07}")
        // Display boundary escapes every control as \u{hex}.
        Self.assertTerminalSafe(profile.redactedDescription)
        Self.assertTerminalSafe(snapshot.redactedDescription)
        #expect(profile.redactedDescription.contains("\\u{1b}"),
                "ESC must render visibly as \\u{1b}: \(profile.redactedDescription)")
    }

    @Test("CFG-02 credential references escape controls, keep the reference")
    func CFG_02_credentialReferenceEscaped() throws {
        let ref = CredentialReference(kind: .env(name: "K\u{1B}[2JEY"))
        Self.assertTerminalSafe(ref.redactedDescription)
        #expect(ref.redactedDescription.hasPrefix("env:"), "reference shape stays: \(ref.redactedDescription)")
    }

    @Test("TOOL_12_bidiOverridesNeutralized")
    func tool12BidiOverrides() {
        for v in Self.bidiOverrides { Self.expectFFFD(v, "override") }
    }

    @Test("TOOL_12_bidiIsolatesNeutralized")
    func tool12BidiIsolates() {
        for v in Self.bidiIsolates { Self.expectFFFD(v, "isolate") }
    }

    @Test("TOOL_12_directionMarksNeutralized")
    func tool12DirectionMarks() {
        for v in Self.directionMarks { Self.expectFFFD(v, "direction mark") }
    }

    @Test("TOOL_12_zeroWidthMarksNeutralized")
    func tool12ZeroWidth() {
        for v in Self.zeroWidth { Self.expectFFFD(v, "zero-width") }
    }

    @Test("TOOL_12_c0c1KeepHexRendering")
    func tool12C0C1KeepHex() {
        // Cc behavior is pinned (CFG-02/05 depend on it): controls still
        // render as visible \u{hex}, never raw and never FFFD.
        #expect(terminalSafe("x\u{1B}[2J") == "x\\u{1b}[2J")
        #expect(terminalSafe("u\u{85}c1") == "u\\u{85}c1")
        #expect(!terminalSafe("x\u{1B}").contains(Self.fffd), "Cc must not become FFFD")
    }

    @Test("TOOL_12_displayBoundaryOnlyStoredBytesUnchanged")
    func tool12DisplayBoundaryOnly() {
        // The sanitizer returns a new string; the input (the stored value)
        // is never mutated, and non-hostile bytes pass through exactly.
        let stored = "price\u{200B}:\u{202E} 100"
        let snapshot = stored
        let out = terminalSafe(stored)
        #expect(stored == snapshot, "input untouched: display boundary only")
        #expect(out == "price" + Self.fffd + ":" + Self.fffd + " 100")
        // Binary byte proof: no ESC byte and no hostile scalar encodings in
        // the output; FFFD (EF BF BD) marks each redaction.
        let bytes = Array(out.utf8)
        #expect(!bytes.contains(0x1B), "0 ESC bytes in sanitized output")
        #expect(!out.unicodeScalars.contains(where: { $0.properties.generalCategory == .format }), "no Cf scalars survive")
        var fffdCount = 0
        for i in 0..<(bytes.count - 2) {
            if bytes[i] == 0xEF && bytes[i + 1] == 0xBF && bytes[i + 2] == 0xBD { fffdCount += 1 }
        }
        #expect(fffdCount == 2, "one FFFD per hostile scalar, got \(fffdCount)")
        Self.assertTerminalSafe(out)
    }

    @Test("TOOL_12_ccOnlySanitizerCounterfactual")
    func tool12CcOnlyCounterfactual() {
        // The OLD Cc-only implementation demonstrably lets bidi and
        // zero-width marks through: reordering/hiding survives display.
        // This is the hazard TOOL-12 closes (old must pass through,
        // new must neutralize).
        func ccOnly(_ text: String) -> String {
            var out = ""
            for scalar in text.unicodeScalars {
                if scalar.properties.generalCategory == .control {
                    out += "\\u{\(String(scalar.value, radix: 16))}"
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
            return out
        }
        let hostile = "pay\u{202E} 100\u{200B} USD"
        let oldOut = ccOnly(hostile)
        #expect(oldOut == hostile, "counterfactual: Cc-only sanitizer passes bidi/zero-width through unchanged")
        #expect(oldOut.unicodeScalars.contains(Unicode.Scalar(0x202E)!), "counterfactual: RLO survives the old sanitizer")
        let newOut = terminalSafe(hostile)
        #expect(newOut == "pay" + Self.fffd + " 100" + Self.fffd + " USD")
        #expect(!newOut.unicodeScalars.contains(Unicode.Scalar(0x202E)!), "RLO neutralized by the new sanitizer")
    }
}
