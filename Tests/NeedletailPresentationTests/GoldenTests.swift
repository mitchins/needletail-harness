import Testing
import Foundation
import Crypto
import NeedletailPresentation
import NeedletailCore

/// DX-07 — golden semantic frames + reviewed manifest. The manifest pins
/// every golden file by sha256 at a reviewed revision: an implementation
/// change to goldens without a manifest update FAILS (forces an explicit
/// reviewed diff). Manifest updates themselves are reviewer-checked ritual.

struct GoldenLine: Decodable, Sendable {
    var id: String
    var runs: [GoldenRun]
}

struct GoldenRun: Decodable, Sendable {
    var text: String
    var role: String
}

struct GoldenFrame: Decodable, Sendable {
    var width: Int
    var lines: [GoldenLine]
}

struct ManifestEntry: Decodable, Sendable {
    var path: String
    var sha256: String
}

struct GoldenManifest: Decodable, Sendable {
    var reviewed_rev: String
    var files: [ManifestEntry]
}

enum GoldenFixtures {
    static func root() -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("Tests/Fixtures/render").path
    }

    static func load(_ name: String) throws -> Data {
        let path = root() + "/" + name
        guard let data = FileManager.default.contents(atPath: path) else {
            throw GoldenError.missing(path)
        }
        return data
    }

    static func scenario() -> RenderFrame {
        var state = UIState()
        state.suggestion = MentionSuggestionState(query: "src/", revision: 5, candidates: [])
        (state, _) = reduce(state, .session(.admitted(commandID: CommandID("q-1"), revision: 1)))
        (state, _) = reduce(state, .session(.agent(alias: "local-coder", locality: "local", phase: "requesting")))
        (state, _) = reduce(state, .completion(CompletionResult(
            queryRevision: 5, candidates: [CandidateFile(path: "src/main.swift")])))
        return render(state, width: 80, capabilities: TerminalCapabilities())
    }
}

enum GoldenError: Error {
    case missing(String)
    case mismatch(String)
}

struct GoldenTests {

    @Test("DX-07 golden manifest matches fixture bytes")
    func DX_07_manifestMatches() throws {
        let manifest = try JSONDecoder().decode(
            GoldenManifest.self, from: GoldenFixtures.load("manifest.json"))
        #expect(!manifest.reviewed_rev.isEmpty, "manifest names its reviewed revision")
        for entry in manifest.files {
            let bytes = try GoldenFixtures.load(entry.path)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            #expect(digest == entry.sha256, "\(entry.path) changed without a manifest update — cut an explicit reviewed diff")
        }
    }

    @Test("DX-07 scripted scenario renders the golden frames")
    func DX_07_goldenFramesMatch() throws {
        let golden = try JSONDecoder().decode(
            GoldenFrame.self, from: GoldenFixtures.load("basic-chat.json"))
        let frame = GoldenFixtures.scenario()
        #expect(frame.width == golden.width)
        #expect(frame.lines.count == golden.lines.count,
                "line count: \(frame.lines.map(\.id)) vs \(golden.lines.map(\.id))")
        for (actual, expected) in zip(frame.lines, golden.lines) {
            #expect(actual.id == expected.id, "line id: \(actual.id) vs \(expected.id)")
            #expect(actual.runs.map(\.text) == expected.runs.map(\.text), "text for \(expected.id)")
            #expect(actual.runs.map(\.role.rawValue) == expected.runs.map(\.role),
                    "roles for \(expected.id)")
        }
    }
}
