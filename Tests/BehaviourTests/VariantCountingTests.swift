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
    func BDD_02_duplicateVariantKeysAreRejected() throws {        let entry = CatalogueEntry(id: "WIRE-01", family: "WIRE", scenario: "byte splits", dueMilestone: "M1", evidenceLayers: [.integration])
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

    @Test("BDD-02 one reported variant of ten required leaves the case unsatisfied")
    func BDD_02_partialVariantReportIsUnsatisfied() throws {
        // Ten variants are required; only one passing variant is reported.
        // The other nine may have been filtered out or skipped without
        // records — that must not satisfy the case. The requirement is
        // registered independently of the reported results.
        let entry = CatalogueEntry(id: "WIRE-01", family: "WIRE", scenario: "byte splits", dueMilestone: "M1", evidenceLayers: [.integration])
        let catalogue = Catalogue(entries: [entry])
        let required = Set((1...10).map { "byte-split-\($0)" })
        let results = [CaseResult(caseID: "WIRE-01", variantID: "byte-split-1", testStatus: .pass)]
        let reconciliation = ResultsReconciler.reconcile(catalogue: catalogue, results: results, requiredVariants: ["WIRE-01": required])
        guard case .consistent(let report) = reconciliation else {
            Issue.record("expected a consistent report, got \(reconciliation)")
            return
        }
        #expect(report.unsatisfied == ["WIRE-01"], "nine absent required variants must not be assumed pass")
        #expect(report.satisfied.isEmpty)
    }

    @Test("BDD-02 all required variants passing satisfies the case")
    func BDD_02_allRequiredVariantsSatisfy() throws {
        let entry = CatalogueEntry(id: "WIRE-01", family: "WIRE", scenario: "byte splits", dueMilestone: "M1", evidenceLayers: [.integration])
        let catalogue = Catalogue(entries: [entry])
        let required = Set((1...10).map { "byte-split-\($0)" })
        let results = (1...10).map { seed in
            CaseResult(caseID: "WIRE-01", variantID: "byte-split-\(seed)", testStatus: .pass)
        }
        let reconciliation = ResultsReconciler.reconcile(catalogue: catalogue, results: results, requiredVariants: ["WIRE-01": required])
        guard case .consistent(let report) = reconciliation else {
            Issue.record("expected a consistent report, got \(reconciliation)")
            return
        }
        #expect(report.satisfied == ["WIRE-01"])
    }

    @Test("BDD-02 a passing mock-tier pin does not veto native certification")
    func BDD_02_mockTierPassDoesNotVetoNative() throws {
        // Same shared contract at two tiers: the mock pin passes its test
        // gates at .pure, the certifying variant passes at .nativeStorage.
        // The case is satisfied; the mock is supporting evidence, not a veto.
        let entry = CatalogueEntry(id: "STORE-07", family: "STORE", scenario: "resume", dueMilestone: "M2", evidenceLayers: [.nativeStorage, .integration])
        let catalogue = Catalogue(entries: [entry])
        let results = [
            CaseResult(caseID: "STORE-07", variantID: "in-memory", testStatus: .pass, evidenceTier: .pure),
            CaseResult(caseID: "STORE-07", variantID: "sqlite", testStatus: .pass, evidenceTier: .nativeStorage),
        ]
        let reconciliation = ResultsReconciler.reconcile(
            catalogue: catalogue, results: results, requiredVariants: ["STORE-07": ["sqlite"]])
        guard case .consistent(let report) = reconciliation else {
            Issue.record("expected a consistent report, got \(reconciliation)")
            return
        }
        #expect(report.satisfied == ["STORE-07"], "native evidence certifies despite the mock-tier pin")
    }

    @Test("BDD-02 a failing mock-tier pin still vetoes the case")
    func BDD_02_mockTierFailVetoesCase() throws {
        // The mock pin regressed (test FAIL): behavior drift is real even
        // though native evidence exists — the case must not certify.
        let entry = CatalogueEntry(id: "STORE-07", family: "STORE", scenario: "resume", dueMilestone: "M2", evidenceLayers: [.nativeStorage, .integration])
        let catalogue = Catalogue(entries: [entry])
        let results = [
            CaseResult(caseID: "STORE-07", variantID: "in-memory", testStatus: .fail, evidenceTier: .pure),
            CaseResult(caseID: "STORE-07", variantID: "sqlite", testStatus: .pass, evidenceTier: .nativeStorage),
        ]
        let reconciliation = ResultsReconciler.reconcile(
            catalogue: catalogue, results: results, requiredVariants: ["STORE-07": ["sqlite"]])
        guard case .consistent(let report) = reconciliation else {
            Issue.record("expected a consistent report, got \(reconciliation)")
            return
        }
        #expect(report.unsatisfied == ["STORE-07"], "a failing mock pin vetoes certification")
        #expect(report.satisfied.isEmpty)
    }

    @Test("BDD-02 a low-tier required variant never certifies the case")
    func BDD_02_lowTierRequiredVariantNeverCertifies() throws {
        // Fail-closed tier rule: the required `sqlite` variant passes its
        // test but carries `.pure` evidence — the native requirement is
        // uncertified and the case stays unsatisfied (never a pass).
        let entry = CatalogueEntry(id: "STORE-07", family: "STORE", scenario: "resume", dueMilestone: "M2", evidenceLayers: [.nativeStorage, .integration])
        let catalogue = Catalogue(entries: [entry])
        for tier in [EvidenceLayer.pure, .nativeProcess] {
            let results = [
                CaseResult(caseID: "STORE-07", variantID: "sqlite", testStatus: .pass, evidenceTier: tier),
            ]
            guard case .consistent(let report) = ResultsReconciler.reconcile(
                catalogue: catalogue, results: results, requiredVariants: ["STORE-07": ["sqlite"]]) else {
                Issue.record("expected a consistent report, got tier \(tier)"); return
            }
            #expect(report.unsatisfied == ["STORE-07"], "\(tier) evidence must not certify native storage")
            #expect(report.satisfied.isEmpty)
        }
    }

    @Test("BDD-04 a skipped sibling vetoes satisfaction without required variants")
    func BDD_04_skippedSiblingVetoesSatisfaction() throws {
        // The ingestion layer records executed-but-skipped tests as
        // `.deferredByPlan`. Even with no required variants, the deferred
        // record fails its test gate, so passing siblings cannot carry the
        // case — a skip is unsatisfied, never a silent pass.
        let entry = CatalogueEntry(id: "WIRE-01", family: "WIRE", scenario: "byte splits", dueMilestone: "M1", evidenceLayers: [.integration])
        let catalogue = Catalogue(entries: [entry])
        let results = [
            CaseResult(caseID: "WIRE-01", variantID: "byte-split-1", testStatus: .pass),
            CaseResult(caseID: "WIRE-01", variantID: "byte-split-2", testStatus: .deferredByPlan),
        ]
        guard case .consistent(let report) = ResultsReconciler.reconcile(catalogue: catalogue, results: results) else {
            Issue.record("expected a consistent report"); return
        }
        #expect(report.unsatisfied == ["WIRE-01"], "a skipped sibling must veto satisfaction")
        #expect(report.satisfied.isEmpty)
    }
}
