import Testing
import NeedletailTestSupport

/// BDD-03 / BDD-04 / TESTING §11 — a registered case with no executed test
/// body, a skipped or filtered variant, an example-kind record, or a
/// valid-looking self-certifying JSON never counts as a pass.
/// Given synthetic per-case reports, when classified, then only records
/// whose test/review/environment fields are all PASS satisfy the case.
/// Forbidden: skipped→PASS, missing→PASS, example→PASS, single-field PASS.
struct ResultsClassificationTests {

    private static func singleCaseCatalogue() -> Catalogue {
        Catalogue(entries: [
            CatalogueEntry(id: "BDD-03", family: "BDD", scenario: "no executed body", dueMilestone: "M0", evidenceLayers: [.reviewProcess]),
            CatalogueEntry(id: "BDD-04", family: "BDD", scenario: "required variant skipped", dueMilestone: "M0", evidenceLayers: [.reviewProcess]),
        ])
    }

    @Test("BDD-03 a case absent from the report is missing, never pass")
    func BDD_03_absentCaseIsMissingNeverPass() {
        let report: ReconciliationReport
        switch ResultsReconciler.reconcile(catalogue: Self.singleCaseCatalogue(), results: []) {
        case .consistent(let consistent): report = consistent
        case .invalid(let reason): Issue.record("unexpected invalid: \(reason)"); return
        }
        #expect(report.missing.sorted() == ["BDD-03", "BDD-04"], "both cases due now are missing, not passed")
        #expect(report.satisfied.isEmpty)
    }

    @Test("BDD-04 a variant marked deferred or not implemented never satisfies the gate")
    func BDD_04_nonPassStatusesNeverSatisfy() {
        for status in [CaseStatus.deferredByPlan, .notImplemented, .blockedReview, .unqualifiedEnvironment, .fail] {
            #expect(!status.isSatisfied, "\(status.rawValue) must not satisfy a gate")
        }
        #expect(CaseStatus.pass.isSatisfied)
    }

    @Test("BDD-04 review and environment fields are independent gates")
    func BDD_04_reviewAndEnvironmentFieldsAreIndependentGates() {
        let cases = Self.singleCaseCatalogue()
        let results = [
            CaseResult(caseID: "BDD-03", testStatus: .pass, reviewStatus: .pass),
            CaseResult(caseID: "BDD-04", testStatus: .pass, reviewStatus: .blockedReview),
        ]
        guard case .consistent(let report) = ResultsReconciler.reconcile(catalogue: cases, results: results) else {
            Issue.record("expected consistent report"); return
        }
        #expect(report.satisfied == ["BDD-03"])
        #expect(report.unsatisfied == ["BDD-04"], "a blocked review cannot be overridden by a passing test")
    }

    @Test("BDD-03 a case requiring review evidence is unsatisfied without a review record")
    func BDD_03_missingReviewEvidenceIsUnsatisfied() {
        // The single-case catalogue requires the reviewProcess layer for
        // BDD-03. A passing test with NO review record must not satisfy it:
        // absent required evidence is never a pass.
        let cases = Self.singleCaseCatalogue()
        let results = [CaseResult(caseID: "BDD-03", testStatus: .pass)]
        guard case .consistent(let report) = ResultsReconciler.reconcile(catalogue: cases, results: results) else {
            Issue.record("expected consistent report"); return
        }
        #expect(report.satisfied.isEmpty, "absent review evidence must not satisfy BDD-03")
        #expect(report.unsatisfied == ["BDD-03"])
    }

    @Test("BDD-03 placeholder-kind records cannot certify their own run (TESTING §11)")
    func BDD_03_placeholderRecordsAreRejected() {
        let cases = Self.singleCaseCatalogue()
        let results = [
            CaseResult(caseID: "BDD-03", testStatus: .pass, kind: "placeholder"),
            CaseResult(caseID: "BDD-04", testStatus: .pass),
        ]
        guard case .invalid(let reason) = ResultsReconciler.reconcile(catalogue: cases, results: results) else {
            Issue.record("expected invalid reconciliation for placeholder-kind records"); return
        }
        #expect(reason.contains("placeholder"), "reason must mention placeholder records: \(reason)")
    }

    @Test("BDD-04 an unqualified environment is reported, not hidden as a pass")
    func BDD_04_unqualifiedEnvironmentIsReported() {
        let cases = Self.singleCaseCatalogue()
        let results = [CaseResult(caseID: "BDD-03", testStatus: .pass, environmentStatus: .unqualifiedEnvironment)]
        guard case .consistent(let report) = ResultsReconciler.reconcile(catalogue: cases, results: results) else {
            Issue.record("expected consistent report"); return
        }
        #expect(report.unsatisfied == ["BDD-03"])
        #expect(report.missing == ["BDD-04"])
    }

    @Test("BDD-03 example-kind records cannot certify their own run (TESTING §11)")
    func BDD_03_exampleRecordsAreRejected() {
        let cases = Self.singleCaseCatalogue()
        let results = [
            CaseResult(caseID: "BDD-03", testStatus: .pass, kind: "example"),
            CaseResult(caseID: "BDD-04", testStatus: .pass),
        ]
        guard case .invalid(let reason) = ResultsReconciler.reconcile(catalogue: cases, results: results) else {
            Issue.record("expected invalid reconciliation for example-kind records"); return
        }
        #expect(reason.contains("example"), "reason must mention example records: \(reason)")
    }
}
