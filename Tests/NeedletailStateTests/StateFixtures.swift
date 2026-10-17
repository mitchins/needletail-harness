import Testing
import Foundation
import NeedletailCore
import NeedletailTestSupport

/// Deterministic fixtures for M1-B pure suites: frozen clock/IDs, a valid
/// local snapshot (via the M1-A pipeline — no fixture files), and session
/// builders. No filesystem, environment, network or wall clock.
enum StateFixtures {
    static let configJSON = """
        {"version":1,"default_model":"local-coder","allow_http_origins":["http://127.0.0.1:11434"],"models":[{"alias":"local-coder","protocol":"openai-chat-completions","base_url":"http://127.0.0.1:11434","model":"qwen","context_window":262144,"max_output":4096,"locality":"local","credential":{"env":"NT_M1B_KEY"},"connect_timeout_s":10,"read_idle_timeout_s":300,"request_timeout_s":1800,"max_in_flight":1}],"tools":{"read":true,"search":true,"edit":true,"write":true,"exec":"ask","consult":false}}
        """

    static func snapshot() throws -> ConfigSnapshot {
        try validateConfig(Data(configJSON.utf8))
    }

    /// - Parameter permissive: when true, the workspace grant allows the
    ///   configured tools (simulating post-`trust` sessions for approval/
    ///   execution-path tests). Default mirrors production (deny-all until
    ///   M2 trust — most tests prove denial, not grants).
    static func epoch(profileAlias: String = "local-coder", permissive: Bool = false) throws -> EpochDescriptor {
        let snapshot = try snapshot()
        let profile = try #require(snapshot.profiles[profileAlias])
        let caps = effectiveCapabilities(
            build: .allAllowed, userConfig: snapshot.tools,
            workspaceGrant: permissive ? .allAllowed : .allDenied,
            invocationMask: .allAllowed,
            sealed: SealedRestrictions(sealed: false))
        let route = selectRoute(snapshot: snapshot, requestedAlias: profileAlias, sealed: false)
        return EpochDescriptor(
            epochID: EpochID("epoch-1"), parentEpochID: nil,
            configSnapshot: snapshot, profile: profile,
            effectiveCaps: caps, route: route)
    }

    static func idle(trustMode: TrustMode = .workspace, permissive: Bool = false) throws -> SessionState {
        let epoch = try epoch(permissive: permissive)
        _ = try validateTrustConsistency(mode: trustMode, caps: epoch.effectiveCaps.tools)
        return SessionState(sessionID: SessionID("s-1"), epoch: epoch, trustMode: trustMode, phase: .idle)
    }

    static func ids(prefix: String = "t") -> DeterministicIDSource {
        DeterministicIDSource(prefix: prefix)
    }

    static func input(
        _ text: String, id: String = "cmd-1", kind: QueueKind = .followUp,
        sealed: Bool = false, at: UInt64 = 1000
    ) -> SessionEvent {
        .operatorInput(commandID: CommandID(id), text: text, kind: kind, revision: 1, sealed: sealed, atMillis: at)
    }

    /// Drives a fresh admission and returns the admitting state (turnsUsed
    /// still 0 — dispatch confirmation is a separate event).
    static func admitted(
        _ text: String = "do the thing", id: String = "cmd-1", ids: inout DeterministicIDSource
    ) throws -> (SessionState, RunDescriptor) {
        let idle = try idle()
        let result = transition(idle, input(text, id: id), &ids)
        guard case .admitting = result.state.phase else {
            Issue.record("admission must land in admitting")
            throw FixtureFailure.admission
        }
        let run = try #require(result.state.activeRun, "admission must reserve a run")
        return (result.state, run)
    }
}

enum FixtureFailure: Error {
    case admission
}
