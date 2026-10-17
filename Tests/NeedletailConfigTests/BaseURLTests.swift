import Testing
import Foundation
import NeedletailCore

/// CFG-02 (URL half, rev4-A + rev5 D1/D2) — explicit API path prefixes are
/// preserved verbatim and joined once; origins stay origin-only and are
/// never widened by a prefix. Forbidden: prefix drop/duplication, origin
/// widening, silent `/v1` guessing, any network effect.
struct BaseURLTests {

    @Test("CFG-02 configured path prefix is preserved in the endpoint")
    func CFG_02_basePrefixPreserved() throws {
        let snapshot = try ConfigTestHelpers.validateData(ConfigTestHelpers.configJSON(
            models: [ConfigTestHelpers.modelJSON(base: "http://127.0.0.1:11434/v1")]))
        let profile = try #require(snapshot.profiles["local-coder"])
        #expect(profile.origin == "http://127.0.0.1:11434")
        #expect(profile.pathPrefix == "/v1")
        #expect(endpointURL(for: profile) == "http://127.0.0.1:11434/v1/chat/completions")
    }

    @Test("CFG-02 unconditional v1 prepend is caught, never duplicated")
    func CFG_02_noDupV1() throws {
        // Wrong-impl shape: adapter prepends /v1 regardless of configuration.
        // The oracle pins the exact joined bytes, so /v1/v1/... fails.
        let snapshot = try ConfigTestHelpers.validateData(ConfigTestHelpers.configJSON(
            models: [ConfigTestHelpers.modelJSON(base: "http://127.0.0.1:11434/v1")]))
        let profile = try #require(snapshot.profiles["local-coder"])
        let endpoint = endpointURL(for: profile)
        #expect(!endpoint.contains("/v1/v1/"), "duplicated prefix: \(endpoint)")
        #expect(endpoint == "http://127.0.0.1:11434/v1/chat/completions")
        let bare = try ConfigTestHelpers.validateData(ConfigTestHelpers.configJSON())
        let bareProfile = try #require(bare.profiles["local-coder"])
        #expect(endpointURL(for: bareProfile) == "http://127.0.0.1:11434/chat/completions")
    }

    @Test("CFG-02 base already ending in a protocol suffix is rejected")
    func CFG_02_basePrefixAlreadySuffixRejected() throws {
        for suffix in ["/chat/completions", "/responses", "/messages"] {
            let data = ConfigTestHelpers.configJSON(
                models: [ConfigTestHelpers.modelJSON(base: "http://127.0.0.1:11434\(suffix)")])
            try ConfigTestHelpers.expectFailure(data, kind: .malformedOrigin, pathFragment: "base_url")
        }
    }

    @Test("CFG-02 traversal, encoded traversal and malformed paths rejected")
    func CFG_02_baseTraversalRejected() throws {
        for bad in [
            "http://127.0.0.1:11434/v1/../evil",
            "http://127.0.0.1:11434/%2e%2e/evil",
            "http://127.0.0.1:11434/%2E%2E/evil",
            "http://127.0.0.1:11434/.%2e/x",
            "http://127.0.0.1:11434/%2e./x",
            "http://127.0.0.1:11434/%5Cx",
            "http://127.0.0.1:11434/%5Cx/v1",
            "http://127.0.0.1:11434//v1",
            "http://127.0.0.1:11434/\\\\v1",
            "http://127.0.0.1:11434/v1#x",
            "http://127.0.0.1:11434/v1?x=1",
            "http://127.0.0.1:11434/v1 withspace",
            "http://127.0.0.1:11434/v1%20x",
        ] {
            try ConfigTestHelpers.expectFailure(
                ConfigTestHelpers.configJSON(models: [ConfigTestHelpers.modelJSON(base: bad)]),
                kind: .malformedOrigin, pathFragment: "base_url")
        }
    }

    @Test("CFG-02 C1 controls in hosts are rejected at load")
    func CFG_02_c1HostRejected() throws {
        // H2-2: U+0085 (NEL) in a host must fail closed at parse, never
        // reach origin/endpoint display strings.
        try ConfigTestHelpers.expectFailure(
            ConfigTestHelpers.configJSON(models: [ConfigTestHelpers.modelJSON(base: "http://ex\\u0085ample.com:11434")]),
            kind: .malformedOrigin, pathFragment: "base_url")
    }

    @Test("CFG-02 credentials in base URLs are rejected")
    func CFG_02_baseCredentialsRejected() throws {
        try ConfigTestHelpers.expectFailure(
            ConfigTestHelpers.configJSON(models: [ConfigTestHelpers.modelJSON(base: "http://user:pass@127.0.0.1:11434/v1")]),
            kind: .malformedOrigin, pathFragment: "base_url")
    }

    @Test("CFG-02 origin is derived by discarding the prefix, never widened")
    func CFG_02_originDerivedFromPrefixedBase() throws {
        // Prefixed base matches the origin-only entry ...
        let snapshot = try ConfigTestHelpers.validateData(ConfigTestHelpers.configJSON(
            models: [ConfigTestHelpers.modelJSON(base: "http://127.0.0.1:11434/v1")]))
        #expect(snapshot.profiles["local-coder"] != nil)
        // ... but a different host or port with the same prefix does not.
        for other in ["http://127.0.0.2:11434/v1", "http://127.0.0.1:9999/v1"] {
            try ConfigTestHelpers.expectFailure(
                ConfigTestHelpers.configJSON(models: [ConfigTestHelpers.modelJSON(base: other)]),
                kind: .originNotAllowlisted, pathFragment: "base_url")
        }
    }

    @Test("CFG-02 default ports compare equal to bare origins")
    func CFG_02_originDefaultPortEquality() throws {
        #expect(try parseOriginEntry("http://h", path: "$") == parseOriginEntry("http://h:80", path: "$"))
        #expect(try parseOriginEntry("https://h", path: "$") == parseOriginEntry("https://h:443", path: "$"))
        #expect(try parseOriginEntry("http://h", path: "$") != parseOriginEntry("http://h:81", path: "$"))
        // Host case is insignificant; a path in an entry is malformed.
        #expect(try parseOriginEntry("http://EXAMPLE.com", path: "$") == "http://example.com")
        do {
            _ = try parseOriginEntry("http://127.0.0.1:11434/v1", path: "$")
            Issue.record("origin entry with a path must be rejected")
        } catch let error as ConfigError {
            #expect(error.kind == .malformedOrigin)
        }
    }
}
