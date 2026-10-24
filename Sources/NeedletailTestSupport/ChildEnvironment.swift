import Foundation

/// FINAL-02 B fixture hermeticity for spawned CLI children.
///
/// The CLI binary resolves rg/git via inherited PATH
/// (`RunCommand.locateExecutable`), but B2ClosureTests poisons the
/// RUNNER's process-global PATH (fake-rg shadowing) and
/// RIPGREP_CONFIG_PATH while sibling suites spawn binaries in parallel.
/// Inheriting the live PATH let a poison window shadow rg for TOOL_03 on
/// CI (exit 0, in-root match missing). Temp-dir PATH entries can only be
/// test fixtures — never system tools — so strip them; system entries are
/// preserved, which keeps the transform a no-op when no poison is
/// present. Inherited RIPGREP_CONFIG_PATH/RIPGREP_CONFIG are dropped for
/// the same reason; callers that need a config (e.g. TOOL-03's evil
/// config) set it afterwards.
public func hermeticChildEnvironment(_ env: [String: String]) -> [String: String] {
    var clean = env
    let tmpPrefix = FileManager.default.temporaryDirectory.path
    let pathEntries = (clean["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init).filter {
        !$0.hasPrefix(tmpPrefix)
    }
    clean["PATH"] = pathEntries.isEmpty ? "/usr/bin:/bin" : pathEntries.joined(separator: ":")
    clean.removeValue(forKey: "RIPGREP_CONFIG_PATH")
    clean.removeValue(forKey: "RIPGREP_CONFIG")
    return clean
}
