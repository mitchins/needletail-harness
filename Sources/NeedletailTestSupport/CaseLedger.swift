import Foundation
import NeedletailCore

/// NeedletailTestSupport is the tiny development-support layer required by
/// TESTING §2: it associates stable case IDs with evidence layers, loads the
/// frozen catalogue, reconciles it against the specification, and classifies
/// per-case results with the official status vocabulary. It is development
/// tooling, never linked into the shipped harness.
///
/// Assertions stay in Swift Testing; nothing here wraps or replaces them.

// MARK: - Case identity

/// A stable catalogue identifier, e.g. `UX-UNDO-02` or `UX-MENTION-11`.
/// Family groups are uppercase words separated by hyphens, followed by a
/// two-digit numeric suffix. Format validation here is deliberate: an
/// unknown or malformed ID is a reconciliation failure (BDD-01), never a
/// silently ignored label.
public struct CaseID: Sendable, Equatable, Hashable, CustomStringConvertible {
    public let raw: String

    public init?(_ raw: String) {
        // The numeric suffix is separated by the LAST hyphen; family groups
        // may themselves contain hyphens.
        guard let separator = raw.lastIndex(of: "-") else { return nil }
        let family = raw[..<separator]
        let suffix = raw[raw.index(after: separator)...]
        guard !family.isEmpty, !suffix.isEmpty else { return nil }
        // Suffix must be plain digits; never coerced or re-formatted.
        guard suffix.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        guard Int(suffix) != nil else { return nil }
        // Family: uppercase alphanumeric words joined by single hyphens.
        guard family.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
        let words = family.split(separator: "-", omittingEmptySubsequences: false)
        guard !words.contains(where: { $0.isEmpty }) else { return nil }
        self.raw = raw
    }

    public var description: String { raw }
}

/// Evidence layers, per TESTING §3. A pass at a lower layer never satisfies
/// an obligation that requires a higher one.
public enum EvidenceLayer: String, Sendable, Equatable, Codable, CaseIterable {
    case pure
    case integration
    case nativeProcess     // real processes / filesystem
    case nativeStorage     // real SQLite reopen / crash points
    case terminalAdapter
    case pty
    case liveProvider
    case packaging
    case reviewProcess
}

/// The official status vocabulary (DEVELOPMENT §6). Test, review and
/// environment status are separate fields in every record.
public enum CaseStatus: String, Sendable, Equatable, Codable {
    case pass = "PASS"
    case fail = "FAIL"
    case blockedReview = "BLOCKED_REVIEW"
    case unqualifiedEnvironment = "UNQUALIFIED_ENVIRONMENT"
    case deferredByPlan = "DEFERRED_BY_PLAN"
    case notImplemented = "NOT_IMPLEMENTED"

    /// True only for PASS. Every other value is an unsatisfied gate.
    public var isSatisfied: Bool { self == .pass }
}

// MARK: - Catalogue files

public struct CatalogueEntry: Sendable, Equatable, Codable {
    public var id: String
    public var family: String
    public var scenario: String
    public var dueMilestone: String
    public var evidenceLayers: [EvidenceLayer]
    /// Catalog-side annotations (disposition status, executed-evidence
    /// pointers). Optional so the frozen expectation fixture does not need
    /// to duplicate them; decoding ignores absence, and the field round-trips
    /// when the catalog is re-encoded.
    public var status: String?
    public var statusDetail: String?

    public init(id: String, family: String, scenario: String, dueMilestone: String, evidenceLayers: [EvidenceLayer], status: String? = nil, statusDetail: String? = nil) {
        self.id = id
        self.family = family
        self.scenario = scenario
        self.dueMilestone = dueMilestone
        self.evidenceLayers = evidenceLayers
        self.status = status
        self.statusDetail = statusDetail
    }

    enum CodingKeys: String, CodingKey {
        case id, family, scenario, status
        case dueMilestone = "due_milestone"
        case evidenceLayers = "evidence_layers"
        case statusDetail = "status_detail"
    }
}

public struct Catalogue: Sendable, Equatable {
    public var entries: [CatalogueEntry]

    public init(entries: [CatalogueEntry]) { self.entries = entries }

    public var ids: Set<String> { Set(entries.map(\.id)) }

    /// Duplicate case IDs are a reconciliation error, not a cosmetic one.
    public var duplicateIDs: [String] {
        var seen: Set<String> = []
        var duplicates: [String] = []
        for entry in entries where !seen.insert(entry.id).inserted {
            duplicates.append(entry.id)
        }
        return duplicates
    }
}

/// The on-disk envelope of `cases/catalog.json` and
/// `cases/expected-index.json`. The catalogue itself is derived from it.
public struct CatalogueFile: Sendable, Equatable, Codable {
    public var catalogue: String
    public var formatVersion: Int
    public var caseCount: Int?
    public var currentMilestone: String?
    public var provenance: String
    public var entries: [CatalogueEntry]

    enum CodingKeys: String, CodingKey {
        case catalogue
        case formatVersion = "format_version"
        case caseCount = "case_count"
        case currentMilestone = "current_milestone"
        case provenance
        case entries
    }
}

/// Locates the repository root from a test source file path so fixtures and
/// the spec edition are read from their committed locations.
func repositoryRoot(fromTestFile testFile: String = #filePath) -> String {
    var url = URL(fileURLWithPath: testFile)
    // <root>/Tests/<Target>/<File>.swift
    for _ in 0..<3 { url.deleteLastPathComponent() }
    return url.path
}

public enum FixtureError: Error, Equatable, CustomStringConvertible {
    case missingFile(String)
    case undecodable(String, String)

    public var description: String {
        switch self {
        case .missingFile(let path): return "missing fixture file: \(path)"
        case .undecodable(let path, let message): return "undecodable fixture \(path): \(message)"
        }
    }
}

public enum CatalogueStore {
    static let catalogueFileName = "catalog.json"
    static let expectedIndexFileName = "expected-index.json"
    static let specFileName = "COMPLETE-SPEC.md"

    private static func loadFile(name: String, root: String?) throws -> Catalogue {
        let base = root ?? repositoryRoot()
        let path = base + "/cases/" + name
        guard let data = FileManager.default.contents(atPath: path) else {
            throw FixtureError.missingFile(path)
        }
        guard let file = try? JSONDecoder().decode(CatalogueFile.self, from: data) else {
            throw FixtureError.undecodable(path, "schema mismatch")
        }
        return Catalogue(entries: file.entries)
    }

    public static func loadCatalogue(root: String? = nil) throws -> Catalogue {
        try loadFile(name: catalogueFileName, root: root)
    }

    public static func loadExpectedIndex(root: String? = nil) throws -> Catalogue {
        try loadFile(name: expectedIndexFileName, root: root)
    }

    /// Extracts case IDs from the ACCEPTANCE.md tables embedded in the
    /// generated reading edition (Part 10). The standalone ACCEPTANCE.md is
    /// not present in this workspace; provenance is recorded in STATUS.md.
    public static func specCaseIDs(root: String? = nil) throws -> Set<String> {
        let base = root ?? repositoryRoot()
        let path = base + "/" + specFileName
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw FixtureError.missingFile(path)
        }
        var ids: Set<String> = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Table rows look like: | UX-UNDO-02 | scenario | result |
            guard line.hasPrefix("| ") else { continue }
            let cells = line.dropFirst(2).split(separator: "|", omittingEmptySubsequences: false)
            guard let first = cells.first else { continue }
            let candidate = first.trimmingCharacters(in: .whitespaces)
            if let id = CaseID(candidate), !candidate.contains(" ") {
                ids.insert(id.raw)
            }
        }
        return ids
    }
}

// MARK: - Result classification

/// One per-case result record, as a consumer (CI or `./dev coverage`) would
/// hand to the reconciler. Multiple variants of one behaviour share the case
/// ID and differ by `variantID`; duplicates of a (case, variant) pair are
/// errors. `kind: "example"` records are rejected outright: a valid-looking
/// JSON object cannot certify its own run (TESTING §11).
public struct CaseResult: Sendable, Equatable, Codable {
    public var caseID: String
    public var variantID: String
    public var testStatus: CaseStatus
    public var reviewStatus: CaseStatus?
    public var environmentStatus: CaseStatus?
    public var kind: String

    enum CodingKeys: String, CodingKey {
        case caseID = "case_id"
        case variantID = "variant_id"
        case testStatus = "test_status"
        case reviewStatus = "review_status"
        case environmentStatus = "environment_status"
        case kind
    }

    public init(caseID: String, variantID: String = "default", testStatus: CaseStatus,
                reviewStatus: CaseStatus? = nil, environmentStatus: CaseStatus? = nil,
                kind: String = "evidence") {
        self.caseID = caseID
        self.variantID = variantID
        self.testStatus = testStatus
        self.reviewStatus = reviewStatus
        self.environmentStatus = environmentStatus
        self.kind = kind
    }

    /// A case is satisfied only when every required field is PASS.
    public var satisfied: Bool {
        guard testStatus.isSatisfied else { return false }
        if let reviewStatus, !reviewStatus.isSatisfied { return false }
        if let environmentStatus, !environmentStatus.isSatisfied { return false }
        return true
    }
}

public struct ReconciliationReport: Sendable, Equatable {
    public var distinctCases: Int
    public var variantCount: Int
    public var satisfied: [String]
    public var unsatisfied: [String]
    public var missing: [String]
    public var unknown: [String]
    public var duplicates: [String]
    public var invalidReason: String?

    public var isConsistent: Bool { invalidReason == nil }

    public func status(ofCase caseID: String) -> CaseStatus {
        if unsatisfied.contains(caseID) || missing.contains(caseID) { return .fail }
        if satisfied.contains(caseID) { return .pass }
        return .fail
    }
}

public enum Reconciliation: Sendable, Equatable {
    case consistent(ReconciliationReport)
    case invalid(String)
}

/// Classifies a results report against the catalogue with the anti-inflation
/// rules: unknown IDs fail; duplicate coverage keys fail; cases due now but
/// absent from the report are reported missing, never assumed pass; example
/// records cannot certify anything. A case's status is the least-satisfied
/// status across its variants and across the test/review/environment fields,
/// which are kept separate (DEVELOPMENT §6).
public enum ResultsReconciler {
    public static func reconcile(catalogue: Catalogue, results: [CaseResult]) -> Reconciliation {
        // 1. Example/placeholder records cannot certify anything.
        if results.contains(where: { $0.kind == "example" }) {
            return .invalid("example-kind result records are not evidence (TESTING §11)")
        }

        // 2. Unknown IDs are failures with the exact identifier.
        let unknowns = Set(results.map(\.caseID)).subtracting(catalogue.ids).sorted()
        if !unknowns.isEmpty {
            return .invalid("unknown case IDs in results: \(unknowns.joined(separator: ", "))")
        }

        // 3. Duplicate coverage keys are errors.
        var seen: Set<String> = []
        var duplicates: [String] = []
        for result in results {
            let key = "\(result.caseID)/\(result.variantID)"
            if !seen.insert(key).inserted { duplicates.append(key) }
        }
        if !duplicates.isEmpty {
            return .invalid("duplicate case/variant keys in results: \(duplicates.sorted().joined(separator: ", "))")
        }

        // 4. Group variants per case; count distinct semantic cases once
        //    (BDD-02) and never let a missing case look like a pass (BDD-03/04).
        let reportedIDs = Set(results.map(\.caseID))
        let missing = catalogue.ids.subtracting(reportedIDs).sorted()

        var satisfied: [String] = []
        var unsatisfied: [String] = []
        for caseID in reportedIDs.sorted() {
            let variants = results.filter { $0.caseID == caseID }
            if variants.allSatisfy(\.satisfied) {
                satisfied.append(caseID)
            } else {
                unsatisfied.append(caseID)
            }
        }

        let report = ReconciliationReport(
            distinctCases: reportedIDs.count,
            variantCount: results.count,
            satisfied: satisfied,
            unsatisfied: unsatisfied,
            missing: missing,
            unknown: [],
            duplicates: [],
            invalidReason: nil
        )
        return .consistent(report)
    }
}
