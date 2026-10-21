import Testing
import Foundation

/// ARCH-import-gate (non-gate tooling; PORT-02 method precursor, NOT a case
/// claim — this test never matches a `./dev test case` filter and never
/// counts toward coverage): NeedletailCore imports no transport, storage,
/// terminal or platform implementation. Production reducers and effect
/// boundaries stay free of I/O by construction, guarded here against
/// accidental coupling.
struct ImportGateTests {
    private static let forbiddenImports = [
        "AsyncHTTPClient", "OpenAPIRuntime", "Subprocess", "SystemPackage",
        "GRDB", "Crypto", "ArgumentParser",
        "Darwin", "Glibc", "Security", "AppKit", "SwiftUI", "Combine",
        "NIOCore", "NIOHTTP1", "FoundationNetworking", "SQLite3",
        "CReplxx", "PTYShim",
    ]

    private static func coreSources() throws -> [String] {
        var testFile = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { testFile.deleteLastPathComponent() }
        let core = testFile.appendingPathComponent("Sources/NeedletailCore").path
        return try FileManager.default.contentsOfDirectory(atPath: core)
            .filter { $0.hasSuffix(".swift") }
            .map { core + "/" + $0 }
    }

    @Test("ARCH-import-gate: Core imports no transport, storage, terminal or platform implementation")
    func ARCH_importGateCoreHasNoEffectImports() throws {
        for path in try Self.coreSources() {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                let trimmedImport = trimmed.dropFirst(7).trimmingCharacters(in: .whitespaces)
                let pieces = trimmedImport.split(whereSeparator: { $0.isWhitespace })
                let module = (pieces.last { !$0.isEmpty && !["struct", "class", "enum", "actor", "protocol", "typealias", "let", "var"].contains(String($0)) }?.trimmingCharacters(in: CharacterSet(charactersIn: " \";")) ?? "")
                    .split(separator: ".").first.map(String.init) ?? ""
                #expect(!Self.forbiddenImports.contains(module),
                        "\(path): forbidden import '\(module)' — Core performs no I/O")
            }
        }
    }

    @Test("ARCH-import-gate: CLI doctor and validate paths import no HTTP client")
    func ARCH_importGateCLINoTransportImports() throws {
        var testFile = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { testFile.deleteLastPathComponent() }
        let cli = testFile.appendingPathComponent("Sources/NeedletailCLI").path
        for file in try FileManager.default.contentsOfDirectory(atPath: cli).filter({ $0.hasSuffix(".swift") }) {
            // M1-D RunCommand is the headless loop and legitimately links the
            // transport; the offline bootstrap paths (Doctor, ConfigValidate)
            // must stay offline.
            if file == "RunCommand.swift" { continue }
            let text = try String(contentsOfFile: cli + "/" + file, encoding: .utf8)
            #expect(!text.contains("import AsyncHTTPClient"),
                    "NeedletailCLI/\(file): offline bootstrap paths must not link the HTTP client")
        }
    }

    @Test("A5-1 CLI exposes no ownership-recovery surface")
    func CLINoRecoverySurface() throws {
        // RecoveryAuthorization is a scope-bound audit value, not
        // independent authentication — and no later user-facing recovery
        // command exists. The CLI composition root must never reference
        // the takeover operation: any mention here is a new user-facing
        // recovery path without a trusted operator boundary. Fail closed.
        var testFile = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { testFile.deleteLastPathComponent() }
        let cli = testFile.appendingPathComponent("Sources/NeedletailCLI").path
        for file in try FileManager.default.contentsOfDirectory(atPath: cli).filter({ $0.hasSuffix(".swift") }) {
            let text = try String(contentsOfFile: cli + "/" + file, encoding: .utf8)
            #expect(!text.contains("recoverWriterOwnership"),
                    "NeedletailCLI/\(file): CLI must not expose ownership takeover")
            #expect(!text.contains("RecoveryAuthorization"),
                    "NeedletailCLI/\(file): CLI must not reference recovery authorization")
        }
    }
}
