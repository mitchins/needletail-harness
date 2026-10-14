import Testing
import Foundation

/// PORT-02 (presentation half) + R21 construction-site gate: the
/// presentation target imports Foundation + NeedletailCore only, and no
/// file outside Core constructs `SessionEventProjection(` (Core-only
/// construction keeps the UI from minting actor-bound projections).
struct PresentationGateTests {

    private static func sourcesRoot() throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.path + "/Sources/"
    }

    @Test("PORT-02 presentation imports stay platform-free")
    func PORT_02_presentationImportGate() throws {
        let root = try Self.sourcesRoot()
        let dir = root + "NeedletailPresentation"
        let forbidden = [
            "AsyncHTTPClient", "OpenAPIRuntime", "Subprocess", "SystemPackage",
            "GRDB", "Crypto", "ArgumentParser",
            "Darwin", "Glibc", "Security", "AppKit", "SwiftUI", "Combine",
        ]
        for file in try FileManager.default.contentsOfDirectory(atPath: dir).filter({ $0.hasSuffix(".swift") }) {
            let text = try String(contentsOfFile: dir + "/" + file, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                let module = trimmed.dropFirst(7).split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                #expect(!forbidden.contains(module), "Presentation/\(file): forbidden import '\(module)'")
            }
        }
    }

    @Test("DX-03 projection construction sites stay inside Core")
    func projectionConstructionSiteGate() throws {
        // R21: SessionEventProjection has an internal init, so only Core
        // constructs it. This static check fails any future minting site
        // outside Sources/NeedletailCore/ (tests may only CONSUME).
        let root = try Self.sourcesRoot()
        let manager = FileManager.default
        var offenders: [String] = []
        for target in ["NeedletailPresentation", "NeedletailCLI", "NeedletailRuntime", "NeedletailProviders"] {
            let dir = root + target
            guard manager.fileExists(atPath: dir) else { continue }
            for file in try manager.contentsOfDirectory(atPath: dir).filter({ $0.hasSuffix(".swift") }) {
                let text = try String(contentsOfFile: dir + "/" + file, encoding: .utf8)
                if text.contains("SessionEventProjection(") {
                    offenders.append("\(target)/\(file)")
                }
            }
        }
        #expect(offenders.isEmpty, "projection minted outside Core: \(offenders)")
    }
}
