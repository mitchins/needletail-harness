/// M1-A effective capabilities (SPEC §10.1–10.3, rev4-B/C). Pure and
/// deterministic: no filesystem, environment, network or clock access.
/// Denials dominate grants across five layers; repository instructions,
/// skills, tool outputs and model messages are not parameters and therefore
/// cannot enlarge the result. `--sealed` and `--tools none` deny **tools
/// only** — route authorization is independent (`RouteDecision`).
public struct ToolCapabilities: Sendable, Equatable, Codable {
    public let read: Bool
    public let search: Bool
    public let edit: Bool
    public let write: Bool
    public let exec: ExecPolicy
    public let consult: Bool

    public init(read: Bool, search: Bool, edit: Bool, write: Bool, exec: ExecPolicy, consult: Bool) {
        self.read = read
        self.search = search
        self.edit = edit
        self.write = write
        self.exec = exec
        self.consult = consult
    }

    public static let allAllowed = ToolCapabilities(
        read: true, search: true, edit: true, write: true, exec: .allowed, consult: true)
    public static let allDenied = ToolCapabilities(
        read: false, search: false, edit: false, write: false, exec: .denied, consult: false)

    public func intersected(with other: ToolCapabilities) -> ToolCapabilities {
        ToolCapabilities(
            read: read && other.read,
            search: search && other.search,
            edit: edit && other.edit,
            write: write && other.write,
            exec: exec.intersected(with: other.exec),
            consult: consult && other.consult)
    }

    /// Minting a grant from workspace/repo text is refused at the call
    /// site (R9): the only M1-A workspace source is the deny-all operator
    /// default until the M2 `trust` command gates its origin. The refused
    /// text is described by length only (S9) — never echoed, so secret
    /// bearing input cannot reach diagnostics through this path.
    public static func grant(fromUntrustedSource text: String) throws -> ToolCapabilities {
        throw ConfigError(
            path: "$.workspace", kind: .unsupportedCombination,
            message: "workspace content (\(text.count) bytes) cannot mint capability grants.",
            hint: "grants come only from the operator trust action (M2); repo text is task data.")
    }
}

public enum ExecPolicy: String, Sendable, Equatable, Codable {
    case denied
    case ask
    case allowed

    func intersected(with other: ExecPolicy) -> ExecPolicy {
        switch (self, other) {
        case (.denied, _), (_, .denied): return .denied
        case (.ask, _), (_, .ask): return .ask
        case (.allowed, .allowed): return .allowed
        }
    }
}

public enum RoutePolicy: String, Sendable, Equatable, Codable {
    case none
    case localOnly
}

/// Sealed mode carries no tool content — only the bit — so last-flag-wins
/// over tools is unrepresentable in the signature.
public struct SealedRestrictions: Sendable, Equatable {
    public let sealed: Bool
    public init(sealed: Bool) { self.sealed = sealed }
}

public struct EffectiveCapabilities: Sendable, Equatable, Codable {
    public let tools: ToolCapabilities
    /// M1-A routes local-only or denies per request (`selectRoute`); the
    /// policy field records the only routable class and never varies with
    /// sealing (rev4-B: tools/route independence).
    public let route: RoutePolicy
    /// Layers that denied at least one tool, for actionable diagnostics.
    public let deniedBy: [String]

    public init(tools: ToolCapabilities, route: RoutePolicy, deniedBy: [String]) {
        self.tools = tools
        self.route = route
        self.deniedBy = deniedBy
    }
}

/// Pure intersection over the five SPEC §10.1 layers. `invocationMask` is
/// the already-folded CLI mask (`.allAllowed` when no flag was passed);
/// argv conflicts are detected on the raw tokens by `checkCLIDirectives`
/// before folding, never here.
public func effectiveCapabilities(
    build: ToolCapabilities,
    userConfig: ToolCapabilities,
    workspaceGrant: ToolCapabilities,
    invocationMask: ToolCapabilities,
    sealed sealedRestrictions: SealedRestrictions
) -> EffectiveCapabilities {
    let layers: [(String, ToolCapabilities)] = [
        ("build", build), ("userConfig", userConfig),
        ("workspaceGrant", workspaceGrant), ("invocationMask", invocationMask),
    ]
    let tools = (sealedRestrictions.sealed ? ToolCapabilities.allDenied : build
        .intersected(with: userConfig)
        .intersected(with: workspaceGrant)
        .intersected(with: invocationMask))
    // Diagnostics: every layer holding a denial is named, without secrets.
    var deniedBy: [String] = []
    for (name, layer) in layers where layer.holdsAnyDenial {
        deniedBy.append(name)
    }
    if sealedRestrictions.sealed {
        deniedBy.append("sealed")
    }
    return EffectiveCapabilities(tools: tools, route: .localOnly, deniedBy: deniedBy.sorted())
}

private extension ToolCapabilities {
    /// True when this layer denies (or restricts to ask) at least one tool.
    var holdsAnyDenial: Bool {
        !read || !search || !edit || !write || !consult || exec != .allowed
    }
}

/// CLI directive check over the ORDERED raw argv tokens (D4: detection runs
/// before folding, so `--tools none --tools read` cannot collapse into a
/// silent last-wins mask). Config values never participate: narrowing is
/// always allowed here. Returns the sealed bit and the folded mask (`nil`
/// when no `--tools` directive was passed).
public struct CLIToolsDecision: Sendable, Equatable {
    public let sealed: Bool
    public let mask: ToolCapabilities?

    public init(sealed: Bool, mask: ToolCapabilities?) {
        self.sealed = sealed
        self.mask = mask
    }
}

public func checkCLIDirectives(sealedCount: Int, toolsValues: [String]) throws -> CLIToolsDecision {
    let knownTools = ["none", "read", "search", "edit", "write", "exec", "consult"]
    for value in toolsValues where !knownTools.contains(value) {
        throw ConfigError(
            path: "$.cli.--tools", kind: .unsupportedCombination,
            message: "unknown --tools value '\(terminalSafe(value))'.",
            hint: "use one of: \(knownTools.joined(separator: ", ")). Repeat a value to confirm it; differing values reject.")
    }
    let distinct = Set(toolsValues)
    if distinct.count > 1 {
        throw ConfigError(
            path: "$.cli.--tools", kind: .contradictoryFlags,
            message: "conflicting --tools directives \(toolsValues).",
            hint: "pass one --tools value; later flags can never restore removed capabilities.")
    }
    let sealed = sealedCount > 0
    if sealed, let only = distinct.first, only != "none" {
        throw ConfigError(
            path: "$.cli.--sealed", kind: .contradictoryFlags,
            message: "--sealed conflicts with --tools \(only).",
            hint: "sealed requests are tool-free; drop --tools or drop --sealed.")
    }
    let mask: ToolCapabilities?
    switch distinct.first {
    case nil: mask = nil
    case "none": mask = .allDenied
    case "read": mask = ToolCapabilities(read: true, search: false, edit: false, write: false, exec: .denied, consult: false)
    case "search": mask = ToolCapabilities(read: false, search: true, edit: false, write: false, exec: .denied, consult: false)
    case "edit": mask = ToolCapabilities(read: false, search: false, edit: true, write: false, exec: .denied, consult: false)
    case "write": mask = ToolCapabilities(read: false, search: false, edit: false, write: true, exec: .denied, consult: false)
    case "exec": mask = ToolCapabilities(read: false, search: false, edit: false, write: false, exec: .allowed, consult: false)
    case "consult": mask = ToolCapabilities(read: false, search: false, edit: false, write: false, exec: .denied, consult: true)
    default: mask = nil
    }
    return CLIToolsDecision(sealed: sealed, mask: mask)
}
