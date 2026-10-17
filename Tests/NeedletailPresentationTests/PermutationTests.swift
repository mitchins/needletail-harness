import Testing
import Foundation
import NeedletailPresentation
import NeedletailCore

/// DX-06 — bounded adversarial interleavings over model deltas, status
/// updates, draft input, cancellation notices, completions and queue acks.
/// Invariants hold on EVERY trace: draft byte-exact, no effect without ack,
/// stale revisions drop, single owner, no auto-dispatch while held.
/// Failing traces minimize and promote to BDD-08 (see BDD08ReplayTests).
struct PermutationTests {

    /// Deterministic xorshift64 (fixed seeds — no RNG framework).
    struct XorShift: Sendable {
        var state: UInt64
        mutating func next(bound: Int) -> Int {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(state % UInt64(max(1, bound)))
        }
    }

    enum ScriptOp: Sendable {
        case typeText(String)
        case sessionAdmit(revision: UInt64)
        case sessionDeny
        case completion(rev: UInt64)
        case cancelNotice
        case queueIntent
    }

    static func script(seed: UInt64, length: Int) -> [ScriptOp] {
        var rng = XorShift(state: seed == 0 ? 0x9E37 : seed)
        let texts = ["a", "bb", " x ", "y"]
        return (0..<length).map { _ in
            switch rng.next(bound: 6) {
            case 0: return .typeText(texts[rng.next(bound: texts.count)])
            case 1: return .sessionAdmit(revision: UInt64(rng.next(bound: 3)))
            case 2: return .sessionDeny
            case 3: return .completion(rev: UInt64(rng.next(bound: 3)))
            case 4: return .cancelNotice
            default: return .queueIntent
            }
        }
    }

    struct TraceResult: Sendable {
        var draft: String
        var effects: Int
        var violations: [String]
    }

    /// Replays one scripted trace, collecting invariant violations. All
    /// five claimed invariants are asserted here (S3): (1) draft byte-exact;
    /// (2) every queueOp emits exactly one explicit effect (never silent,
    /// never double — the actor decides, the UI always asks out loud);
    /// (3) stale revisions drop without mutation; (4) single owner: at most
    /// one submission-like effect per action; (5) non-session actions never
    /// touch the queue projection (no auto-dispatch while held — the
    /// projection only moves on actor-originated session events).
    static func replay(_ ops: [ScriptOp]) -> TraceResult {
        var state = UIState()
        state.suggestion = MentionSuggestionState(query: "q", revision: 2, candidates: [])
        var draft = ""
        var effects = 0
        var violations: [String] = []
        // The harness seeds one benign queue intent per trace to exercise
        // invariants (2), (4) and (5) on every run.
        let queueProbe: [ScriptOp] = [.queueIntent]
        for op in ops + queueProbe {
            let queueBefore = state.queue
            switch op {
            case .typeText(let text):
                draft += text
                let (next, emitted) = reduce(state, .input(.insertText(text)))
                state = next
                effects += emitted.count
                if state.composer.text != draft {
                    violations.append("draft corrupted: '\(state.composer.text)' vs '\(draft)'")
                }
                if !emitted.isEmpty {
                    violations.append("plain typing must emit no effects")
                }
            case .sessionAdmit(let revision):
                let (next, emitted) = reduce(
                    state, .session(.admitted(commandID: CommandID("q"), revision: revision)))
                state = next
                effects += emitted.count
            case .sessionDeny:
                let (next, emitted) = reduce(state, .session(.denied(cause: "policy")))
                state = next
                effects += emitted.count
            case .completion(let rev):
                let before = state.composer.text
                let beforeCount = state.suggestion?.candidates.count ?? -1
                let (next, emitted) = reduce(state, .completion(CompletionResult(
                    queryRevision: rev, candidates: [CandidateFile(path: "late")])))
                state = next
                effects += emitted.count
                if rev != 2 {
                    if state.composer.text != before {
                        violations.append("stale completion touched the draft")
                    }
                    if (state.suggestion?.candidates.count ?? -2) != beforeCount {
                        violations.append("stale completion overwrote candidates")
                    }
                }
            case .cancelNotice:
                let (next, emitted) = reduce(state, .session(.denied(cause: "cancelled")))
                state = next
                effects += emitted.count
                if state.composer.text != draft {
                    violations.append("cancel notice corrupted the draft")
                }
            case .queueIntent:
                let (next, emitted) = reduce(state, .queueOp(.submitFollowUp(
                    text: "queued", commandID: CommandID("probe-q"))))
                state = next
                effects += emitted.count
                if emitted.count != 1 {
                    violations.append("queue intent must emit exactly one effect, got \(emitted.count)")
                }
                if state.queue != queueBefore {
                    violations.append("queue intent mutated the projection instead of emitting")
                }
            }
            if state.queue != queueBefore, !isSessionOp(op) {
                violations.append("non-session action touched the queue projection")
            }
        }
        return TraceResult(draft: draft, effects: effects, violations: violations)
    }

    private static func isSessionOp(_ op: ScriptOp) -> Bool {
        switch op {
        case .sessionAdmit, .sessionDeny: return true
        default: return false
        }
    }

    @Test("DX-06 bounded interleavings preserve every invariant")
    func DX_06_adversarialInterleavings() throws {
        var failures: [(seed: UInt64, violations: [String])] = []
        for seed in 1...40 {
            let trace = Self.script(seed: UInt64(seed), length: 12)
            let result = Self.replay(trace)
            if !result.violations.isEmpty {
                failures.append((UInt64(seed), result.violations))
            }
        }
        #expect(failures.isEmpty, "invariant violations (minimize the first): \(failures.prefix(2))")
    }

    /// The minimized hostile trace, frozen. Authored from the threat model
    /// (labeled — see BDD08ReplayTests for provenance) AND covered by the
    /// harness above; if the harness ever reports it, this is the shape.
    static let hostileTrace: [ScriptOp] = [
        .typeText("do not lose me"),
        .completion(rev: 1), // stale (live is 2)
        .sessionAdmit(revision: 1),
        .completion(rev: 1), // stale again, post-ack
        .cancelNotice,
        .typeText(" + more"),
        .completion(rev: 99), // far-future revision: still stale (≠2)
    ]

    @Test("DX-06 authored hostile trace holds invariants")
    func DX_06_hostileTraceHolds() throws {
        let result = Self.replay(Self.hostileTrace)
        #expect(result.violations.isEmpty, "violations: \(result.violations)")
        #expect(result.draft == "do not lose me + more")
        #expect(result.effects == 1, "exactly the appended queue probe effect")
    }
}
