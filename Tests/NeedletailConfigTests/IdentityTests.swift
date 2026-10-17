import Testing
import Foundation
import NeedletailCore

/// CFG-05 — opaque string identities: numeric-looking model IDs are never
/// coerced, huge digit strings never become floating point, Unicode aliases
/// are byte-exact, invalid path encoding is explicitly unsupported.
struct IdentityTests {

    @Test("CFG-05 numeric-looking model IDs are preserved as strings")
    func CFG_05_numericLookingIDsPreserved() throws {
        let snapshot = try ConfigTestHelpers.validateData(ConfigTestHelpers.configJSON(
            models: [ConfigTestHelpers.modelJSON(alias: "num", model: "001234")],
            defaultModel: "num"))
        #expect(snapshot.profiles["num"]?.modelID == "001234")
        #expect(snapshot.profiles["num"]?.modelID != "1234")
    }

    @Test("CFG-05 huge digit strings never become floating point")
    func CFG_05_hugeDigitStringsExact() throws {
        let huge = "123456789012345678901234567890"
        let snapshot = try ConfigTestHelpers.validateData(ConfigTestHelpers.configJSON(
            models: [ConfigTestHelpers.modelJSON(alias: "h", model: huge)],
            defaultModel: "h"))
        #expect(snapshot.profiles["h"]?.modelID == huge, "must round-trip exactly, never 1.234e29")
    }

    @Test("CFG-05 JSON numbers for identities are rejected, never coerced")
    func CFG_05_numberForModelRejected() throws {
        var model = ConfigTestHelpers.modelJSON()
        model = model.replacingOccurrences(of: "\"model\":\"qwen2.5-coder-32b\"", with: "\"model\":1234")
        try ConfigTestHelpers.expectFailure(
            ConfigTestHelpers.configJSON(models: [model]),
            kind: .typeMismatch, pathFragment: "model")
        var aliasNum = ConfigTestHelpers.modelJSON()
        aliasNum = aliasNum.replacingOccurrences(of: "\"alias\":\"local-coder\"", with: "\"alias\":7")
        try ConfigTestHelpers.expectFailure(
            ConfigTestHelpers.configJSON(models: [aliasNum]),
            kind: .typeMismatch, pathFragment: "alias")
    }

    @Test("CFG-05 unicode aliases are byte-exact with no normalization")
    func CFG_05_unicodeAliasesExact() throws {
        // "é" as single scalar vs e + combining accent: different bytes,
        // different aliases. NFC must never merge them (Swift String == is
        // canonical, so the precondition compares UTF-8 bytes, as the
        // loader's duplicate check does).
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        #expect(Array(composed.utf8) != Array(decomposed.utf8), "precondition: fixtures really differ in bytes")
        // Each name is usable alone (byte-exact, never merged) ...
        for (alias, id) in [(composed, "id-composed"), (decomposed, "id-decomposed")] {
            let solo = try ConfigTestHelpers.validateData(ConfigTestHelpers.configJSON(
                models: [ConfigTestHelpers.modelJSON(alias: alias, model: id)],
                defaultModel: alias))
            #expect(solo.profiles[alias]?.alias == alias)
        }
        // ... but the pair cannot coexist: the snapshot dictionary could
        // not hold both without silent canonical merging, so the loader
        // refuses loudly instead of normalizing.
        try ConfigTestHelpers.expectFailure(
            ConfigTestHelpers.configJSON(
                models: [
                    ConfigTestHelpers.modelJSON(alias: composed, model: "id-composed"),
                    ConfigTestHelpers.modelJSON(alias: decomposed, model: "id-decomposed"),
                ],
                defaultModel: composed),
            kind: .duplicateKey, pathFragment: "models[1].alias")
    }

    @Test("CFG-05 invalid UTF-8 configuration is explicitly unsupported")
    func CFG_05_invalidEncodingUnsupported() throws {
        var bytes = Array(#"{"version":1,"#.utf8)
        bytes += [0x22, 0xFF, 0xFE, 0x22, 0x3A, 0x31, 0x7D] // "?ÿþ" broken key
        do {
            _ = try validateConfig(Data(bytes))
            Issue.record("invalid UTF-8 must fail")
        } catch let error as ConfigError {
            #expect(error.kind == .unsupportedPathEncoding || error.kind == .malformedJSON,
                    "explicit unsupported/invalid, got \(error.kind)")
        }
    }
}
