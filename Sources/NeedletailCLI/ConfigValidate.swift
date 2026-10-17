import ArgumentParser
import Foundation
import NeedletailCore
import NeedletailRuntime

/// `needletail config validate` (M1-A): strict offline configuration
/// inspection. Reads at most 1 MiB + 1 byte, validates the full pipeline,
/// and prints a redacted summary (references and origins only — never
/// secret values, never `request_options` values). No network, no
/// credential resolution, no session side effects. Exit 0 valid, 2 invalid.
struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Inspect configuration files (offline, redacted).",
        subcommands: [ConfigValidate.self])
}

struct ConfigValidate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate a configuration file and show the redacted effective state.")

    @Option(name: .long, help: "Explicit configuration file path.")
    var config: String?

    // S7: real production caller for the CLI-directive checker. These flags
    // only narrow the *displayed* effective tools for inspection (the M1-A
    // workspace default stays deny-all until M2 trust); the headless
    // chat/run surface that enforces them arrives in M1-D and reuses the
    // same pure function. Conflicting directives reject here, identically.
    @Flag(name: .long, help: "Deny all tools for the inspected state (routes stay independent).")
    var sealed: Bool = false

    @Option(name: .long, help: "Restrict inspected tools to one value: none, read, search, edit, write, exec or consult. Repeat to confirm; differing values reject.")
    var tools: [String] = []

    mutating func run() throws {
        let decision: CLIToolsDecision
        do {
            decision = try checkCLIDirectives(sealedCount: sealed ? 1 : 0, toolsValues: tools)
        } catch let error as ConfigError {
            eprint("\(error)")
            throw ExitCode(2)
        }
        let path: String
        if let explicit = config {
            path = explicit
        } else if let fallback = defaultConfigPath() {
            path = fallback
        } else {
            eprint("error $: configNotFound — no configuration file found. Fix: pass --config PATH.")
            throw ExitCode(2)
        }
        let data: Data
        do {
            data = try readBoundedFile(path)
        } catch let error as ConfigError {
            eprint("\(error)")
            throw ExitCode(2)
        }
        let snapshot: ConfigSnapshot
        do {
            snapshot = try validateConfig(data)
        } catch let error as ConfigError {
            eprint("\(error)")
            throw ExitCode(2)
        } catch {
            eprint("error $: malformedJSON — \(terminalSafe(String(describing: error))). Fix: validate the file as strict JSON first.")
            throw ExitCode(2)
        }
        print(renderSummary(snapshot, decision: decision))
    }
}

/// Concurrency-safe stderr sink (Swift 6 mode forbids the shared C
/// `stderr` global). Diagnostics go to stderr on every path.
struct StandardErrorStream: TextOutputStream {
    mutating func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}

func eprint(_ text: String) {
    var stream = StandardErrorStream()
    print(text, to: &stream)
}

/// Default user configuration locations (explicit `--config` wins; repo
/// files are never consulted). Returns the first existing path, else nil.
func defaultConfigPath() -> String? {
    let environment = ProcessInfo.processInfo.environment
    if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
        let candidate = xdg + "/needletail/config.json"
        if FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
    }
    if let home = environment["HOME"], !home.isEmpty {
        let candidate = home + "/.config/needletail/config.json"
        if FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

/// Redacted one-line-per-fact summary. Origins and references only.
func renderSummary(_ snapshot: ConfigSnapshot, decision: CLIToolsDecision) -> String {
    // H2: defaultAlias is operator-supplied; render it escaped.
    var lines = [
        "needletail config OK",
        "version: \(snapshot.version)",
        "default_model: \(terminalSafe(snapshot.defaultAlias))",
        "models: \(snapshot.profiles.count)",
    ]
    for alias in snapshot.profiles.keys.sorted() {
        let profile = snapshot.profiles[alias]!
        // H2: identity fields are operator-supplied; render them escaped.
        lines.append(
            "profile \(terminalSafe(profile.alias)) \(profile.wireProtocol.rawValue) \(profile.origin) \(profile.locality.rawValue)"
                + " model \(terminalSafe(profile.modelID)) ctx \(profile.contextWindow) out \(profile.maxOutput)"
                + " credential \(profile.credential?.redactedDescription ?? "none")"
                + " unqualified:\(profile.unqualifiedOptions.count)")
    }
    lines.append("tools-configured: \(renderTools(snapshot.tools))")
    lines.append("invocation: \(renderInvocation(decision))")
    let effective = effectiveCapabilities(
        build: .allAllowed, userConfig: snapshot.tools,
        workspaceGrant: .allDenied, invocationMask: decision.mask ?? .allAllowed,
        sealed: SealedRestrictions(sealed: decision.sealed))
    if effective.tools == .allDenied {
        lines.append("tools-effective: none (workspace: default deny-all until M2 trust)")
    } else {
        lines.append("tools-effective: \(renderTools(effective.tools))")
    }
    switch selectRoute(snapshot: snapshot, requestedAlias: snapshot.defaultAlias, sealed: false) {
    case .allowed(let endpoint, _):
        lines.append("default-route: allowed \(endpoint)")
    case .denied(let denial):
        lines.append("default-route: denied (\(denial.kind)) \(denial.message)")
    }
    return lines.joined(separator: "\n")
}

/// Echo of the folded CLI directives (S7): proves the production parser
/// feeds the same pure checker the tests exercise.
func renderInvocation(_ decision: CLIToolsDecision) -> String {
    var parts: [String] = []
    if decision.sealed { parts.append("sealed") }
    if let mask = decision.mask {
        parts.append(mask == .allDenied ? "tools=none" : "tools=\(renderTools(mask))")
    }
    return parts.isEmpty ? "default" : parts.joined(separator: " ")
}

func renderTools(_ tools: ToolCapabilities) -> String {
    var parts: [String] = []
    if tools.read { parts.append("read") }
    if tools.search { parts.append("search") }
    if tools.edit { parts.append("edit") }
    if tools.write { parts.append("write") }
    parts.append("exec=\(tools.exec.rawValue)")
    if tools.consult { parts.append("consult") }
    return parts.joined(separator: " ")
}
