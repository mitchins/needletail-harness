import Testing
import NeedletailTestSupport

/// BDD-02 — Ten seeds and duplicate test functions exercise the same
/// behaviour.
/// Given many variant records of one behaviour, when coverage is reconciled,
/// then exactly one distinct semantic case is counted and the variants are
/// reported separately. Forbidden: counting variants as semantic cases.
struct VariantCountingTests {

    @Test("BDD-02 ten variants of one behaviour count as one semantic case")
    func BDD_02_tenVariantsCountAsOneCase() throws {
        let entry = CatalogueEntry(id: "WIRE-01", family: "WIRE", scenario: "byte splits", dueMilestone: "M1", evidenceLayers: [.integration])
        let catalogue = Catalogue(entries: [entry])

        let results = (1...10).map { seed in
            CaseResult(caseID: "WIRE-01", variantID: "byte-split-\(seed)", testStatus: .pass)
        }
        let reconciliation = ResultsReconciler.reconcile(catalogue: catalogue, results: results)
        guard case .consistent(let report) = reconciliation else {
            Issue.record("expected a consistent report, got \(reconciliation)")
            return
        }
        #expect(report.distinctCases == 1, "ten variants are one semantic case")
        #expect(report.variantCount == 10, "variants are reported separately")
        #expect(report.satisfied == ["WIRE-01"])
        #expect(report.missing.isEmpty)
    }

    @Test("BDD-02 one failing variant makes the semantic case unsatisfied")
    func BDD_02_oneFailingVariantFailsTheCase() throws {
        let entry = CatalogueEntry(id: "WIRE-01", family: "WIRE", scenario: "byte splits", dueMilestone: "M1", evidenceLayers: [.integration])
        let catalogue = Catalogue(entries: [entry])

        let results = (1...9).map { seed in
            CaseResult(caseID: "WIRE-01", variantID: "byte-split-\(seed)", testStatus: .pass)
        } + [CaseResult(caseID: "WIRE-01", variantID: "byte-split-10", testStatus: .fail)]
        let reconciliation = ResultsReconciler.reconcile(catalogue: catalogue, results: results)
        guard case .consistent(let report) = reconciliation else {
            Issue.record("expected a consistent report, got \(reconciliation)")
            return
        }
        #expect(report.distinctCases == 1)
        #expect(report.variantCount == 10)
        #expect(report.unsatisfied == ["WIRE-01"], "a failing variant cannot be averaged away")
        #expect(report.satisfied.isEmpty)
    }

    @Test("BDD-02 duplicate (case, variant) keys are rejected")
    func BDD_02_duplicateVariantKeysAreRejected() throws {
        let entry = CatalogueEntry(id: "WIRE-01", family: "WIRE", scenario: "byte splits", dueMilestone: "M1", evidenceLayers: [.integration])
        let catalogue = Catalogue(entries: [entry])
        let results = [
            CaseResult(caseID: "WIRE-01", variantID: "byte-split-1", testStatus: .pass),
            CaseResult(caseID: "WIRE-01", variantID: "byte-split-1", testStatus: .pass),
        ]
        let reconciliation = ResultsReconciler.reconcile(catalogue: catalogue, results: results)
        guard case .invalid(let reason) = reconciliation else {
            Issue.record("expected invalid reconciliation for duplicate keys")
            return
        }
        #expect(reason.contains("WIRE-01/byte-split-1"), "reason must name the duplicate key: \(reason)")
    }
}
