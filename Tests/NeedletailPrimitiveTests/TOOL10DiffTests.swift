import Testing
import Foundation
import Dispatch
import NeedletailCore
import NeedletailTestSupport
@testable import NeedletailRuntime
import SystemPackage
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// TOOL-10: operator-side `needletail diff`. Native legs exercise the
/// GitDiff core directly (repo fixtures, driver neutralization, missing
/// git, large/binary output, dirty trees); binary legs spawn the real
/// `needletail diff` CLI (poisoned env, missing git, bad workspace,
/// truncation notes, driver neutralization through the binary).
struct TOOL10DiffTests {

    // MARK: - Fixtures

    private static func tempDir(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    private static func locateGit() -> String? {
        for candidate in ["/usr/bin/git", "/bin/git", "/usr/local/bin/git"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func runGit(_ git: String, args: [String], cwd: URL, env: [String: String]? = nil) throws -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = args
        p.currentDirectoryURL = cwd
        // Fixture hermeticity: inherited GIT_* variables (GIT_DIR,
        // GIT_WORK_TREE, GIT_COMMON_DIR, ...) would redirect these fixture
        // commands at the caller's repository instead of the temp
        // fixture, so every inherited GIT_* entry is stripped before
        // test overrides apply. (The B5-C binary legs poison GIT_* deliberately
        // through their own env parameter — that path is the behavior
        // under test, and unaffected by this scrub.)
        var e = ProcessInfo.processInfo.environment
        for key in e.keys.filter({ $0.hasPrefix("GIT_") }) {
            e.removeValue(forKey: key)
        }
        if let env {
            for (k, v) in env { e[k] = v }
        }
        p.environment = e
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        p.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, out, err)
    }

    private static func makeRepo(files: [String: String] = ["f.txt": "hello\n"]) throws -> (URL, String) {
        let git = try #require(Self.locateGit(), "git required for TOOL-10 evidence; silent skip is not evidence")
        let dir = try Self.tempDir(prefix: "tool10-repo")
        _ = try Self.runGit(git, args: ["init", "-q"], cwd: dir)
        _ = try Self.runGit(git, args: ["config", "user.email", "t@t"], cwd: dir)
        _ = try Self.runGit(git, args: ["config", "user.name", "t"], cwd: dir)
        for (name, content) in files {
            try content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        _ = try Self.runGit(git, args: ["add", "-A"], cwd: dir)
        _ = try Self.runGit(git, args: ["commit", "-qm", "init"], cwd: dir)
        return (dir, git)
    }

    // MARK: - Contract pins (argv, env)

    @Test("TOOL_10_argvPinned")
    func argvPinned() {
        #expect(GitDiff.fixedArgv == ["--no-pager", "--no-optional-locks", "-c", "core.fsmonitor=false", "diff", "--no-color", "--no-ext-diff", "--no-textconv"])
        for flag in ["--no-color", "--no-ext-diff", "--no-textconv", "--no-pager", "--no-optional-locks"] {
            #expect(GitDiff.fixedArgv.contains(flag), "contract flag missing: \(flag)")
        }
        #expect(GitDiff.fixedArgv.contains("core.fsmonitor=false"), "fsmonitor override pinned: repo config must not execute hooks")
    }

    @Test("TOOL_10_fsmonitorNeutralized")
    func fsmonitorNeutralized() throws {
        let (dir, git) = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Repo-configured fsmonitor hook that would execute during diff.
        let marker = dir.appendingPathComponent("fsmonitor-fired").path
        _ = try Self.runGit(git, args: ["config", "core.fsmonitor", "touch \(marker)"], cwd: dir)
        try "changed\n".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let out = try GitDiff.run(workspace: dir, gitPath: git)
        let text = String(data: out.stdout, encoding: .utf8) ?? ""
        #expect(!FileManager.default.fileExists(atPath: marker), "fsmonitor hook must not execute")
        #expect(text.contains("+changed"), "normal diff still produced, got \(text)")
        // Sensitivity: raw git without our -c override fires the hook.
        _ = try Self.runGit(git, args: ["diff"], cwd: dir)
        #expect(FileManager.default.fileExists(atPath: marker), "sensitivity: unsanitized git honors core.fsmonitor")
    }

    @Test("TOOL_10_sanitizedEnvExact")
    func sanitizedEnvExact() {
        #expect(Set(GitDiff.sanitizedEnv.keys) == ["LANG", "TZ"], "allowlist is LANG+TZ only, got \(GitDiff.sanitizedEnv)")
        for poison in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_EXTERNAL_DIFF", "GIT_CONFIG_PARAMETERS", "PATH", "HOME", "RIPGREP_CONFIG_PATH"] {
            #expect(GitDiff.sanitizedEnv[poison] == nil, "\(poison) must be scrubbed")
        }
    }

    // MARK: - Native legs

    @Test("TOOL_10_cleanTreeEmpty")
    func cleanTreeEmpty() throws {
        let (dir, git) = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try GitDiff.run(workspace: dir, gitPath: git)
        #expect(out.stdout.isEmpty, "clean tree diffs empty")
        #expect(!out.truncated)
    }

    @Test("TOOL_10_dirtyWorktreeShowsUnstaged")
    func dirtyWorktree() throws {
        let (dir, git) = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "hello world\n".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let out = try GitDiff.run(workspace: dir, gitPath: git)
        let text = String(data: out.stdout, encoding: .utf8) ?? ""
        #expect(text.contains("diff --git a/f.txt b/f.txt"), "diff header present, got \(text)")
        #expect(text.contains("-hello") && text.contains("+hello world"), "unstaged hunk present")
        #expect(!out.truncated)
    }

    @Test("TOOL_10_diffExternalNeutralized")
    func diffExternalNeutralized() throws {
        let (dir, git) = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Repo-local external driver that would hijack the diff if honored.
        let marker = dir.appendingPathComponent("external-fired").path
        let driver = dir.appendingPathComponent("ext.sh")
        try "#!/bin/sh\ntouch \(marker)\nexit 0\n".write(to: driver, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: driver.path)
        _ = try Self.runGit(git, args: ["config", "diff.external", driver.path], cwd: dir)
        try "changed\n".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let out = try GitDiff.run(workspace: dir, gitPath: git)
        let text = String(data: out.stdout, encoding: .utf8) ?? ""
        #expect(!FileManager.default.fileExists(atPath: marker), "external driver must not run")
        #expect(text.contains("+changed"), "normal diff still produced, got \(text)")
        // Sensitivity: raw git without our argv fires the driver.
        let raw = try Self.runGit(git, args: ["diff"], cwd: dir)
        #expect(FileManager.default.fileExists(atPath: marker) || raw.out.isEmpty, "sensitivity: unsanitized git honors diff.external")
    }

    @Test("TOOL_10_textconvNeutralized")
    func textconvNeutralized() throws {
        let (dir, git) = try Self.makeRepo(files: ["f.txt": "hello\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        // Textconv driver that would rewrite a binary file's diff if honored.
        // (The blob arrives as $1; output must depend on it or old and new
        // convert identically and there is no diff at all.)
        let conv = dir.appendingPathComponent("conv.sh")
        try "#!/bin/sh\nprintf 'CONVERTED\\n'\nwc -c < \"$1\"\n".write(to: conv, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: conv.path)
        _ = try Self.runGit(git, args: ["config", "diff.foo.textconv", conv.path], cwd: dir)
        try "x\n*.foo diff=foo\n".write(to: dir.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try Data([0x00, 0x01, 0x02, 0xFF, 0xFE]).write(to: dir.appendingPathComponent("b.foo"))
        _ = try Self.runGit(git, args: ["add", "-A"], cwd: dir)
        _ = try Self.runGit(git, args: ["commit", "-qm", "bin"], cwd: dir)
        try Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0x03]).write(to: dir.appendingPathComponent("b.foo"))
        let out = try GitDiff.run(workspace: dir, gitPath: git)
        let text = String(data: out.stdout, encoding: .utf8) ?? ""
        #expect(!text.contains("CONVERTED"), "textconv driver must not run, got \(text)")
        #expect(text.contains("Binary"), "binary diff reported raw, got \(text)")
        // Sensitivity: raw git without --no-textconv runs the driver.
        let raw = try Self.runGit(git, args: ["diff"], cwd: dir)
        #expect(raw.out.contains("CONVERTED"), "sensitivity: unsanitized git runs textconv")
    }

    @Test("TOOL_10_missingGit")
    func missingGit() throws {
        let dir = try Self.tempDir(prefix: "tool10-nogit")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: GitDiff.Failure.missingGit("git is not provisioned (pass --git ABSOLUTE-PATH)")) {
            try GitDiff.run(workspace: dir, gitPath: nil)
        }
        #expect(throws: GitDiff.Failure.missingGit("git not found at /definitely/absent/git")) {
            try GitDiff.run(workspace: dir, gitPath: "/definitely/absent/git")
        }
        #expect(throws: GitDiff.Failure.self) {
            try GitDiff.run(workspace: dir, gitPath: "relative/git")
        }
    }

    @Test("TOOL_10_untrustedGitDenied")
    func untrustedGitDenied() throws {
        let dir = try Self.tempDir(prefix: "tool10-untrusted")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Symlink pin.
        let link = dir.appendingPathComponent("git-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/usr/bin/git")
        #expect(throws: GitDiff.Failure.denied("git is a symlink")) {
            try GitDiff.run(workspace: dir, gitPath: link.path)
        }
        // Non-executable regular file.
        let plain = dir.appendingPathComponent("git-plain")
        try "not git".write(to: plain, atomically: true, encoding: .utf8)
        #expect(throws: GitDiff.Failure.self) {
            try GitDiff.run(workspace: dir, gitPath: plain.path)
        }
        // World-writable copy of the real git.
        guard let real = Self.locateGit() else { throw TOOL10Error.noGit }
        let copy = dir.appendingPathComponent("git-copy")
        try FileManager.default.copyItem(atPath: real, toPath: copy.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: copy.path)
        #expect(throws: GitDiff.Failure.denied("git is world-writable")) {
            try GitDiff.run(workspace: dir, gitPath: copy.path)
        }
    }

    enum TOOL10Error: Error { case noGit, missingBinary }

    @Test("TOOL_10_largeOutputTruncated")
    func largeOutputTruncated() throws {
        let (dir, git) = try Self.makeRepo(files: ["big.txt": String(repeating: "a\n", count: 10)])
        defer { try? FileManager.default.removeItem(at: dir) }
        // Rewrite with ~2 MiB of changed lines.
        let big = String(repeating: "abcdefghijklmnopqrstuvwxyz0123456789\n", count: 60_000)
        try big.write(to: dir.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        let out = try GitDiff.run(workspace: dir, gitPath: git)
        #expect(out.truncated, "oversized output must truncate")
        #expect(out.stdout.count == GitDiff.maxStdoutBytes, "bounded exactly at the cap, got \(out.stdout.count)")
        #expect(!out.stdout.isEmpty)
    }

    @Test("TOOL_10_binaryDiffSafe")
    func binaryDiffSafe() throws {
        let (dir, git) = try Self.makeRepo(files: ["f.txt": "hello\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([0x00, 0x01, 0x02]).write(to: dir.appendingPathComponent("b.bin"))
        _ = try Self.runGit(git, args: ["add", "-A"], cwd: dir)
        _ = try Self.runGit(git, args: ["commit", "-qm", "bin"], cwd: dir)
        try Data([0x00, 0x01, 0x03]).write(to: dir.appendingPathComponent("b.bin"))
        let out = try GitDiff.run(workspace: dir, gitPath: git)
        #expect(!out.stdout.contains(0x00), "no NUL bytes in bounded diff output")
        let text = String(data: out.stdout, encoding: .utf8) ?? ""
        #expect(text.contains("Binary"), "binary diff reported, got \(text)")
    }

    @Test("TOOL_10_writeOutputDiscipline")
    func writeOutputDiscipline() throws {
        let dir = try Self.tempDir(prefix: "tool10-out")
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("d.diff").path
        let bytes = Data("diff --git a/f b/f\n".utf8)
        try GitDiff.writeOutput(bytes, toFileAtPath: target)
        #expect(try Data(contentsOf: URL(fileURLWithPath: target)) == bytes, "byte-exact artifact")
        let mode = try FileManager.default.attributesOfItem(atPath: target)[.posixPermissions] as? Int
        #expect(mode == 0o600, "private 0600, got \(String(format: "%o", mode ?? 0))")
        #expect(throws: GitDiff.Failure.self) {
            try GitDiff.writeOutput(Data("x".utf8), toFileAtPath: target)
        }
        // Symlink target refused (never follows).
        let link = dir.appendingPathComponent("link.diff")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        #expect(throws: GitDiff.Failure.self) {
            try GitDiff.writeOutput(bytes, toFileAtPath: link.path)
        }
    }

    @Test("TOOL_10_notARepo")
    func notARepo() throws {
        let git = try #require(Self.locateGit())
        let dir = try Self.tempDir(prefix: "tool10-norepo")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: GitDiff.Failure.self) {
            try GitDiff.run(workspace: dir, gitPath: git)
        }
    }

    @Test("TOOL_10_modelDiffDenied")
    func modelDiffDenied() throws {
        // `diff` is not a model tool: no capability bit exists (compile-time
        // shape: ToolCapabilities has no diff member) and dispatch rejects
        // it before any side effect.
        #expect(throws: ToolFailure.preDispatch(status: "invalid-arguments", summary: "unknown tool diff")) {
            try ToolValidator.validateBatchArguments(batch: ToolBatch([
                ToolProposal(callID: "c1", tool: "diff", argumentsDigest: "d", arguments: "{\"path\":\"f\"}"),
            ]))
        }
        #expect(!ToolAdvertisement.names(for: .allAllowed).contains("diff"), "diff never advertised even with full caps")
    }

    // MARK: - Binary legs (real needletail CLI)

    private static func binary() throws -> URL {
        // NEEDLETAIL_BIN wins when set AND executable; otherwise resolve
        // the product beside THIS test runner (built fresh from the same
        // revision, whatever the build dir is); the legacy .build/debug
        // path remains for hand-invoked runs. A missing binary fails
        // loudly as missingBinary, never as noGit (which means "no
        // system git", a different precondition).
        if let env = ProcessInfo.processInfo.environment["NEEDLETAIL_BIN"],
           FileManager.default.isExecutableFile(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        var runner = URL(fileURLWithPath: CommandLine.arguments[0])
        if !runner.path.hasPrefix("/") {
            runner = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(CommandLine.arguments[0])
        }
        let sibling = runner.deletingLastPathComponent().appendingPathComponent("needletail")
        if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        let built = URL(fileURLWithPath: "/data/coding/needletail/.build/debug/needletail")
        if FileManager.default.isExecutableFile(atPath: built.path) { return built }
        Issue.record("needletail binary missing; build the product before diff binary legs")
        throw TOOL10Error.missingBinary
    }

    private static func run(_ bin: URL, args: [String], cwd: URL, env: [String: String]? = nil) throws -> (Int32, String, String) {
        // Concurrent pipe drain: outputs can exceed the 64 KiB pipe buffer
        // (truncation tests emit megabytes); reading only after wait would
        // deadlock the child on a full pipe.
        final class DataBox: @unchecked Sendable { var data = Data() }
        let p = Process()
        p.executableURL = bin
        p.arguments = args
        p.currentDirectoryURL = cwd
        if let env {
            // Explicit caller entries win (including a deliberate PATH
            // override such as the empty-PATH test); everything else is
            // hermetic (FINAL-02 B: never inherit a poisoned runner PATH).
            var e = hermeticChildEnvironment(ProcessInfo.processInfo.environment)
            for (k, v) in env { e[k] = v }
            p.environment = e
        } else {
            p.environment = hermeticChildEnvironment(ProcessInfo.processInfo.environment)
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        p.waitUntilExit()
        group.wait()
        let out = String(data: outBox.data, encoding: .utf8) ?? ""
        let err = String(data: errBox.data, encoding: .utf8) ?? ""
        return (p.terminationStatus, out, err)
    }

    @Test("TOOL_10_binaryCleanAndDirty")
    func binaryCleanAndDirty() throws {
        let bin = try Self.binary()
        let (dir, _) = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        var (code, out, err) = try Self.run(bin, args: ["diff", "--workspace", dir.path], cwd: dir)
        #expect(code == 0, "clean tree exits 0, got \(code) err=\(err)")
        #expect(out.isEmpty, "clean tree prints no diff")
        #expect(err.contains("no uncommitted changes"), "clean note on stderr, got \(err)")
        try "hello world\n".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let target = dir.appendingPathComponent("d.diff").path
        (code, out, err) = try Self.run(bin, args: ["diff", "--workspace", dir.path, "--output", target], cwd: dir)
        #expect(code == 0, "dirty tree exits 0, got \(code) err=\(err)")
        #expect(out.contains("+hello world"), "stdout carries the diff, got \(out)")
        #expect(try String(contentsOfFile: target, encoding: .utf8) == out, "--output is byte-exact with stdout")
        let mode = try FileManager.default.attributesOfItem(atPath: target)[.posixPermissions] as? Int
        #expect(mode == 0o600, "output is 0600, got \(String(format: "%o", mode ?? 0))")
    }

    @Test("TOOL_10_binaryPoisonedEnv")
    func binaryPoisonedEnv() throws {
        let bin = try Self.binary()
        let (dir, git) = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "poison\n".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        var poison: [String: String] = [
            "GIT_DIR": "/nonexistent",
            "GIT_WORK_TREE": "/nonexistent",
            "GIT_INDEX_FILE": "/nonexistent",
            "GIT_OBJECT_DIRECTORY": "/nonexistent",
            "GIT_CONFIG_PARAMETERS": "'core.pager=evil'",
        ]
        let marker = dir.appendingPathComponent("poison-marker").path
        try "#!/bin/sh\ntouch \(marker)\n".write(to: dir.appendingPathComponent("marker.sh"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("marker.sh").path)
        poison["GIT_EXTERNAL_DIFF"] = dir.appendingPathComponent("marker.sh").path
        let (code, out, err) = try Self.run(bin, args: ["diff", "--workspace", dir.path], cwd: dir, env: poison)
        #expect(code == 0, "poisoned env still succeeds, got \(code) err=\(err)")
        #expect(out.contains("+poison"), "correct diff despite poisons, got \(out)")
        #expect(!FileManager.default.fileExists(atPath: marker), "external driver never ran")
        // Sensitivity: raw git with the same poisons fails loudly.
        let raw = try Self.runGit(git, args: ["diff"], cwd: dir, env: poison)
        #expect(raw.status != 0, "sensitivity: unsanitized git breaks under the poisons (status \(raw.status))")
    }

    @Test("TOOL_10_binaryMissingGit")
    func binaryMissingGit() throws {
        let bin = try Self.binary()
        let (dir, _) = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Empty PATH + no --git: unavailable, not silent, not a crash.
        let (code, _, err) = try Self.run(bin, args: ["diff", "--workspace", dir.path], cwd: dir, env: ["PATH": ""])
        #expect(code == 4, "missing git exits 4, got \(code)")
        #expect(err.lowercased().contains("git"), "message explains git is unavailable, got \(err)")
        // Explicit absent pin: same denial.
        let (code2, _, err2) = try Self.run(bin, args: ["diff", "--workspace", dir.path, "--git", "/definitely/absent/git"], cwd: dir)
        #expect(code2 == 4, "absent pin exits 4, got \(code2)")
        #expect(err2.lowercased().contains("git"), "got \(err2)")
        // Relative --git is a usage error.
        let (code3, _, _) = try Self.run(bin, args: ["diff", "--workspace", dir.path, "--git", "relative/git"], cwd: dir)
        #expect(code3 == 2, "relative --git exits 2, got \(code3)")
    }

    @Test("TOOL_10_binaryBadWorkspace")
    func binaryBadWorkspace() throws {
        let bin = try Self.binary()
        let (dir, _) = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (code, _, _) = try Self.run(bin, args: ["diff", "--workspace", "/definitely/absent/ws"], cwd: dir)
        #expect(code == 2, "absent workspace exits 2, got \(code)")
        let link = dir.appendingPathComponent("ws-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: dir.path)
        let (code2, _, err2) = try Self.run(bin, args: ["diff", "--workspace", link.path], cwd: dir)
        #expect(code2 == 2, "symlink workspace exits 2, got \(code2) err=\(err2)")
    }

    @Test("TOOL_10_binaryNonGitToolsUnaffected")
    func binaryNonGitToolsUnaffected() throws {
        // With git removed from PATH, non-git commands are unaffected.
        let bin = try Self.binary()
        let (dir, _) = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (helpCode, helpOut, _) = try Self.run(bin, args: ["--help"], cwd: dir, env: ["PATH": ""])
        #expect(helpCode == 0, "help works without git on PATH, got \(helpCode)")
        #expect(helpOut.contains("diff"), "diff stays listed")
    }

    @Test("TOOL_10_binaryTruncationNote")
    func binaryTruncationNote() throws {
        let bin = try Self.binary()
        let (dir, _) = try Self.makeRepo(files: ["big.txt": "x\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try String(repeating: "0123456789abcdef\n", count: 80_000).write(to: dir.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        let (code, out, err) = try Self.run(bin, args: ["diff", "--workspace", dir.path], cwd: dir)
        #expect(code == 0, "truncation is not fatal, got \(code)")
        #expect(err.contains("truncated"), "truncation noted on stderr, got \(err)")
        #expect(err.contains("--output"), "note points at --output, got \(err)")
        #expect(!out.isEmpty)
        let target = dir.appendingPathComponent("t.diff").path
        let (code2, out2, err2) = try Self.run(bin, args: ["diff", "--workspace", dir.path, "--output", target], cwd: dir)
        #expect(code2 == 0)
        #expect(err2.contains(target), "note names the artifact file, got \(err2)")
        #expect(try String(contentsOfFile: target, encoding: .utf8) == out2, "artifact is byte-exact")
    }

    @Test("TOOL_10_binaryDriversNeutralized")
    func binaryDriversNeutralized() throws {
        // diff.external + textconv through the real binary.
        let bin = try Self.binary()
        let (dir, git) = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("ext-fired").path
        let driver = dir.appendingPathComponent("ext.sh")
        try "#!/bin/sh\ntouch \(marker)\nexit 0\n".write(to: driver, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: driver.path)
        _ = try Self.runGit(git, args: ["config", "diff.external", driver.path], cwd: dir)
        try "v2\n".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let (code, out, err) = try Self.run(bin, args: ["diff", "--workspace", dir.path], cwd: dir)
        #expect(code == 0, "got \(code) err=\(err)")
        #expect(!FileManager.default.fileExists(atPath: marker), "external driver never ran through the binary")
        #expect(out.contains("+v2"), "normal diff through the binary, got \(out)")
    }
}
