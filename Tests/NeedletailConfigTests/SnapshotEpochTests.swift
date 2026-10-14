import Testing
import Foundation
import NeedletailCore

/// CFG-02 (profile-shape half) — snapshots are immutable `let` values and
/// `requiresNewEpoch` fires on every incompatible profile change. The
/// predicate is owned here; the epoch transition that consumes it is M1-B.
/// Given two snapshots, when compared, then identity/route/generation
/// changes force a new epoch while identical snapshots never do.
struct SnapshotEpochTests {

    private static func profile(alias: String = "local-coder", base: String = "http://127.0.0.1:11434") throws -> ModelProfile {
        let snapshot = try ConfigTestHelpers.validateData(ConfigTestHelpers.configJSON(
            models: [ConfigTestHelpers.modelJSON(alias: alias, base: base)],
            defaultModel: alias))
        return try #require(snapshot.profiles[alias])
    }

    /// Rebuilds a profile with one field changed. Profiles are immutable
    /// (`let` throughout, H1), so every variant constructs a fresh value
    /// through the single validating initializer.
    private static func copy(
        _ base: ModelProfile,
        alias: String? = nil, wire: WireProtocol? = nil, baseURL: String? = nil,
        modelID: String? = nil, locality: Locality? = nil,
        contextWindow: Int? = nil, maxOutput: Int? = nil, raw: Data? = nil
    ) throws -> ModelProfile {
        try ModelProfile(
            alias: alias ?? base.alias, wireProtocol: wire ?? base.wireProtocol,
            baseURL: baseURL ?? base.baseURL, modelID: modelID ?? base.modelID,
            contextWindow: contextWindow ?? base.contextWindow,
            maxOutput: maxOutput ?? base.maxOutput,
            locality: locality ?? base.locality, credential: base.credential,
            connectTimeout: base.connectTimeout, readIdleTimeout: base.readIdleTimeout,
            requestTimeout: base.requestTimeout, maxInFlight: base.maxInFlight,
            requestOptions: base.requestOptions,
            requestOptionsRaw: raw ?? base.requestOptionsRaw,
            unqualifiedOptions: base.unqualifiedOptions)
    }

    @Test("CFG-02 snapshots are values: copies never alias the original")
    func CFG_02_snapshotsAreIndependentValues() throws {
        let a = try Self.profile()
        let b = try Self.copy(a, maxOutput: 1)
        #expect(a != b && a.maxOutput == 4096, "rebuild affects only the new value")
    }

    @Test("CFG-02 requiresNewEpoch fires on every incompatible change")
    func CFG_02_requiresNewEpochMatrix() throws {
        let base = try Self.profile()
        // Identity / route / generation-affecting changes all force an epoch.
        #expect(requiresNewEpoch(old: base, new: try Self.copy(base, modelID: "other")))
        #expect(requiresNewEpoch(old: base, new: try Self.copy(base, baseURL: "http://127.0.0.1:11435")))
        #expect(requiresNewEpoch(old: base, new: try Self.copy(base, wire: .openAIResponses)))
        #expect(requiresNewEpoch(old: base, new: try Self.copy(base, locality: .cloud)))
        #expect(requiresNewEpoch(old: base, new: try Self.copy(base, contextWindow: 1024)))
        #expect(requiresNewEpoch(old: base, new: try Self.copy(base, maxOutput: 1)))
        #expect(requiresNewEpoch(old: base, new: try Self.copy(base, raw: Data(" ".utf8))))
        // Identical snapshots never force an epoch.
        #expect(!requiresNewEpoch(old: base, new: base))
        let twin = try Self.profile()
        #expect(!requiresNewEpoch(old: base, new: twin))
    }

    @Test("CFG-02 snapshot-level epoch fires on tool-set and alias changes")
    func CFG_02_snapshotEpochIncludesTools() throws {
        // S2: the tool-set lives on the snapshot, so the predicate has a
        // snapshot-level overload — profile-only comparison cannot see it.
        let a = try ConfigTestHelpers.validateData(ConfigTestHelpers.configJSON())
        #expect(!requiresNewEpoch(old: a, new: a))
        let deniedTools = ConfigSnapshot(
            version: a.version, profiles: a.profiles, defaultAlias: a.defaultAlias,
            allowHTTPOrigins: a.allowHTTPOrigins, tools: ToolCapabilities.allDenied)
        #expect(requiresNewEpoch(old: a, new: deniedTools), "tool-set change must force an epoch")
        let ghostDefault = ConfigSnapshot(
            version: a.version, profiles: a.profiles, defaultAlias: "ghost",
            allowHTTPOrigins: a.allowHTTPOrigins, tools: a.tools)
        #expect(requiresNewEpoch(old: a, new: ghostDefault), "default-alias change must force an epoch")
    }
}
