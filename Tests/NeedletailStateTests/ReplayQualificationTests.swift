import Testing
import Foundation
import NeedletailCore
import NeedletailTestSupport

struct ReplayQualificationTests {
    @Test("M2-0 replay: identical cancellation trace yields identical state and no late resurrection")
    func cancelledLateCompletionReplays() throws {
        func run() throws -> SessionState {
            var ids = StateFixtures.ids()
            let (admitting, run) = try StateFixtures.admitted("mutate", ids: &ids)
            var state = transition(admitting, .requestDispatched(requestID: run.requestID, atMillis: 1001), &ids).state
            state = transition(state, .cancelRequested(atMillis: 1002), &ids).state
            // Late completion from the cancelled generation must not resurrect.
            state = transition(state, .effectCompleted(
                effectID: EffectID("eff-late"), runID: run.runID, generation: run.revision,
                expectedRevision: run.revision, mutating: true, outcome: .success("late"),
                atMillis: 1003), &ids).state
            return state
        }
        let a = try run()
        let b = try run()
        #expect(a == b, "replay must be deterministic")
        #expect(a.phase.isTerminal || a.phase == .cancelling, "cancelled run does not become completed")
    }
}
