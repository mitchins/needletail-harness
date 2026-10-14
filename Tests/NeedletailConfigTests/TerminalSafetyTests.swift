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
        }
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
}
