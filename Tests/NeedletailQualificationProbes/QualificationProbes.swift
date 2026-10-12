import Testing
import Foundation
import NeedletailCore

/// M0-A test-runner qualification fixtures. These deliberately include a
/// failing case, skipped cases, a parameterized case and a passing case so
/// that `./dev test qualification` can prove the runner and the reporter
/// distinguish them. This target is NEVER part of `./dev test quick`,
/// `./dev test offline`, or a bare `swift test` green run: the intentional
/// failure is gated by `.enabled(if:)` on an opt-in environment variable
/// (M0-A "keep demonstration failures outside the ordinary green suite";
/// TESTING §4 "bare `swift test` remains usable"), so an accidental
/// invocation cannot make an ordinary gate red by accident — and a
/// demonstration failure can never be silently converted into a pass by
/// regeneration (TESTING §2, BDD-04, DX-07).

private var qualificationEnabled: Bool {
    ProcessInfo.processInfo.environment["NEEDLETAIL_QUALIFICATION"] == "1"
}

struct QualificationIntentionalFailureTests {

    /// RED demonstration: when run via `./dev test qualification`, this test
    /// MUST fail for the intended reason. If it ever passes, the
    /// qualification evidence for "failures are detected" is void and M0-A
    /// cannot close. Gated so a default `swift test` stays green.
    @Test("qualification intentional failure must be reported as a failure",
          .enabled(if: qualificationEnabled, "set NEEDLETAIL_QUALIFICATION=1 (./dev test qualification)"))
    func intentionalFailure() {
        #expect(1 + 1 == 3, "deliberate arithmetic failure: the runner must report this")
    }
}

struct QualificationSkipTests {

    /// Skip demonstration: disabled tests are not executed. Reconciliation
    /// must treat an unexecuted case as missing, never as PASS (BDD-04).
    @Test("qualification skipped case is never counted as passing", .disabled("demonstration only"))
    func skippedCase() {
        #expect(Bool(true))
    }

    /// A skipped variant of a due case leaves its gate unsatisfied.
    @Test("qualification skipped variant of a due case", .disabled("demonstration only"))
    func skippedVariant() {
        #expect(Bool(true))
    }
}

struct QualificationParameterizedTests {

    @Test("qualification parameterized cases", arguments: [
        ("byte-split-1", 2),
        ("byte-split-2", 4),
        ("byte-split-3", 8),
    ])
    func parameterizedCases(variant: String, chunkSize: Int) {
        #expect(chunkSize > 0, "\(variant): chunk size must be positive")
        #expect(chunkSize % 2 == 0, "\(variant): fixture chunk sizes are even")
    }
}

struct QualificationPassingTests {

    @Test("qualification passing case is reported as passing")
    func passingCase() {
        #expect(NeedletailVersion(parsing: "0.3.0") == NeedletailVersion(major: 0, minor: 3, patch: 0))
    }
}
