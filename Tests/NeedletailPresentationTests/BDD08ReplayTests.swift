import Testing
import Foundation
import NeedletailPresentation
import NeedletailCore

/// BDD-08 — frozen replay of a minimized hostile interleaving.
/// PROVENANCE: hand-authored from the threat model for rev1 (the DX-06
/// harness with seeds 1...40 reports no failure — see DX_06 test). Labeled
/// as authored, never counted as "failure reproduced": it pins the
/// cancel-racing-completion + stale-candidate ordering that the harness
/// exists to explore, so any future reducer change that breaks it fails
/// loudly with this exact frozen trace.
struct BDD08ReplayTests {

    /// Frozen trace (clock/IDs/seed fixed): type, stale-complete, admit,
    /// stale-complete again, cancel notice, more typing, far-future stale.
    @Test("BDD-08 frozen hostile interleaving replays green")
    func BDD_08_frozenInterleavingReplays() throws {
        let trace: [PermutationTests.ScriptOp] = [
            .typeText("do not lose me"),
            .completion(rev: 1),
            .sessionAdmit(revision: 1),
            .completion(rev: 1),
            .cancelNotice,
            .typeText(" + more"),
            .completion(rev: 99),
        ]
        let result = PermutationTests.replay(trace)
        #expect(result.violations.isEmpty, "frozen trace must hold: \(result.violations)")
        #expect(result.draft == "do not lose me + more", "draft exact after replay")
        #expect(result.effects == 0, "this trace emits no effects (completions all stale, no queue ops)")
    }
}
