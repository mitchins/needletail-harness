import Testing
import Foundation
import NeedletailCore

/// CFG-01 — duplicate model IDs and duplicate JSON keys, including nested
/// keys. Given crafted configuration bytes, when the bounded preflight +
/// validation pipeline runs, then every duplicate is rejected with its field
/// path before any provider request. Forbidden: silent first-wins/last-wins,
/// partial profile construction, any network effect.
struct ConfigPreflightTests {

    @Test("CFG-01 top-level duplicate keys are rejected")
    func CFG_01_topLevelDuplicateKeysRejected() throws {
        let data = Data(#"{"version":1,"version":2,"default_model":"a","allow_http_origins":[],"models":[],"tools":{}}"#.utf8)
        try ConfigTestHelpers.expectFailure(data, kind: .duplicateKey, pathFragment: "$.version")
    }

    @Test("CFG-01 nested duplicate keys inside a model are rejected")
    func CFG_01_nestedDuplicateKeysRejected() throws {
        let model = #"{"alias":"a","alias":"b","protocol":"openai-chat-completions","base_url":"http://127.0.0.1:11434","model":"m","context_window":100,"max_output":10,"locality":"local","connect_timeout_s":1,"read_idle_timeout_s":2,"request_timeout_s":3,"max_in_flight":1}"#
        let data = ConfigTestHelpers.configJSON(models: [model])
        try ConfigTestHelpers.expectFailure(data, kind: .duplicateKey, pathFragment: "models[0].alias")
    }

    @Test("CFG-01 deep duplicate keys inside request_options are rejected")
    func CFG_01_deepDuplicateKeysRejected() throws {
        let model = ConfigTestHelpers.modelJSON(options: #"{"temperature":0.2,"temperature":0.9}"#)
        let data = ConfigTestHelpers.configJSON(models: [model])
        try ConfigTestHelpers.expectFailure(data, kind: .duplicateKey, pathFragment: "request_options.temperature")
    }

    @Test("CFG-01 unicode-escaped duplicate keys are still duplicates")
    func CFG_01_unicodeEscapedDuplicateKeysRejected() throws {
        // "\u0061lias" decodes to "alias": the scanner must compare decoded
        // scalars, not raw bytes.
        let model = #"{"alias":"a","\u0061lias":"b","protocol":"openai-chat-completions","base_url":"http://127.0.0.1:11434","model":"m","context_window":100,"max_output":10,"locality":"local","connect_timeout_s":1,"read_idle_timeout_s":2,"request_timeout_s":3,"max_in_flight":1}"#
        let data = ConfigTestHelpers.configJSON(models: [model])
        try ConfigTestHelpers.expectFailure(data, kind: .duplicateKey, pathFragment: "models[0].alias")
    }

    @Test("CFG-01 surrogate-pair versus literal duplicate keys are rejected")
    func CFG_01_surrogateDuplicateKeysRejected() throws {
        // S3: one key is the literal emoji, the other the \uD83D\uDE00
        // escape — this exercises pair combination, not literal equality.
        let model = "{\"😀\":1,\"\\uD83D\\uDE00\":2,\"alias\":\"a\",\"protocol\":\"openai-chat-completions\",\"base_url\":\"http://127.0.0.1:11434\",\"model\":\"m\",\"context_window\":100,\"max_output\":10,\"locality\":\"local\",\"connect_timeout_s\":1,\"read_idle_timeout_s\":2,\"request_timeout_s\":3,\"max_in_flight\":1}"
        let data = ConfigTestHelpers.configJSON(models: [model])
        try ConfigTestHelpers.expectFailure(data, kind: .duplicateKey)
    }

    @Test("CFG-01 lone surrogates are malformed, never keys")
    func CFG_01_loneSurrogateRejected() throws {
        for text in ["{\"\\uD83D\":1}", "{\"\\uDE00\":1}", "{\"\\uD83D\\u0041\":1}"] {
            do {
                _ = try scanJSONStructure(Array(text.utf8))
                Issue.record("lone surrogate must fail: \(text)")
            } catch let error as ConfigError {
                #expect(error.kind == .malformedJSON, "\(text): got \(error.kind)")
            }
        }
    }

    @Test("CFG-01 duplicate model aliases are rejected")
    func CFG_01_duplicateAliasesRejected() throws {
        let data = ConfigTestHelpers.configJSON(models: [
            ConfigTestHelpers.modelJSON(alias: "a"),
            ConfigTestHelpers.modelJSON(alias: "a"),
        ])
        try ConfigTestHelpers.expectFailure(data, kind: .duplicateKey, pathFragment: "models[1].alias")
    }

    @Test("CFG-01 duplicate endpoint plus model identity is rejected")
    func CFG_01_duplicateEndpointModelRejected() throws {
        let data = ConfigTestHelpers.configJSON(
            models: [
                ConfigTestHelpers.modelJSON(alias: "a", model: "same-id"),
                ConfigTestHelpers.modelJSON(alias: "b", model: "same-id"),
            ],
            defaultModel: "a"
        )
        try ConfigTestHelpers.expectFailure(data, kind: .duplicateKey, pathFragment: "models[1]")
    }

    @Test("CFG-01 endpoint identity is origin-normalized, not string-compared")
    func CFG_01_duplicateEndpointNormalized() throws {
        // S5: host case differs in the verbatim base but normalizes to one
        // origin — a string-compared identity would miss this duplicate.
        let data = ConfigTestHelpers.configJSON(
            models: [
                ConfigTestHelpers.modelJSON(alias: "a", base: "http://Example.COM:11434", model: "same-id"),
                ConfigTestHelpers.modelJSON(alias: "b", base: "http://example.com:11434", model: "same-id"),
            ],
            defaultModel: "a",
            origins: #"["http://example.com:11434"]"#
        )
        try ConfigTestHelpers.expectFailure(data, kind: .duplicateKey, pathFragment: "models[1]")
    }

    @Test("CFG-01 same model ID on different endpoints is legal")
    func CFG_01_sameModelIDDifferentEndpointsAccepted() throws {
        let data = ConfigTestHelpers.configJSON(
            models: [
                ConfigTestHelpers.modelJSON(alias: "a", base: "http://127.0.0.1:11434", model: "same-id"),
                ConfigTestHelpers.modelJSON(alias: "b", base: "http://127.0.0.1:11435", model: "same-id"),
            ],
            defaultModel: "a",
            origins: #"["http://127.0.0.1:11434","http://127.0.0.1:11435"]"#
        )
        let snapshot = try ConfigTestHelpers.validateData(data)
        #expect(snapshot.profiles.count == 2)
    }

    @Test("CFG-01 case-sensitive aliases are distinct")
    func CFG_01_caseSensitiveAliasesDistinct() throws {
        // Same base is fine only with distinct served IDs: the alias check
        // is case-sensitive while the endpoint-identity check still applies.
        let data = ConfigTestHelpers.configJSON(
            models: [
                ConfigTestHelpers.modelJSON(alias: "A", model: "id-one"),
                ConfigTestHelpers.modelJSON(alias: "a", model: "id-two"),
            ],
            defaultModel: "A"
        )
        let snapshot = try ConfigTestHelpers.validateData(data)
        #expect(snapshot.profiles["A"] != nil && snapshot.profiles["a"] != nil)
    }

    @Test("CFG-01 canonically equivalent keys are refused, never merged")
    func CFG_01_canonicalKeyCollisionRejected() throws {
        // Byte-distinct (composed vs decomposed) but canonically equal:
        // a decoded dictionary could not hold both without silent merging.
        let text = "{\"caf\u{00E9}\":1,\"cafe\u{0301}\":2}"
        do {
            _ = try scanJSONStructure(Array(text.utf8))
            Issue.record("canonically equivalent keys must be refused")
        } catch let error as ConfigError {
            #expect(error.kind == .duplicateKey)
        }
    }

    @Test("CFG-01 duplicate keys fail on bytes alone, without typed decoding")
    func CFG_01_preflightAloneDetectsDuplicates() throws {
        let bytes = Array(#"{"a":1,"a":2}"#.utf8)
        do {
            _ = try scanJSONStructure(bytes)
            Issue.record("preflight accepted a duplicate key")
        } catch let error as ConfigError {
            #expect(error.kind == .duplicateKey)
            #expect(error.path == "$.a")
        }
    }

    @Test("CFG-01 scanner rejects BOM, trailing garbage, depth and truncation")
    func CFG_01_scannerEdgeCases() throws {
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data(#"{"a":1}"#.utf8)
        try ConfigTestHelpers.expectFailure(bom, kind: .unsupportedFormat)
        try ConfigTestHelpers.expectFailure(Data(#"{"a":1} trailing"#.utf8), kind: .malformedJSON)
        try ConfigTestHelpers.expectFailure(Data(#"{"a":{"#.utf8), kind: .malformedJSON)
        var deep = "0"
        for _ in 0..<40 { deep = "[\(deep)]" }
        try ConfigTestHelpers.expectFailure(Data(deep.utf8), kind: .limitExceeded)
        // Depth 32 is exactly legal.
        var ok = "0"
        for _ in 0..<31 { ok = "[\(ok)]" }
        _ = try scanJSONStructure(Array(ok.utf8))
    }
}
