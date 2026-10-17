import Testing
import Foundation
import NeedletailCore

/// CFG-06 — reserved native request-options overrides are rejected before
/// serialization; only the inert operator namespace passes, with unknown
/// non-reserved keys marked unqualified. Forbidden: silent strip/rewrite,
/// serializing a reserved key, any request.
struct RequestOptionsTests {

    @Test("CFG-06 every reserved key is rejected at the top level")
    func CFG_06_reservedKeysRejected() throws {
        let reserved = ["model", "messages", "input", "tools", "tool_choice", "parallel_tool_calls",
                        "stream", "stream_options", "system", "history", "auth", "authorization",
                        "api_key", "credentials", "proxy", "base_url", "url", "endpoint",
                        "response_format", "store", "metadata"]
        for key in reserved {
            let model = ConfigTestHelpers.modelJSON(options: #"{"\#(key)":"evil"}"#)
            try ConfigTestHelpers.expectFailure(
                ConfigTestHelpers.configJSON(models: [model]),
                kind: .reservedOverride, pathFragment: "request_options")
        }
    }

    @Test("CFG-06 reserved match is case-insensitive with separators collapsed")
    func CFG_06_reservedCaseVariantsRejected() throws {
        for key in ["API_KEY", "Authorization", "apiKey", "X-Api-Key", "TOOL_CHOICE", "Base-URL", "STREAM"] {
            let model = ConfigTestHelpers.modelJSON(options: #"{"\#(key)":"evil"}"#)
            try ConfigTestHelpers.expectFailure(
                ConfigTestHelpers.configJSON(models: [model]),
                kind: .reservedOverride, pathFragment: "request_options")
        }
    }

    @Test("CFG-06 nested reserved names are ordinary operator data")
    func CFG_06_nestedReservedNamesAllowed() throws {
        let model = ConfigTestHelpers.modelJSON(options: #"{"mytool":{"model":"x","auth":"y"}}"#)
        let snapshot = try ConfigTestHelpers.validateData(ConfigTestHelpers.configJSON(models: [model]))
        let profile = try #require(snapshot.profiles["local-coder"])
        #expect(profile.unqualifiedOptions == ["mytool"])
    }

    @Test("CFG-06 unknown non-reserved keys pass as unqualified, never silent")
    func CFG_06_unqualifiedAllowed() throws {
        let model = ConfigTestHelpers.modelJSON(options: #"{"temperature":0.2,"cache_prompt":true}"#)
        let snapshot = try ConfigTestHelpers.validateData(ConfigTestHelpers.configJSON(models: [model]))
        let profile = try #require(snapshot.profiles["local-coder"])
        #expect(profile.unqualifiedOptions.sorted() == ["cache_prompt", "temperature"])
        #expect(!profile.redactedDescription.contains("0.2"), "values never rendered: \(profile.redactedDescription)")
    }

    @Test("CFG-06 canonical form is deterministic across key order and runs")
    func CFG_06_canonicalDeterministic() throws {
        let a = ConfigTestHelpers.modelJSON(options: #"{"b":1,"a":{"z":true,"y":1.5}}"#)
        let b = ConfigTestHelpers.modelJSON(options: #"{"a":{"y":1.5,"z":true},"b":1}"#)
        let sa = try ConfigTestHelpers.validateData(ConfigTestHelpers.configJSON(models: [a]))
        let sb = try ConfigTestHelpers.validateData(ConfigTestHelpers.configJSON(models: [b]))
        let pa = try #require(sa.profiles["local-coder"])
        let pb = try #require(sb.profiles["local-coder"])
        // Same semantic content reorders to the same canonical bytes ...
        #expect(canonicalJSONData(.object(pa.requestOptions)) == canonicalJSONData(.object(pb.requestOptions)))
        // ... while the retained raw bytes stay verbatim for epoch comparison.
        #expect(pa.requestOptionsRaw != pb.requestOptionsRaw)
        #expect(requiresNewEpoch(old: pa, new: pb), "byte-differing raw options are an epoch change")
        #expect(!requiresNewEpoch(old: pa, new: pa))
    }
}
