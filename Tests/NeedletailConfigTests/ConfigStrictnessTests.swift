import Testing
import Foundation
import NeedletailCore

/// CFG-02 (non-URL half) — unknown fields, bad limits, missing references.
/// Given malformed configuration, when validated, then a field-path error
/// names the exact location with an actionable hint. Forbidden: silent
/// ignore, default substitution, any provider request.
struct ConfigStrictnessTests {

    @Test("CFG-02 unknown top-level fields are rejected with vocabulary hint")
    func CFG_02_unknownTopLevelFieldRejected() throws {
        let text = """
        {"version":1,"default_model":"local-coder","allow_http_origins":[],"models":[],"tools":{},"zzz":1}
        """
        let error = try ConfigTestHelpers.expectFailure(Data(text.utf8), kind: .unknownField, pathFragment: "$.zzz")
        #expect(error.hint.contains("version"), "hint must name allowed fields: \(error.hint)")
    }

    @Test("CFG-02 unknown model and tools fields are rejected")
    func CFG_02_unknownNestedFieldsRejected() throws {
        var model = ConfigTestHelpers.modelJSON()
        model = String(model.dropLast()) + #","bogus":1}"#
        try ConfigTestHelpers.expectFailure(ConfigTestHelpers.configJSON(models: [model]), kind: .unknownField, pathFragment: "bogus")
        try ConfigTestHelpers.expectFailure(
            ConfigTestHelpers.configJSON(tools: #"{"read":true,"bogus":true}"#),
            kind: .unknownField, pathFragment: "$.tools.bogus")
    }

    @Test("CFG-02 negative, zero and contradictory limits are rejected")
    func CFG_02_badLimitsRejected() throws {
        var negative = ConfigTestHelpers.modelJSON()
        negative = negative.replacingOccurrences(of: "\"context_window\":262144", with: "\"context_window\":-1")
        try ConfigTestHelpers.expectFailure(ConfigTestHelpers.configJSON(models: [negative]), kind: .limitExceeded, pathFragment: "context_window")
        var zero = ConfigTestHelpers.modelJSON()
        zero = zero.replacingOccurrences(of: "\"max_output\":4096", with: "\"max_output\":0")
        try ConfigTestHelpers.expectFailure(ConfigTestHelpers.configJSON(models: [zero]), kind: .limitExceeded, pathFragment: "max_output")
        var order = ConfigTestHelpers.modelJSON()
        order = order
            .replacingOccurrences(of: "\"connect_timeout_s\":10", with: "\"connect_timeout_s\":100")
            .replacingOccurrences(of: "\"request_timeout_s\":1800", with: "\"request_timeout_s\":50")
        try ConfigTestHelpers.expectFailure(
            ConfigTestHelpers.configJSON(models: [order]),
            kind: .unsupportedCombination, pathFragment: "models[0]")
    }

    @Test("CFG-02 missing alias references and required fields fail")
    func CFG_02_missingReferencesRejected() throws {
        try ConfigTestHelpers.expectFailure(
            ConfigTestHelpers.configJSON(defaultModel: "ghost"),
            kind: .missingReference, pathFragment: "$.default_model")
        var noLocality = ConfigTestHelpers.modelJSON()
        noLocality = noLocality.replacingOccurrences(of: #","locality":"local""#, with: "")
        try ConfigTestHelpers.expectFailure(
            ConfigTestHelpers.configJSON(models: [noLocality]),
            kind: .missingField, pathFragment: "locality")
        let noDefault = """
        {"version":1,"allow_http_origins":[],"models":[],"tools":{}}
        """
        try ConfigTestHelpers.expectFailure(Data(noDefault.utf8), kind: .missingField, pathFragment: "default_model")
    }

    @Test("CFG-02 bad versions are rejected without silent defaulting")
    func CFG_02_badVersionsRejected() throws {
        // Non-integer JSON never coerces to a version ...
        for version in ["\"1\"", "1.5", "true"] {
            try ConfigTestHelpers.expectFailure(
                ConfigTestHelpers.configJSON(version: version),
                kind: .typeMismatch, pathFragment: "$.version")
        }
        // ... and an unknown integer version fails closed, never migrates.
        try ConfigTestHelpers.expectFailure(
            ConfigTestHelpers.configJSON(version: "99"),
            kind: .unsupportedCombination, pathFragment: "$.version")
    }

    @Test("CFG-02 oversized files are rejected before unbounded decoding")
    func CFG_02_oversizedFileRejected() throws {
        let padding = String(repeating: " ", count: ConfigLimits.maxFileBytes + 8)
        let data = Data(("{\"version\":1,\"default_model\":\"a\",\"allow_http_origins\":[],\"models\":[],\"tools\":{}}" + padding).utf8)
        try ConfigTestHelpers.expectFailure(data, kind: .fileTooLarge, pathFragment: "$")
    }

    @Test("CFG-02 oversized request_options are rejected")
    func CFG_02_oversizedRequestOptionsRejected() throws {
        let big = String(repeating: "x", count: ConfigLimits.maxRequestOptionsBytes + 1)
        let model = ConfigTestHelpers.modelJSON(options: #"{"blob":"\#(big)"}"#)
        try ConfigTestHelpers.expectFailure(
            ConfigTestHelpers.configJSON(models: [model]),
            kind: .limitExceeded, pathFragment: "request_options")
    }

    @Test("CFG-02 unknown protocol, locality and exec values are rejected")
    func CFG_02_unknownEnumsRejected() throws {
        try ConfigTestHelpers.expectFailure(
            ConfigTestHelpers.configJSON(models: [ConfigTestHelpers.modelJSON(proto: "carrier-pigeon")]),
            kind: .typeMismatch, pathFragment: "protocol")
        try ConfigTestHelpers.expectFailure(
            ConfigTestHelpers.configJSON(models: [ConfigTestHelpers.modelJSON(locality: "edge")]),
            kind: .typeMismatch, pathFragment: "locality")
        try ConfigTestHelpers.expectFailure(
            ConfigTestHelpers.configJSON(tools: #"{"exec":"sometimes"}"#),
            kind: .typeMismatch, pathFragment: "exec")
    }
}
