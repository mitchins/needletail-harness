/// M1-A explicit bounds (SPEC §5). Profile-adjustable only via config
/// edits in later milestones, never silently enlarged by the harness.
public enum ConfigLimits {
    /// Maximum configuration file size. Reads stop at `maxFileBytes + 1`
    /// and fail, so a FIFO or concurrently grown file cannot OOM the loader.
    public static let maxFileBytes = 1_048_576
    /// Maximum serialized size of one `request_options` object.
    public static let maxRequestOptionsBytes = 65_536
    /// Maximum JSON nesting depth enforced by the preflight scanner.
    public static let maxNestingDepth = 32
    /// Maximum size of a single credential value read from a file.
    public static let maxCredentialBytes = 65_536

    public static let contextWindow = 1...16_777_216
    public static let maxOutput = 1...131_072
    public static let connectTimeout = 1...120
    public static let readIdleTimeout = 1...1_800
    public static let requestTimeout = 1...1_800
    public static let maxInFlight = 1...16
    public static let allowOrigins = 0...32
}
