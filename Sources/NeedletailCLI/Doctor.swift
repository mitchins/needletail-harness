import ArgumentParser
import Foundation
import NeedletailCore

/// Offline environment inspection (M0-D). No network, no provider calls,
/// no session side effects (I01): it reports the build identity, the host
/// platform, and which external executables are available — each with the
/// exact capability its absence disables (PKG-05's machinery, early).
struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Offline local checks only; no network requests."
    )

    mutating func run() throws {
        print("needletail \(NeedletailVersion(major: 0, minor: 3, patch: 0))")
        print("platform: \(hostPlatform())")

        var exitCode: Int32 = 0
        for requirement in ExecutableRequirement.all {
            if let resolved = resolveExecutable(requirement.name) {
                print("\(requirement.name): available (\(resolved)) — enables \(requirement.enables)")
            } else {
                print("\(requirement.name): NOT FOUND — disables \(requirement.disables)")
                if requirement.fatal {
                    exitCode = 1
                }
            }
        }
        if exitCode != 0 {
            throw ExitCode(exitCode)
        }
    }

    private func hostPlatform() -> String {
        var uts = utsname()
        uname(&uts)
        let machine = withUnsafePointer(to: &uts.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        let sysname = withUnsafePointer(to: &uts.sysname) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        let release = withUnsafePointer(to: &uts.release) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        return "\(sysname) \(release) \(machine)"
    }

    /// PATH-based executable lookup. No execution, no environment
    /// inheritance of provider secrets, no spawning.
    private func resolveExecutable(_ name: String) -> String? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

/// Each external executable the harness provisions (never installs) and the
/// capability it gates (DEPENDENCIES.md: git and rg are "provisioned
/// executables, not libraries to reimplement").
private struct ExecutableRequirement {
    var name: String
    var enables: String
    var disables: String
    var fatal: Bool

    static let git = ExecutableRequirement(
        name: "git",
        enables: "git-aware diagnostics and /diff",
        disables: "git-specific features (no libgit2 fallback; not required for non-git directories)",
        fatal: false
    )
    static let rg = ExecutableRequirement(
        name: "rg",
        enables: "the native search tool",
        disables: "the search tool (denied, never a synthetic substitute)",
        fatal: false
    )
    static let all: [ExecutableRequirement] = [git, rg]
}
