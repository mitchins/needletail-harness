import ArgumentParser
import NeedletailCore

/// Minimal composition root at M0-A. It exists so `./dev build` links a real
/// executable and later milestones (M0-D smoke, headless JSONL) extend it.
/// No network access, no session side effects: `needletail --version` and
/// `needletail --help` are offline by construction (I01).
@main
struct NeedletailCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "needletail",
        abstract: "Needletail — minimal local-first Swift coding harness (M0 bootstrap).",
        version: NeedletailVersion(major: 0, minor: 3, patch: 0).description
    )

    mutating func run() throws {
        // M0-A: the entry point only reports the version. No subcommands are
        // implemented yet; none is claimed.
    }
}
