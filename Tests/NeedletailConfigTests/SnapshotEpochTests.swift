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

    @Test("CFG-02 snapshots are values: copies never alias the original")
    func CFG_02_snapshotsAreIndependentValues() throws {
        let a = try Self.profile()
        var b = a
        #expect(a == b)
        b.maxOutput = 1
        #expect(a != b && a.maxOutput == 4096, "mutation affects only the copy")
    }

    @Test("CFG-02 requiresNewEpoch fires on every incompatible change")
    func CFG_02_requiresNewEpochMatrix() throws {
        let base = try Self.profile()
        // Identity / route / generation-affecting changes all force an epoch.
        var changed = base; changed.modelID = "other"; #expect(requiresNewEpoch(old: base, new: changed))
        changed = base; changed.baseURL = "http://127.0.0.1:11435"; #expect(requiresNewEpoch(old: base, new: changed))
        changed = base; changed.wireProtocol = .openAIResponses; #expect(requiresNewEpoch(old: base, new: changed))
        changed = base; changed.locality = .cloud; #expect(requiresNewEpoch(old: base, new: changed))
        changed = base; changed.contextWindow = 1024; #expect(requiresNewEpoch(old: base, new: changed))
        changed = base; changed.maxOutput = 1; #expect(requiresNewEpoch(old: base, new: changed))
        changed = base; changed.requestOptionsRaw = Data(" ".utf8); #expect(requiresNewEpoch(old: base, new: changed))
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
        var b = a
        #expect(!requiresNewEpoch(old: a, new: b))
        b.tools = ToolCapabilities.allDenied
        #expect(requiresNewEpoch(old: a, new: b), "tool-set change must force an epoch")
        b = a
        b.defaultAlias = "ghost"
        #expect(requiresNewEpoch(old: a, new: b), "default-alias change must force an epoch")
    }
}
