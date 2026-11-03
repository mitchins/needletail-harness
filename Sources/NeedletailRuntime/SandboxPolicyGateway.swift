import Foundation
import NeedletailCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// M3-D Docker amendment: container-scoped automatic approval.
///
/// This gateway approves ONLY inside a benchmark container the trusted
/// launcher built, and ONLY against an immutable launcher-issued grant
/// bound to that container and its disposable workspace. It NEVER
/// approves on an ordinary host run: without a valid grant whose
/// container identity matches the live hostname, every decision is
/// `.unavailable` (exit 3, fail closed — the exact headless behavior).
///
/// Threat model (documented limitation): the adversary is the MODEL
/// (untrusted text that can only act through validated tool calls), not
/// a host user. Inside the container the model cannot change the
/// hostname (CAP_SYS_ADMIN is dropped), cannot rewrite the read-only
/// grant mount, and cannot escape path confinement (the executor
/// enforces FD-level confinement; this gateway enforces the coarser
/// grant scope). A host user with file-write privileges could mint a
/// grant — equivalent in power to the pre-existing `--trusted` flag,
/// and strictly narrower in scope; host TTY policy is unchanged.
///
/// What is evaluated: the VALIDATED `ToolBatch` carried on the
/// `ApprovalRequest` (parsed arguments, validator-derived paths, bound
/// exec identities) — never the rendered `operation` display text, which
/// is untrusted model-influenced rendering.
public struct SandboxPolicyGateway: ApprovalGateway, Sendable {
    /// Launcher-issued per-run grant (JSON, read-only mount in the
    /// container, e.g. `/grant/grant.json`).
    public struct Grant: Sendable, Equatable, Codable {
        public let version: Int
        public let runID: String
        public let containerID: String
        /// Canonical disposable workspace (e.g. `/workspace`).
        public let workspace: String
        /// Tool names the model may use (subset of read/search/edit/write/exec).
        public let allowedTools: [String]
        /// Executable basenames the model may run (e.g. python3, node, swiftc).
        public let allowedExec: [String]

        public init(version: Int = 1, runID: String, containerID: String, workspace: String, allowedTools: [String], allowedExec: [String]) {
            self.version = version
            self.runID = runID
            self.containerID = containerID
            self.workspace = workspace
            self.allowedTools = allowedTools
            self.allowedExec = allowedExec
        }
    }

    private let grantPath: String
    /// Override for the live hostname (tests only — production always
    /// passes nil and reads the real hostname, which a contained model
    /// cannot change).
    private let containerIDOverride: String?

    public init(grantPath: String, containerID: String? = nil) {
        self.grantPath = grantPath
        self.containerIDOverride = containerID
    }

    public func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
        guard let grant = loadGrant() else {
            return .unavailable("sandbox grant missing or invalid; fail closed")
        }
        guard grant.version == 1 else {
            return .unavailable("sandbox grant version unsupported; fail closed")
        }
        guard grant.containerID == Self.containerID(override: containerIDOverride) else {
            return .unavailable("sandbox grant container mismatch; fail closed")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: grant.workspace, isDirectory: &isDir), isDir.boolValue else {
            return .unavailable("sandbox workspace missing; fail closed")
        }
        let workspace = Self.canonical(grant.workspace)
        // The batch under approval, structurally validated. The
        // transition validated it before requesting approval; re-validating
        // here keeps the policy independent of that path.
        let validated: [ValidatedToolCall]
        do {
            validated = try ToolValidator.validateBatchArguments(batch: request.batch)
        } catch {
            return .unavailable("sandbox batch failed validation; fail closed")
        }
        guard !validated.isEmpty else {
            return .unavailable("sandbox cannot approve an empty batch")
        }
        for call in validated {
            guard grant.allowedTools.contains(call.tool) else {
                return .unavailable("sandbox denies tool \(call.tool); fail closed")
            }
            for path in call.paths {
                guard Self.isWithinWorkspace(path, workspace: workspace) else {
                    return .unavailable("sandbox denies out-of-workspace path; fail closed")
                }
            }
            if call.tool == "exec" {
                guard request.execIdentities.contains(where: { $0.callID == call.callID }) else {
                    return .unavailable("sandbox denies unbound exec identity; fail closed")
                }
                let args: ExecArguments
                do {
                    args = try ToolValidator.execArguments(fromRaw: call.rawArguments)
                } catch {
                    return .unavailable("sandbox denies unparseable exec; fail closed")
                }
                // Both the requested and the RESOLVED basenames must be
                // allowlisted: a workspace-local symlink named `python3`
                // pointing elsewhere passes only if its target is also
                // an allowed interpreter (interpreters already provide
                // arbitrary execution, so this is naming hygiene, not a
                // new capability boundary — the container is).
                let base = (args.executable as NSString).lastPathComponent
                let resolvedBase = (request.execIdentities.first(where: { $0.callID == call.callID })?.resolvedPath as NSString?)?.lastPathComponent ?? ""
                guard !base.isEmpty, grant.allowedExec.contains(base), grant.allowedExec.contains(resolvedBase) else {
                    return .unavailable("sandbox denies exec outside the allowlist; fail closed")
                }
                if let cwd = args.cwd, !Self.isWithinWorkspace(cwd, workspace: workspace) {
                    return .unavailable("sandbox denies out-of-workspace cwd; fail closed")
                }
            }
        }
        return .sandboxGrant(note: "sandbox:\(grant.runID):\(grant.containerID)")
    }

    private func loadGrant() -> Grant? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: grantPath)),
              let grant = try? JSONDecoder().decode(Grant.self, from: data),
              !grant.runID.isEmpty, !grant.containerID.isEmpty, !grant.workspace.isEmpty else {
            return nil
        }
        return grant
    }

    private static func containerID(override: String?) -> String {
        if let override { return override }
        var name = [CChar](repeating: 0, count: 256)
        guard gethostname(&name, name.count) == 0 else { return "" }
        return String(cString: name)
    }

    /// Lexical canonicalization (no FS touch): absolute-izes relative
    /// paths against the workspace, collapses `.`/`..`, squeezes
    /// duplicate slashes. Symlink races are the executor's domain
    /// (FD-level confinement); this layer enforces grant scope.
    public static func canonical(_ path: String, relativeTo workspace: String? = nil) -> String {
        let absolute: String
        if path.hasPrefix("/") {
            absolute = path
        } else if let workspace {
            absolute = workspace + "/" + path
        } else {
            absolute = "/" + path
        }
        var parts: [String] = []
        for component in absolute.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(String(component))
        }
        return "/" + parts.joined(separator: "/")
    }

    public static func isWithinWorkspace(_ path: String, workspace: String) -> Bool {
        let base = canonical(workspace)
        let candidate = canonical(path, relativeTo: workspace)
        return candidate == base || candidate.hasPrefix(base + "/")
    }
}
