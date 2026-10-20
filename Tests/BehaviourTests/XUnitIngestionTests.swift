import Testing
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import NeedletailCore
import NeedletailTestSupport

/// M2-0 runner-result ingestion: joins ACTUAL Swift Testing xunit output to
/// the catalogue via the existing `ResultsReconciler` — the only reconciler.
///
/// How to run: `./dev coverage` executes the evidence suites with
/// `swift test --xunit-output <base>` (SwiftPM writes `<base>-swift-testing.xml`;
/// verified on Swift 6.4), deletes any previous file first so a stale report
/// can never pass, then re-runs ONLY this suite with `NT_XUNIT_PATH` set to
/// the fresh file. Outside `./dev coverage` this test is disabled (same
/// `.enabled(if:)` precedent as the qualification fixtures): an ingestion
/// test with nothing to ingest must skip, never invent results.
///
/// Join rules (documented limits, all verified against real runner output):
/// - Case IDs come from the Swift FUNCTION name (`STATE_01_...` →
///   `STATE-01`), because xunit carries `classname` + function name but NOT
///   the `@Test` display name. Functions without a case prefix are tallied
///   as unlabeled, never failed.
/// - Variant IDs are the bare function names; the M2-0 `requiredVariants`
///   below name the exact functions expected, so a rename fails loudly.
/// - `<skipped>` is RECORDED as a `.deferredByPlan` result: a skipped case
///   lands in `unsatisfied` and can never satisfy its gate (BDD-04) —
///   not missing, not passed. `<failure>`/`<error>` → FAIL.
/// - Parameterized cases collapse to ONE `<testcase>` in xunit (verified):
///   per-argument variants are invisible to this join — a documented gap,
///   not silently assumed coverage.
/// - Evidence tiers come from the executing target (verified mapping): real
///   SQLite/process execution is the only native evidence; everything
///   in-process is pure/integration at best.
private var ingestionEnabled: Bool {
    // Both halves are set ONLY by the ./dev coverage branch: a stray
    // NT_XUNIT_PATH in the ambient environment must not activate ingestion
    // against an arbitrary file.
    ProcessInfo.processInfo.environment["NT_COVERAGE_ACTIVE"] == "1"
        && ProcessInfo.processInfo.environment["NT_XUNIT_PATH"] != nil
}

struct XUnitIngestionTests {

    private struct ExecutedCase {
        var function: String
        var suite: String
        var module: String
        var skipped: Bool
        var failed: Bool
    }

    private final class Parser: NSObject, XMLParserDelegate, @unchecked Sendable {
        var cases: [ExecutedCase] = []
        private var current: ExecutedCase?

        func parser(_ parser: XMLParser, didStartElement name: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            if name == "testcase" {
                let qualified = attributes["classname"] ?? ""
                let parts = qualified.split(separator: ".", maxSplits: 1).map(String.init)
                current = ExecutedCase(
                    function: attributes["name"]?.replacingOccurrences(of: "()", with: "")
                        .replacingOccurrences(of: "\\(.*\\)$", with: "", options: .regularExpression) ?? "",
                    suite: parts.count > 1 ? parts[1] : "",
                    module: parts.first ?? "",
                    skipped: false, failed: false)
            } else if name == "skipped" {
                current?.skipped = true
            } else if name == "failure" || name == "error" {
                current?.failed = true
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String,
                    namespaceURI: String?, qualifiedName: String?) {
            if name == "testcase", let done = current {
                cases.append(done)
                current = nil
            }
        }
    }

    private static func splitCaseID(function: String) -> (caseID: String, variantID: String)? {
        // Family: one or more all-caps tokens, terminated by a two-digit
        // number, followed by at least one description token
        // (STORE_07_sqlite... → STORE-07; UX_UNDO_02_... → UX-UNDO-02).
        let tokens = function.split(separator: "_").map(String.init)
        var family: [String] = []
        var index = 0
        while index < tokens.count,
              tokens[index].allSatisfy({ $0.isUppercase || $0.isNumber }),
              !(tokens[index].count == 2 && tokens[index].allSatisfy(\.isNumber)) {
            family.append(tokens[index])
            index += 1
        }
        guard !family.isEmpty,
              index + 1 < tokens.count,
              tokens[index].count == 2, tokens[index].allSatisfy(\.isNumber) else { return nil }
        return (family.joined(separator: "-") + "-" + tokens[index], function)
    }

    private static func tier(module: String, function: String) -> EvidenceLayer {
        let lower = function.lowercased()
        if module == "NeedletailPrimitiveTests",
           (lower.contains("sqlite") || lower.contains("sigkill")) {
            return .nativeStorage
        }
        switch module {
        case "NeedletailPrimitiveTests",
             "NeedletailConfigIntegrationTests",
             "NeedletailProviderIntegrationTests":
            return .nativeProcess
        case "NeedletailTerminalTests":
            return .pty
        case "NeedletailActorTests":
            return .integration
        default:
            return .pure
        }
    }

    /// The M2-0 scope: every case this milestone must satisfy. `required`
    /// names the CERTIFYING functions (tier-adequate); mock-tier pins of the
    /// same shared contract (in-memory) are reported variants that must pass
    /// their test gates but never veto native certification — and a rename
    /// of any listed function fails loudly. `requiredModule` pins WHERE each
    /// certifying function must execute: a `sqlite`/`sigkill` name in a
    /// pure target would be tier fraud, so module attribution is asserted,
    /// not assumed from the substring.
    private static let requiredEvidence: [String: [String: String]] = [
        "STATE-01": ["STATE_01_cancelledLateCompletionReplays": "NeedletailStateTests"],
        "STORE-01": ["STORE_01_sqliteProductionStorePersistsAcrossReopen": "NeedletailPrimitiveTests",
                     "STORE_01_sqliteDurabilityPragmasHoldOnOwnConnection": "NeedletailPrimitiveTests"],
        "STORE-05": ["STORE_05_sqliteFutureOrCorruptStoreFailsClosed": "NeedletailPrimitiveTests"],
        "STORE-06": ["STORE_06_sqliteTwoWritersCompeteForOneSession": "NeedletailPrimitiveTests"],
        "STORE-07": ["STORE_07_sqliteProductionResumeAtScale": "NeedletailPrimitiveTests"],
        "STORE-09": ["STORE_09_sqliteProductionQuotasEnforceInTransaction": "NeedletailPrimitiveTests"],
        "STORE-02": ["STORE_02_sigkillMidTransactionRollsBack": "NeedletailPrimitiveTests",
                      "STORE_02_sqliteKillBeforeIntentCommitLeavesNothing": "NeedletailPrimitiveTests",
                      "STORE_02_sqliteKillAfterIntentCommitHoldsUnknown": "NeedletailPrimitiveTests",
                      "STORE_02_sqliteKillAfterSideEffectHoldsWithoutRedispatch": "NeedletailPrimitiveTests",
                      "STORE_02_sqliteKillBeforeResultCommitDerivesUncertainty": "NeedletailPrimitiveTests",
                      "STORE_02_sqliteKillAfterResultCommitSurvivesComplete": "NeedletailPrimitiveTests",
                      "STORE_02_sqliteInterruptedArtifactTmpReportsNoReference": "NeedletailPrimitiveTests",
                      "STORE_02_sqliteRenamedArtifactWithoutReferenceIsOrphan": "NeedletailPrimitiveTests",
                      "STORE_02_sqliteCommittedArtifactReferenceReadsVerified": "NeedletailPrimitiveTests"],
        "PORT-04": ["PORT_04_sqliteNativeKillReopenLegMustExecute": "NeedletailPrimitiveTests"],
        "STORE-03": ["STORE_03_sqliteRenamedArtifactWithoutReferenceIsReportedOrphan": "NeedletailPrimitiveTests"],
        "STORE-04": ["STORE_04_sqliteReferenceToAbsentArtifactFailsTypedIntegrity": "NeedletailPrimitiveTests"],
    ]

    private static var requiredVariants: [String: Set<String>] {
        requiredEvidence.mapValues { Set($0.keys) }
    }

    /// Cases whose CERTIFYING evidence does not exist yet and is owed to a
    /// later milestone. EMPTY as of A2: STORE-06 landed
    /// (`STORE_06_sqliteTwoWritersCompeteForOneSession` — two independent
    /// handles, fenced writes/releases in the mutation transaction) and
    /// moved to `requiredEvidence`. The invariant below keeps this map and
    /// `requiredEvidence` disjoint; a future deferral registers here and
    /// hard-blocks its case from `satisfied` until the named test exists.
    private static let deferredToM2A: [String: Set<String>] = [:]
    @Test("BDD-01 ingestion joins executed runner results to the catalogue",
          .enabled(if: ingestionEnabled, "run via ./dev coverage (sets NT_XUNIT_PATH)"))
    func BDD_01_ingestionReconcilesExecutedResults() throws {
        let path = try #require(ProcessInfo.processInfo.environment["NT_XUNIT_PATH"],
                                "NT_XUNIT_PATH must point at fresh xunit output")
        let data = try #require(FileManager.default.contents(atPath: path),
                               "xunit output missing at \(path): ./dev coverage must regenerate it")
        let delegate = Parser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        // Require, not expect: reconciling a truncated parse would mix a
        // parse failure with derived gate failures and hide the root cause.
        try #require(parser.parse(), "xunit XML must parse")
        let executed = delegate.cases
        #expect(!executed.isEmpty, "runner reported zero test cases: no evidence ingested")

        var results: [CaseResult] = []
        var moduleByKey: [String: String] = [:]
        var unlabeled = 0
        var skippedKnown: [String] = []
        var xmlFailures: [String] = []
        for test in executed {
            guard let (caseID, variantID) = Self.splitCaseID(function: test.function) else {
                unlabeled += 1
                continue
            }
            if test.failed { xmlFailures.append("\(caseID)/\(variantID)") }
            if test.skipped {
                // A skip is RECORDED, never dropped: a skipped variant with
                // passing siblings must still leave the case unsatisfied
                // (BDD-04). `.deferredByPlan` is the vocabulary's "not run in
                // this gate" status; its test gate fails, so it vetoes
                // satisfaction without claiming a failure occurred.
                skippedKnown.append(caseID)
                results.append(CaseResult(
                    caseID: caseID, variantID: variantID,
                    testStatus: .deferredByPlan,
                    evidenceTier: Self.tier(module: test.module, function: test.function)))
                continue
            }
            moduleByKey["\(caseID)/\(variantID)"] = test.module
            results.append(CaseResult(
                caseID: caseID, variantID: variantID,
                testStatus: test.failed ? .fail : .pass,
                evidenceTier: Self.tier(module: test.module, function: test.function)))
        }

        let catalogue = try CatalogueStore.loadCatalogue()
        let reconciliation = ResultsReconciler.reconcile(
            catalogue: catalogue, results: results, requiredVariants: Self.requiredVariants)
        guard case .consistent(let report) = reconciliation else {
            Issue.record("ingestion invalid: \(reconciliation)")
            return
        }
        // `results` holds every labeled executed test (passes, failures AND
        // recorded skips); `skippedKnown` is the labeled-skip subset.
        print("INGEST: executed=\(executed.count) labeled=\(results.count) unlabeled=\(unlabeled) skipped=\(skippedKnown.count) failed=\(xmlFailures.count) satisfied=\(report.satisfied.count) unsatisfied=\(report.unsatisfied.count) missing=\(report.missing.count)")
        #expect(xmlFailures.isEmpty, "executed failures in evidence: \(xmlFailures)")
        for (caseID, variants) in Self.requiredEvidence {
            for (variantID, expectedModule) in variants {
                #expect(moduleByKey["\(caseID)/\(variantID)"] == expectedModule,
                        "certifying evidence \(caseID)/\(variantID) must execute in \(expectedModule), ran in \(moduleByKey["\(caseID)/\(variantID)"] ?? "nowhere")")
            }
        }
        for caseID in Self.requiredVariants.keys.sorted() {
            #expect(report.satisfied.contains(caseID),
                    "M2-0 scope case \(caseID) must be satisfied; unsatisfied=\(report.unsatisfied) missing=\(report.missing.filter { Self.requiredVariants.keys.contains($0) })")
        }
        // Skipped known cases are RECORDED as deferred results, hence
        // unsatisfied — a skip is never a pass and never silently missing
        // (BDD-04). Pin it for every skipped case the extractor recognised.
        for caseID in Set(skippedKnown) {
            #expect(report.unsatisfied.contains(caseID),
                    "skipped case \(caseID) must be unsatisfied, not satisfied or missing")
            #expect(!report.satisfied.contains(caseID), "skipped case \(caseID) must not be satisfied")
        }
        // Deferred-to-M2A cases must NEVER be satisfied by the evidence that
        // exists today, whatever else passes (BDD-03/04 — absent required
        // evidence is never a pass).
        for caseID in Self.deferredToM2A.keys.sorted() {
            #expect(!report.satisfied.contains(caseID),
                    "deferred case \(caseID) is not certifiable in M2-0; satisfied=\(report.satisfied)")
        }
        // Maps invariant (A2): a case is either required-here or deferred —
        // never both, and every deferred case must be due eventually.
        #expect(Set(Self.requiredEvidence.keys).isDisjoint(with: Self.deferredToM2A.keys),
                "requiredEvidence and deferredToM2A must be disjoint")
    }

    @Test("native kill/reopen evidence is pinned to the production tier")
    func nativeKillEvidencePinnedToProductionTier() {
        // PORT-04 exists precisely to stop in-memory success from masking a
        // missing native leg: deleting or re-pointing this entry must fail
        // loudly here, not silently weaken the gate. Same for the STORE-02
        // production matrix: the old DELETE-mode sqlite3-CLI probe alone
        // must never satisfy the final contract again.
        #expect(Self.requiredEvidence["PORT-04"] ==
                ["PORT_04_sqliteNativeKillReopenLegMustExecute": "NeedletailPrimitiveTests"],
                "PORT-04 must require the native kill/reopen variant")
        let store02 = Self.requiredEvidence["STORE-02"] ?? [:]
        for variant in [
            "STORE_02_sqliteKillBeforeIntentCommitLeavesNothing",
            "STORE_02_sqliteKillAfterIntentCommitHoldsUnknown",
            "STORE_02_sqliteKillAfterSideEffectHoldsWithoutRedispatch",
            "STORE_02_sqliteKillBeforeResultCommitDerivesUncertainty",
            "STORE_02_sqliteKillAfterResultCommitSurvivesComplete",
            "STORE_02_sqliteInterruptedArtifactTmpReportsNoReference",
            "STORE_02_sqliteRenamedArtifactWithoutReferenceIsOrphan",
            "STORE_02_sqliteCommittedArtifactReferenceReadsVerified",
        ] {
            #expect(store02[variant] == "NeedletailPrimitiveTests",
                    "STORE-02 must require production variant \(variant)")
        }
        #expect(store02["STORE_02_sigkillMidTransactionRollsBack"] == "NeedletailPrimitiveTests",
                "the original DELETE-mode probe stays as supplementary evidence")
    }
}
