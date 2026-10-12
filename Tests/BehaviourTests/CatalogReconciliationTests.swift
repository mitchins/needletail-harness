import Testing
import NeedletailTestSupport

/// BDD-01 — Required behaviour test has no catalogue ID or an unknown ID.
/// Given the frozen catalogue and expectation fixture, when IDs are
/// reconciled, then missing/unknown identifiers fail with exact names and
/// nothing is silently counted. Forbidden: self-consistent drift between
/// catalog.json, expected-index.json and the specification inventory.
struct CatalogReconciliationTests {

    @Test("BDD-01 catalog and frozen expectation agree")
    func BDD_01_catalogMatchesFrozenExpectation() throws {
        let catalogue = try CatalogueStore.loadCatalogue()
        let expected = try CatalogueStore.loadExpectedIndex()

        #expect(catalogue.duplicateIDs.isEmpty, "duplicate catalogue case IDs: \(catalogue.duplicateIDs)")
        #expect(expected.duplicateIDs.isEmpty, "duplicate expectation case IDs: \(expected.duplicateIDs)")

        let onlyCatalogue = catalogue.ids.subtracting(expected.ids).sorted()
        let onlyExpected = expected.ids.subtracting(catalogue.ids).sorted()
        #expect(onlyCatalogue.isEmpty, "IDs present only in catalog.json: \(onlyCatalogue)")
        #expect(onlyExpected.isEmpty, "IDs present only in expected-index.json: \(onlyExpected)")

        // Entry-level agreement, not just ID-set agreement.
        for entry in catalogue.entries {
            guard let mirror = expected.entries.first(where: { $0.id == entry.id }) else {
                Issue.record("catalog entry \(entry.id) missing from expected-index.json")
                continue
            }
            #expect(mirror.scenario == entry.scenario, "scenario drift for \(entry.id)")
            #expect(mirror.dueMilestone == entry.dueMilestone, "due milestone drift for \(entry.id)")
            #expect(mirror.evidenceLayers == entry.evidenceLayers, "evidence layer drift for \(entry.id)")
        }
    }

    @Test("BDD-01 frozen expectation matches specification inventory")
    func BDD_01_expectationMatchesSpecificationInventory() throws {
        let expected = try CatalogueStore.loadExpectedIndex()
        let specIDs = try CatalogueStore.specCaseIDs()

        let onlySpec = specIDs.subtracting(expected.ids).sorted()
        let onlyFixture = expected.ids.subtracting(specIDs).sorted()
        #expect(onlySpec.isEmpty, "case IDs in COMPLETE-SPEC.md Part 10 but not in expected-index.json: \(onlySpec)")
        #expect(onlyFixture.isEmpty, "case IDs in expected-index.json but not in COMPLETE-SPEC.md Part 10: \(onlyFixture)")
        #expect(expected.entries.count == 200, "expected catalogue size 200, found \(expected.entries.count)")
    }

    @Test("BDD-01 unknown case ID is rejected with the exact identifier")
    func BDD_01_unknownCaseIDIsRejected() throws {
        let catalogue = try CatalogueStore.loadCatalogue()
        let results = [CaseResult(caseID: "UX-UNDO-99", testStatus: .pass)]
        let reconciliation = ResultsReconciler.reconcile(catalogue: catalogue, results: results)
        guard case .invalid(let reason) = reconciliation else {
            Issue.record("expected invalid reconciliation for unknown case ID")
            return
        }
        #expect(reason.contains("UX-UNDO-99"), "reason must name the exact identifier: \(reason)")
    }

    @Test("BDD-01 malformed case identifiers do not parse")
    func BDD_01_malformedCaseIdentifiersDoNotParse() {
        #expect(CaseID("UX-UNDO-02") != nil)
        #expect(CaseID("UX-MENTION-11") != nil, "hyphenated family groups are valid")
        #expect(CaseID("ux-undo-02") == nil, "family letters are uppercase in the catalogue")
        #expect(CaseID("UX-UNDO") == nil, "a case ID carries a numeric suffix")
        #expect(CaseID("UX UNDO 02") == nil, "spaces are not separators")
        #expect(CaseID("UX-UNDO-+2") == nil, "the suffix is plain digits")
        #expect(CaseID("-UNDO-02") == nil, "the family is non-empty")
        #expect(CaseID("UX---02") == nil, "family words are non-empty")
        #expect(CaseID("") == nil)
    }

    @Test("BDD-01 a well-formed but uncatalogued identifier is unknown, not silently accepted")
    func BDD_01_uncataloguedIdentifierIsUnknown() throws {
        let catalogue = try CatalogueStore.loadCatalogue()
        let results = [CaseResult(caseID: "UX-UNDO-2", testStatus: .pass)]
        let reconciliation = ResultsReconciler.reconcile(catalogue: catalogue, results: results)
        guard case .invalid(let reason) = reconciliation else {
            Issue.record("expected invalid reconciliation for an uncatalogued identifier")
            return
        }
        #expect(reason.contains("UX-UNDO-2"), "reason must name the exact identifier: \(reason)")
    }

    @Test("BDD-01 duplicate catalogue keys are detectable")
    func BDD_01_duplicateCatalogueKeysAreDetectable() {
        let entry = CatalogueEntry(id: "BDD-01", family: "BDD", scenario: "s", dueMilestone: "M0", evidenceLayers: [.reviewProcess])
        let catalogue = Catalogue(entries: [entry, entry])
        #expect(catalogue.duplicateIDs == ["BDD-01"])
    }

    @Test("BDD-01 missing fixture files produce actionable errors")
    func BDD_01_missingFixturesProduceActionableErrors() {
        do {
            _ = try CatalogueStore.loadCatalogue(root: "/nonexistent-root")
            Issue.record("expected a missingFile error for a nonexistent root")
        } catch let error as FixtureError {
            guard case .missingFile(let path) = error else {
                Issue.record("expected missingFile, got \(error)")
                return
            }
            #expect(path.contains("cases/catalog.json"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("BDD-04 catalog status vocabulary follows the due-milestone rule")
    func BDD_04_catalogStatusFollowsDueMilestoneRule() throws {
        let catalogue = try CatalogueStore.loadCatalogue()
        let currentMilestone = "M0"
        for entry in catalogue.entries {
            if entry.dueMilestone == currentMilestone {
                #expect(entry.status == "IMPLEMENTED" || entry.status == "NOT_IMPLEMENTED",
                        "\(entry.id): due \(entry.dueMilestone) must be IMPLEMENTED or NOT_IMPLEMENTED, got \(entry.status ?? "nil")")
                if entry.status == "IMPLEMENTED" {
                    let detail = try #require(entry.statusDetail, "\(entry.id): IMPLEMENTED requires an evidence pointer")
                    #expect(detail.contains("executed"), "\(entry.id): evidence pointer must name executed evidence: \(detail)")
                }
            } else {
                #expect(entry.status == "DEFERRED_BY_PLAN",
                        "\(entry.id): due \(entry.dueMilestone) is later than \(currentMilestone), must be DEFERRED_BY_PLAN, got \(entry.status ?? "nil")")
            }
        }
    }
}
