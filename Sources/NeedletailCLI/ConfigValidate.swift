import ArgumentParser
import Foundation
import NeedletailCore

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

    mutating func run() throws {
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
            data = try readBoundedConfigFile(path)
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
            eprint("error $: malformedJSON — \(error). Fix: validate the file as strict JSON first.")
            throw ExitCode(2)
        }
        print(renderSummary(snapshot))
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

/// Bounded file read shared by `config validate` and `doctor --probe`:
/// refuses directories, reads at most `limit + 1` bytes, and fails closed
/// with `fileTooLarge` instead of allocating an unbounded file.
func readBoundedConfigFile(_ path: String, limit: Int = ConfigLimits.maxFileBytes) throws -> Data {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
        throw ConfigError(
            path: "$", kind: .configNotFound,
            message: "configuration file '\(path)' does not exist.",
            hint: "pass an existing --config PATH.")
    }
    guard !isDirectory.boolValue else {
        throw ConfigError(
            path: "$", kind: .unsupportedFormat,
            message: "'\(path)' is a directory, not a configuration file.",
            hint: "point --config at a versioned JSON file.")
    }
    guard let handle = FileHandle(forReadingAtPath: path) else {
        throw ConfigError(
            path: "$", kind: .configNotFound,
            message: "configuration file '\(path)' cannot be opened.",
            hint: "check permissions and pass a readable --config PATH.")
    }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: limit + 1) else {
        throw ConfigError(
            path: "$", kind: .malformedJSON,
            message: "configuration file '\(path)' cannot be read.",
            hint: "check the file is a readable regular file.")
    }
    let bytes = data ?? Data()
    guard bytes.count <= limit else {
        throw ConfigError(
            path: "$", kind: .fileTooLarge,
            message: "configuration exceeds \(limit) bytes.",
            hint: "split native options out or shrink the file; files are rejected before decoding.")
    }
    return bytes
}

/// Redacted one-line-per-fact summary. Origins and references only.
func renderSummary(_ snapshot: ConfigSnapshot) -> String {
    var lines = [
        "needletail config OK",
        "version: \(snapshot.version)",
        "default_model: \(snapshot.defaultAlias)",
        "models: \(snapshot.profiles.count)",
    ]
    for alias in snapshot.profiles.keys.sorted() {
        let profile = snapshot.profiles[alias]!
        lines.append(
            "profile \(profile.alias) \(profile.wireProtocol.rawValue) \(profile.origin) \(profile.locality.rawValue)"
                + " model \(profile.modelID) ctx \(profile.contextWindow) out \(profile.maxOutput)"
                + " credential \(profile.credential?.redactedDescription ?? "none")"
                + " unqualified:\(profile.unqualifiedOptions.count)")
    }
    lines.append("tools-configured: \(renderTools(snapshot.tools))")
    let effective = effectiveCapabilities(
        build: .allAllowed, userConfig: snapshot.tools,
        workspaceGrant: .allDenied, invocationMask: .allAllowed,
        sealed: SealedRestrictions(sealed: false))
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
