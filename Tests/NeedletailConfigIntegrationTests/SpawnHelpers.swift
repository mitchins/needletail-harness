import Testing
import Subprocess
import SystemPackage
import Foundation

/// Spawn seam for M1-A integration variants: the tests drive the **built**
/// `needletail` binary (product of `swift build`, located via
/// `NEEDLETAIL_BIN` or derived from the source tree) over the production
/// `swift-subprocess` API. No mocks, no network; temp files only.
enum SpawnHelpers {
    static func repositoryRoot() -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.path
    }

    static func binary() throws -> String {
        if let env = ProcessInfo.processInfo.environment["NEEDLETAIL_BIN"],
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        let fallback = repositoryRoot() + "/.build/debug/needletail"
        guard FileManager.default.isExecutableFile(atPath: fallback) else {
            throw SpawnError.missingBinary(fallback)
        }
        return fallback
    }

    /// Runs the binary; returns (exitCode, stdout, stderr). Non-zero exits
    /// are normal results, never thrown — callers assert exact codes.
    static func run(_ args: [String], environment: Environment? = nil) async throws -> (Int32, String, String) {
        let bin = try binary()
        let result = try await Subprocess.run(
            .path(FilePath(bin)),
            arguments: Arguments(args),
            environment: environment ?? .inherit,
            output: .string(limit: 1 << 20),
            error: .string(limit: 1 << 20)
        )
        let code: Int32
        switch result.terminationStatus {
        case .exited(let c): code = c
        case .signaled(let c): code = 128 + c
        }
        return (code, result.standardOutput, result.standardError)
    }

    static func writeTempFile(named name: String, contents: Data) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("needletail-m1a-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url)
        return url.path
    }

    static func assertNoCanary(_ text: String, canary: String, where label: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!text.contains(canary), "\(label) leaks the secret canary", sourceLocation: sourceLocation)
    }
}

enum SpawnError: Error {
    case missingBinary(String)
}
