import ArgumentParser
import Foundation
import NeedletailCore
import NeedletailRuntime
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// `needletail diff` (B5 TOOL-10): OPERATOR-side read command. NOT a model
/// capability (no `ToolCapabilities` bit; model-invoked `diff` is denied
/// at dispatch validation). Shows the uncommitted working-tree diff of the
/// repository containing `--workspace` (default: cwd) using an absolutely
/// pinned, fully qualified git with a fixed argv and a scrubbed
/// environment (LANG + TZ only). Stdout carries bounded pure git bytes
/// (byte-exact, pipeable); human notes go to stderr. `--output` publishes
/// the bounded bytes to a 0600 create-new file (never overwrites).
///
/// Exit codes: 0 success (truncation noted, not fatal); 2 usage
/// (bad flags, non-directory/symlink workspace, relative --git);
/// 4 operational (missing/unusable git, not-a-repo, git failure or
/// timeout, unwritable/existing output).
struct DiffCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Show the uncommitted working-tree diff (operator read command; not a model tool).")

    @Option(name: .long, help: "Workspace directory (must exist, be a real directory, not a symlink). Defaults to the current directory.")
    var workspace: String?

    @Option(name: .long, help: "Absolute path to the git executable. Defaults to PATH lookup; the resolved binary is fully qualified before use.")
    var git: String?

    @Option(name: .long, help: "Write the bounded diff bytes to FILE (created new, 0600; never overwritten).")
    var output: String?

    mutating func run() throws {
        let wsURL: URL
        if let workspace {
            guard !workspace.isEmpty else {
                eprint("usage: needletail diff [--workspace DIR] [--git PATH] [--output FILE]")
                throw ExitCode(2)
            }
            wsURL = URL(fileURLWithPath: workspace)
        } else {
            wsURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        // Existence/dir/symlink gate (RunCommand pattern): a single
        // O_DIRECTORY|O_NOFOLLOW open rejects missing paths, non-dirs
        // and symlinks alike. Never hand a hostile path to the runner.
        if wsURL.path.utf8.contains(0) {
            eprint("diff error: --workspace contains NUL")
            throw ExitCode(2)
        }
        let wsFD = wsURL.path.withCString { cstr in open(cstr, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard wsFD >= 0 else {
            eprint("diff error: --workspace must exist and be a directory (not symlink): \(terminalSafe(wsURL.path))")
            throw ExitCode(2)
        }
        close(wsFD)

        let gitPath: String?
        do {
            gitPath = try Self.resolveGit(explicit: git)
        } catch let code as ExitCode {
            throw code
        }
        let out: GitDiff.Output
        do {
            out = try GitDiff.run(workspace: wsURL, gitPath: gitPath)
        } catch let failure as GitDiff.Failure {
            switch failure {
            case .missingGit(let why):
                eprint("diff unavailable: \(terminalSafe(why))")
                throw ExitCode(4)
            case .denied(let why):
                eprint("diff error: \(terminalSafe(why))")
                throw ExitCode(4)
            case .failed(let why):
                eprint("diff error: \(terminalSafe(why))")
                throw ExitCode(4)
            case .timedOut:
                eprint("diff error: git timed out")
                throw ExitCode(4)
            }
        }
        if let output {
            do {
                try GitDiff.writeOutput(out.stdout, toFileAtPath: output)
            } catch let failure as GitDiff.Failure {
                if case .failed(let why) = failure {
                    eprint("diff error: \(terminalSafe(why))")
                } else {
                    eprint("diff error: cannot write output: \(terminalSafe(output))")
                }
                throw ExitCode(4)
            }
        }
        FileHandle.standardOutput.write(out.stdout)
        if out.truncated {
            let total = "at least \(out.stdout.count) bytes"
            if let output {
                eprint("needletail: diff truncated at \(total); full bounded output in \(terminalSafe(output))")
            } else {
                eprint("needletail: diff truncated at \(total); re-run with --output FILE to capture it")
            }
        } else if out.stdout.isEmpty {
            eprint("needletail: no uncommitted changes")
        }
    }

    /// Resolve the git pin: explicit --git (must be absolute; shape errors
    /// are usage errors) or operator-PATH lookup (operator-controlled
    /// discovery; the resolved binary is fully qualified before use).
    /// Absent/unexecutable resolution is a typed unavailable, not silent.
    static func resolveGit(explicit: String?) throws -> String? {
        if let explicit {
            guard explicit.hasPrefix("/") else {
                eprint("diff error: --git must be an absolute path")
                throw ExitCode(2)
            }
            return explicit
        }
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathEnv.split(separator: ":") {
            let candidate = (dir as NSString).appendingPathComponent("git")
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
