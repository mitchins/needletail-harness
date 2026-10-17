import Testing
import Foundation
import NeedletailCore

/// Epoch rules: switchModel opens a new epoch iff `requiresNewEpoch`,
/// re-validates the route, holds stale-target entries and prunes the ack
/// index; busy-phase switches refuse (M1B4-1: terminal phases refuse with
/// dismiss-first); checkpoints only open at clean idle boundaries.
struct EpochSwitchTests {

    @Test("switchModel to an unknown alias refuses with the vocabulary")
    func switchModelUnknownRefuses() throws {
        var ids = StateFixtures.ids()
        let idle = try StateFixtures.idle()
        let result = transition(idle, .switchModel(alias: "ghost", atMillis: 1000), &ids)
        #expect(result.state.epoch.epochID == EpochID("epoch-1"), "no epoch change on refusal")
    }

    @Test("switchModel to a new profile opens a child epoch and holds stale entries")
    func switchModelOpensEpoch() throws {
        let twoModel = """
            {"version":1,"default_model":"local-coder","allow_http_origins":["http://127.0.0.1:11434","http://127.0.0.1:11435"],"models":[{"alias":"local-coder","protocol":"openai-chat-completions","base_url":"http://127.0.0.1:11434","model":"qwen","context_window":262144,"max_output":4096,"locality":"local","connect_timeout_s":10,"read_idle_timeout_s":300,"request_timeout_s":1800,"max_in_flight":1},{"alias":"second","protocol":"openai-chat-completions","base_url":"http://127.0.0.1:11435","model":"qwen","context_window":262144,"max_output":4096,"locality":"local","connect_timeout_s":10,"read_idle_timeout_s":300,"request_timeout_s":1800,"max_in_flight":1}],"tools":{"read":true}}
            """
        let snapshot = try validateConfig(Data(twoModel.utf8))
        let profile = try #require(snapshot.profiles["local-coder"])
        let caps = effectiveCapabilities(
            build: .allAllowed, userConfig: snapshot.tools,
            workspaceGrant: .allDenied, invocationMask: .allAllowed,
            sealed: SealedRestrictions(sealed: false))
        let epoch = EpochDescriptor(
            epochID: EpochID("epoch-1"), configSnapshot: snapshot, profile: profile,
            effectiveCaps: caps, route: .allowed(endpoint: "http://127.0.0.1:11434/chat/completions", alias: "local-coder"))
        var ids = StateFixtures.ids()
        var state = SessionState(sessionID: SessionID("s-9"), epoch: epoch, trustMode: .workspace, phase: .idle)
        // Build a queued entry bound to the old epoch: admit a run, queue
        // behind it, cancel (holds queue), force interruption, dismiss.
        state = transition(state, StateFixtures.input("run", id: "run-9"), &ids).state
        state = transition(state, StateFixtures.input("old work", id: "old-1"), &ids).state
        #expect(state.queue.count == 1, "entry queues behind the live run")
        state = transition(state, .cancelRequested(atMillis: 1001), &ids).state
        state = transition(state, .tick(nowMillis: 1001 + cancelGraceMillis), &ids).state
        guard case .interrupted = state.phase else {
            Issue.record("expected interrupted"); return
        }
        state = transition(state, .dismissRun(atMillis: 7000), &ids).state
        let switched = transition(state, .switchModel(alias: "second", atMillis: 1001), &ids)
        #expect(switched.state.epoch.parentEpochID == EpochID("epoch-1"), "lineage links parent")
        #expect(switched.state.epoch.profile.alias == "second")
        #expect(switched.state.admittedCommands.isEmpty, "ack index prunes at epoch change")
        #expect(switched.state.queue.first?.state == .held, "stale-epoch entries hold, never auto-dispatch")
    }

    @Test("switchModel to the current alias is a no-op diagnostic")
    func switchModelSameNoop() throws {
        var ids = StateFixtures.ids()
        let idle = try StateFixtures.idle()
        let result = transition(idle, .switchModel(alias: "local-coder", atMillis: 1000), &ids)
        #expect(result.state.epoch.epochID == EpochID("epoch-1"))
    }

    @Test("M1B4-1 terminal switchModel and checkpoint refuse with dismiss-first")
    func terminalMetaRefuses() throws {
        var ids = StateFixtures.ids()
        let idle = try StateFixtures.idle()
        let failed = transition(idle, .invalidInput(fingerprint: "f", cause: "c", atMillis: 1), &ids).state
        let failed2 = transition(failed, .invalidInput(fingerprint: "f", cause: "c", atMillis: 2), &ids).state
        let failed3 = transition(failed2, .invalidInput(fingerprint: "f", cause: "c", atMillis: 3), &ids).state
        guard case .failed = failed3.phase else {
            Issue.record("expected failed phase"); return
        }
        let switched = transition(failed3, .switchModel(alias: "local-coder", atMillis: 4), &ids)
        #expect(switched.state.epoch.epochID == EpochID("epoch-1"), "terminal switch must not open epochs")
        let checked = transition(failed3, .checkpointRequested(atMillis: 4), &ids)
        #expect(checked.state.phase == failed3.phase, "terminal checkpoint must not start")
    }

    @Test("busy switchModel and checkpoint refuse without queueing")
    func busyMetaRefuses() throws {
        var ids = StateFixtures.ids()
        let (admitting, _) = try StateFixtures.admitted("run", ids: &ids)
        let switched = transition(admitting, .switchModel(alias: "local-coder", atMillis: 1001), &ids)
        #expect(switched.state.phase == .admitting, "admission continues; switch refused")
        #expect(switched.state.queue.isEmpty, "refused meta-commands never queue")
        let checked = transition(admitting, .checkpointRequested(atMillis: 1001), &ids)
        #expect(checked.state.phase == .admitting)
    }

    @Test("checkpoint opens only at clean idle and commits or fails back")
    func checkpointBoundary() throws {
        var ids = StateFixtures.ids()
        let idle = try StateFixtures.idle()
        let started = transition(idle, .checkpointRequested(atMillis: 1000), &ids)
        guard case .checkpointing = started.state.phase else {
            Issue.record("clean idle must open checkpointing"); return
        }
        let failed = transition(started.state, .checkpointFailed(reason: "disk hiccup", atMillis: 1001), &ids)
        #expect(failed.state.phase == .idle, "failed checkpoint returns with epoch unchanged")
        #expect(failed.state.epoch.epochID == EpochID("epoch-1"))
        // Unresolved markers refuse the boundary.
        let marker = OperationRef(operationID: OperationID("op-u"), state: .unknown, mutating: true)
        let dirty = idle.replacing(unresolvedOperations: [marker])
        let refused = transition(dirty, .checkpointRequested(atMillis: 1002), &ids)
        #expect(refused.state.phase == .idle, "dirty ledger refuses checkpointing")
    }
}
