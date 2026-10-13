/// NeedletailCore owns pure domain value contracts shared by the CLI, the
/// providers, the runtime and the behaviour-case ledger. It imports no
/// terminal, HTTP, SQLite or process implementations (architecture gates §8).

/// Semantic version of the harness build. Pure value type; used by the CLI
/// entry point and by reporter fixtures so test identity never depends on
/// a wall clock or environment read.
public struct NeedletailVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses `major.minor.patch`. Components are canonical decimal: ASCII
    /// digits, no sign, no leading zero unless the component is exactly
    /// "0". No normalization, no partial versions (CFG-05 spirit:
    /// identity strings are never coerced or reinterpreted).
    public init?(parsing text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy(Self.isCanonicalComponent),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2])
        else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    private static func isCanonicalComponent(_ part: Substring) -> Bool {
        guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        return part.count == 1 || part.first != "0"
    }

    public static func < (lhs: NeedletailVersion, rhs: NeedletailVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}
