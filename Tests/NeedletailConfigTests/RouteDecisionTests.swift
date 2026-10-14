import Testing
import Foundation
import NeedletailCore

/// NET-01 (pure half, rev4-A/B + D3) — local-only routing never becomes
/// cloud routing; sealed tool-free requests to approved local models are
/// permitted; prefixed bases keep their prefix with the origin allow-listed.
/// Forbidden: sockets/DNS/TLS (this layer takes no transport), fallback or
/// retry, credential resolution for denied routes, sealed-caused denials.
struct RouteDecisionTests {

    private static func localSnapshot(extraModels: [String] = [], origins: String? = nil) throws -> ConfigSnapshot {
        var models = [ConfigTestHelpers.modelJSON()]
        models += extraModels
        return try ConfigTestHelpers.validateData(ConfigTestHelpers.configJSON(models: models, origins: origins ?? #"["http://127.0.0.1:11434"]"#))
    }

    @Test("NET-01 local-only profile plus cloud selection denies, no retry")
    func NET_01_localSelectsCloudDenied() throws {
        let snapshot = try Self.localSnapshot(extraModels: [
            ConfigTestHelpers.modelJSON(alias: "cloud-gpt", base: "https://api.example.com", model: "gpt-x", locality: "cloud",
                                        credential: #"{"env":"NT_CLOUD_KEY"}"#),
        ], origins: #"["http://127.0.0.1:11434","https://api.example.com"]"#)
        let route = selectRoute(snapshot: snapshot, requestedAlias: "cloud-gpt", sealed: false)
        guard case .denied(let denial) = route else {
            Issue.record("cloud selection under M1-A must deny, never route")
            return
        }
        #expect(denial.kind == .localOnlyViolation)
        // No fallback: the denial names no alternate provider.
        #expect(!denial.message.contains("127.0.0.1"), "denial must not reroute: \(denial.message)")
    }

    @Test("NET-01 approved local selection is allowed as a decision only")
    func NET_01_localSelectsLocalAllowed() throws {
        let snapshot = try Self.localSnapshot()
        let route = selectRoute(snapshot: snapshot, requestedAlias: "local-coder", sealed: false)
        guard case .allowed(let endpoint, let alias) = route else {
            Issue.record("approved local model must be allowed"); return
        }
        #expect(alias == "local-coder")
        #expect(endpoint == "http://127.0.0.1:11434/chat/completions")
    }

    @Test("NET-01 sealed cloud stays denied, sealed local stays permitted")
    func NET_01_sealedVariants() throws {
        let snapshot = try Self.localSnapshot()
        guard case .denied = selectRoute(snapshot: snapshot, requestedAlias: "cloud-gpt", sealed: true) else {
            Issue.record("sealed cloud must deny"); return
        }
        guard case .allowed = selectRoute(snapshot: snapshot, requestedAlias: "local-coder", sealed: true) else {
            Issue.record("sealed approved-local must permit (tool-free)"); return
        }
        guard case .allowed = selectRoute(snapshot: snapshot, requestedAlias: "local-coder", sealed: false) else {
            Issue.record("tools-none/unsealed approved-local must permit"); return
        }
    }

    @Test("NET-01 route is byte-identical under sealed true and false")
    func NET_01_sealedRouteIdentical() throws {
        let snapshot = try Self.localSnapshot()
        #expect(selectRoute(snapshot: snapshot, requestedAlias: "local-coder", sealed: true)
            == selectRoute(snapshot: snapshot, requestedAlias: "local-coder", sealed: false))
        #expect(selectRoute(snapshot: snapshot, requestedAlias: "cloud-gpt", sealed: true)
            == selectRoute(snapshot: snapshot, requestedAlias: "cloud-gpt", sealed: false))
    }

    @Test("NET-01 unknown aliases fail actionable with no retry")
    func NET_01_unknownAliasDenied() throws {
        let snapshot = try Self.localSnapshot()
        guard case .denied(let denial) = selectRoute(snapshot: snapshot, requestedAlias: "ghost", sealed: false) else {
            Issue.record("unknown alias must deny"); return
        }
        #expect(denial.kind == .unknownAlias)
        #expect(denial.message.contains("ghost"))
    }

    @Test("NET-01 mutated profile state cannot smuggle an unapproved destination")
    func NET_01_mutatedProfileDenied() throws {
        // H1: the old mutable API let post-load state retarget baseURL at
        // an unapproved origin while the stored origin still claimed the
        // allow-list (RED: selectRoute returned allowed). Profiles are now
        // immutable with origin derived at construction, and the decision
        // re-derives from the effective baseURL — inconsistency has no
        // expression left, and every live variant below denies.
        let snapshot = try Self.localSnapshot()
        let local = try #require(snapshot.profiles["local-coder"])
        // A profile retargeted at an unapproved origin is denied even when
        // the snapshot's allow-list is otherwise intact ...
        let retargeted = try ModelProfile(
            alias: local.alias, wireProtocol: local.wireProtocol,
            baseURL: "https://evil.example:443/admin", modelID: local.modelID,
            contextWindow: local.contextWindow, maxOutput: local.maxOutput,
            locality: local.locality, credential: local.credential,
            connectTimeout: local.connectTimeout, readIdleTimeout: local.readIdleTimeout,
            requestTimeout: local.requestTimeout, maxInFlight: local.maxInFlight,
            requestOptions: local.requestOptions, requestOptionsRaw: local.requestOptionsRaw,
            unqualifiedOptions: local.unqualifiedOptions)
        #expect(retargeted.origin == "https://evil.example", "origin derives from the effective base")
        let poisoned = ConfigSnapshot(
            version: snapshot.version, profiles: ["local-coder": retargeted],
            defaultAlias: snapshot.defaultAlias, allowHTTPOrigins: snapshot.allowHTTPOrigins,
            tools: snapshot.tools)
        guard case .denied(let denial) = selectRoute(snapshot: poisoned, requestedAlias: "local-coder", sealed: false) else {
            Issue.record("H1: unapproved effective destination must deny, never route")
            return
        }
        #expect(denial.kind == .originNotAllowlisted, "derived-origin check must fail closed, got \(denial.kind)")
        // ... the dispatch-time entry point agrees ...
        guard case .denied = authorizeRequestDestination(snapshot: poisoned, requestedAlias: "local-coder", sealed: false) else {
            Issue.record("H1: authorizeRequestDestination must agree with selectRoute")
            return
        }
        // ... a snapshot whose allow-list no longer covers the profile
        // denies too (no stale-list routing) ...
        let staleList = ConfigSnapshot(
            version: snapshot.version, profiles: snapshot.profiles,
            defaultAlias: snapshot.defaultAlias, allowHTTPOrigins: [],
            tools: snapshot.tools)
        guard case .denied = selectRoute(snapshot: staleList, requestedAlias: "local-coder", sealed: false) else {
            Issue.record("H1: emptied allow-list must deny")
            return
        }
        // ... while an explicitly approved destination still routes.
        guard case .allowed = selectRoute(snapshot: snapshot, requestedAlias: "local-coder", sealed: false) else {
            Issue.record("H1: approved destinations must keep routing")
            return
        }
    }

    @Test("NET-01 prefixed base keeps its prefix with the origin allowed")
    func NET_01_prefixedBaseEndpointPreserved() throws {
        let snapshot = try Self.localSnapshot(extraModels: [
            ConfigTestHelpers.modelJSON(alias: "prefixed", base: "http://127.0.0.1:11434/v1"),
        ])
        guard case .allowed(let endpoint, _) = selectRoute(snapshot: snapshot, requestedAlias: "prefixed", sealed: false) else {
            Issue.record("prefixed approved-local must be allowed"); return
        }
        #expect(endpoint == "http://127.0.0.1:11434/v1/chat/completions")
    }
}
