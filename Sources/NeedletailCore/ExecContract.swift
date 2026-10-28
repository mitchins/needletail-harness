import Foundation

/// M2-C C0: typed native-execution contract (plan REV12 §3.3/§3.4/§3.4b).
///
/// Core owns the pure contract: the parsed argument shape, the identity
/// values, the resolver REQUIREMENT (protocol — the implementation is
/// Runtime's filesystem work), the deterministic status mapping, and the
/// bounded approval rendering. No filesystem access, no Crypto: a content
/// digest ARRIVES as an opaque string computed by Runtime and is only
/// carried/compared here.

/// Parsed, shape-validated `exec` arguments (SPEC §8.5 shape; REV12 §3.3).
/// Direct argv execution is the default; there is no PATH search and no
/// shell string anywhere in the shape.
public struct ExecArguments: Sendable, Equatable {
    public static let defaultTimeoutSecs = 120
    public static let maxTimeoutSecs = 1800
    public static let maxArgvEntries = 64
    public static let maxExecCallsPerBatch = 8
    public static let maxEnvEntries = 32
    /// Bounded approval display: a command whose rendered description would
    /// exceed this is rejected `invalid-arguments` — an unrenderable
    /// command is unapprovable (plan REV12 §3.3).
    public static let maxDisplayBytes = 8 * 1024

    public let executable: String
    public let argv: [String]
    /// Workspace-relative directory; nil ⇒ workspace root (the only way to
    /// name the root: the component rules reject `.` and empty).
    public let cwd: String?
    public let timeoutSecs: Int
    public let env: [String: String]

    public init(executable: String, argv: [String], cwd: String?, timeoutSecs: Int, env: [String: String]) {
        self.executable = executable
        self.argv = argv
        self.cwd = cwd
        self.timeoutSecs = timeoutSecs
        self.env = env
    }
}

/// Per-call identity bound into the approval request and, on grant, into
/// the dispatch reservation. The digest is computed by Runtime over the
/// qualified file bytes plus dev/ino/size; Core only carries and compares.
public struct ExecCommandIdentity: Sendable, Equatable {
    public let callID: String
    public let requestedPath: String
    public let resolvedPath: String
    public let contentDigest: String
    /// M2-C C0 (plan REV12 §3.4): the resolved cwd identity (dev/ino) bound
    /// alongside the executable digest. C0 carries it through the approval
    /// and the reservation; C1's spawn re-verifies it (fail-closed: cwd swap
    /// ⇒ typed `conflict`).
    public let cwdDevice: UInt64
    public let cwdInode: UInt64

    public init(callID: String, requestedPath: String, resolvedPath: String, contentDigest: String, cwdDevice: UInt64 = 0, cwdInode: UInt64 = 0) {
        self.callID = callID
        self.requestedPath = requestedPath
        self.resolvedPath = resolvedPath
        self.contentDigest = contentDigest
        self.cwdDevice = cwdDevice
        self.cwdInode = cwdInode
    }
}

/// Runtime-computed identity for one exec proposal (resolution-phase
/// output). No fd crosses actor hops: the spawn re-resolves and compares.
public struct ResolvedExecIdentity: Sendable, Equatable {
    public let callID: String
    public let requestedPath: String
    public let resolvedPath: String
    public let device: UInt64
    public let inode: UInt64
    public let size: UInt64
    public let contentDigest: String
    public let cwdDevice: UInt64
    public let cwdInode: UInt64

    public init(callID: String, requestedPath: String, resolvedPath: String, device: UInt64, inode: UInt64, size: UInt64, contentDigest: String, cwdDevice: UInt64, cwdInode: UInt64) {
        self.callID = callID
        self.requestedPath = requestedPath
        self.resolvedPath = resolvedPath
        self.device = device
        self.inode = inode
        self.size = size
        self.contentDigest = contentDigest
        self.cwdDevice = cwdDevice
        self.cwdInode = cwdInode
    }
}

/// Typed resolution failures (plan REV12 §3.4b.1). Every case maps to a
/// DETERMINISTIC pre-dispatch status — a resolution failure is a proven
/// pre-dispatch failure, never an unknown.
public enum ExecResolutionError: Error, Sendable, Equatable {
    /// Requested executable does not exist or is unreachable.
    case notFound(String)
    /// cwd does not exist, escapes the workspace root, or is a read root.
    case cwd(String)
    /// Symlink-hop budget exhausted, non-file final, or
    /// permission/ownership qualification failure.
    case qualification(String)
    /// Aggregate resolution budget exceeded (plan NC-15).
    case budgetExceeded(String)
    /// The resolver cannot run at all (no resolver injected, identity
    /// mismatch in the reply, infrastructure refusal). Infrastructure
    /// refusal is NOT an identity-binding verdict: it maps to `failed`,
    /// reserving `conflict` for digest/cwd mismatches (NC-16).
    case unavailable(String)

    /// Deterministic pre-dispatch status (plan REV12 §3.3). `conflict` is
    /// reserved for binding verdicts; environment/infrastructure refusal
    /// maps to `failed` (REV10 decision f).
    public var preDispatchStatus: String {
        switch self {
        case .notFound, .qualification, .cwd, .budgetExceeded: return "invalid-arguments"
        case .unavailable: return "failed"
        }
    }

    public var preDispatchSummary: String {
        switch self {
        case .notFound(let m), .qualification(let m), .cwd(let m), .budgetExceeded(let m), .unavailable(let m):
            return m
        }
    }
}

/// The resolution REQUIREMENT lives in Core (no dependency edge): the
/// actor holds an injected implementation; Runtime's executor provides it.
/// Synchronous and filesystem-touching — performed inline by the actor
/// within one flight (plan REV12 §3.4b.3; bounded by NC-15 budgets).
public protocol ExecIdentityResolver: Sendable {
    func resolveIdentities(batch: ToolBatch) throws -> [ResolvedExecIdentity]
}

/// Seed stored in state for the resolution hop: binds the in-flight
/// resolution to its run and generation (checkStale arms match on it).
/// Ephemeral: phase 1 writes no records, so a crash mid-resolution simply
/// loses the pending approval (plan REV12 §3.4b.8).
public struct ExecResolutionSeed: Sendable, Equatable {
    public let resolutionID: String
    public let runID: RunID
    public let generation: Revision
    public let batchDigest: String
    public let grantablePaths: [String]

    public init(resolutionID: String, runID: RunID, generation: Revision, batchDigest: String, grantablePaths: [String] = []) {
        self.resolutionID = resolutionID
        self.runID = runID
        self.generation = generation
        self.batchDigest = batchDigest
        self.grantablePaths = grantablePaths
    }
}

// MARK: - Environment deny-set (plan REV12 §3.3 / NC-10)

/// Derive the registered env-credential names from the epoch (the
/// config snapshot carries every profile's credential). Used by the
/// reducer to reject an overlay key that would re-inject a harness
/// credential into a child (plan REV12 §3.3 / NC-10).
public func credentialEnvNames(in epoch: EpochDescriptor) -> Set<String> {
    var names: Set<String> = []
    for profile in epoch.configSnapshot.profiles.values {
        guard let cred = profile.credential else { continue }
        // Only env-backed credentials have a name to deny through the
        // overlay; file/keychain are disjoint namespaces.
        if case .env(let name) = cred.kind { names.insert(name) }
    }
    return names
}

public enum ExecEnvPolicy {
    /// Absolute deny-set: never settable through the overlay, checked at
    /// validation AND re-checked at the spawn-time merge (C1). Loader
    /// variables, interpreter-hijack channels, and harness/credential
    /// namespaces are refused outright; everything else is approvable by
    /// display — the operator sees and approves every exact key/value.
    private static let exactDenied: Set<String> = [
        "PATH", "IFS", "ENV", "BASH_ENV", "SHELLOPTS", "PS4",
        "GCONV_PATH", "GLIBC_TUNABLES", "RUBYOPT", "RUBYLIB",
        "NODE_OPTIONS", "NODE_PATH", "JAVA_TOOL_OPTIONS",
        "GIT_CONFIG_GLOBAL", "GIT_EXEC_PATH", "GIT_SSH_COMMAND",
        "SSH_AUTH_SOCK", "SSH_ASKPASS", "SSL_CERT_FILE", "LOCPATH",
    ]
    private static let prefixDenied = ["LD_", "DYLD_", "PERL5", "PYTHON", "BASH_FUNC_", "NEEDLETAIL_"]

    public static func isDenied(key: String) -> Bool {
        if exactDenied.contains(key) { return true }
        for prefix in prefixDenied where key.hasPrefix(prefix) { return true }
        return false
    }
}

// MARK: - Bounded approval rendering (plan REV12 §3.3)

/// Renders the operator-facing command description. Returns nil when the
/// rendering would exceed `ExecArguments.maxDisplayBytes` — the validator
/// rejects such proposals outright (an unrenderable command is
/// unapprovable: every approved byte is shown, nothing is elided).
/// The rendered text is terminal-safe at construction.
public func renderExecApprovalDisplay(_ args: ExecArguments) -> String? {
    func safe(_ s: String) -> String {
        // Terminal-safe projection: C0 control scalars (except tab) render
        // as escapes; non-ASCII scalars pass through (multibyte UTF-8 is
        // preserved, not mojibake'd). The later ApprovalRequest.terminalSafe
        // provides the injection defense; this is display-layer only.
        var out = ""
        for scalar in s.unicodeScalars {
            if scalar.value < 0x20 && scalar.value != 0x09 {
                out += String(format: "\\x%02x", scalar.value)
            } else if scalar.value == 0x7F {
                out += "\\x7f"
            } else {
                out.append(Character(scalar))
            }
        }
        return out
    }
    func quote(_ s: String) -> String { "'" + safe(s).replacingOccurrences(of: "'", with: "'\\''") + "'" }

    var parts: [String] = ["exec \(safe(args.executable))"]
    var argv = args.argv
    if !argv.isEmpty { argv[0] = args.executable }
    let argvRendered = argv.map(quote)
    var cwdPart = ""
    if let cwd = args.cwd { cwdPart = " cwd=\(safe(cwd))" }
    var envPart = ""
    if !args.env.isEmpty {
        let envRendered = args.env.sorted { $0.key < $1.key }.map { "\(safe($0.key))=\(quote(safe($0.value)))" }.joined(separator: " ")
        envPart = " env(\(envRendered))"
    }
    envPart += " timeout=\(args.timeoutSecs)s"
    parts.append("[\(argvRendered.joined(separator: ", "))]\(cwdPart)\(envPart)")
    let text = parts.joined(separator: " ")
    // Every byte the operator approves must be shown: an over-budget
    // command is unrenderable, hence unapprovable (fail closed — the
    // validator rejects the proposal; no argv is ever elided from
    // the approval display).
    if text.utf8.count > ExecArguments.maxDisplayBytes { return nil }
    return text
}
