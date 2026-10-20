import ArgumentParser
import Foundation
import NeedletailCore
import NeedletailRuntime

/// `needletail session` namespace (A5-2): read-only session tooling.
/// Deliberately narrow — export only. No session list, fork, resume,
/// recovery or interactive commands exist here by design.
struct SessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Read-only session inspection (support diagnostics).",
        subcommands: [SessionExportCommand.self])
}

/// `needletail session export SESSION_ID --output FILE [--include-content]`
/// (A5-2 STORE-08): bounded, privacy-preserving JSONL export of one
/// session's durable records. Read-only against the production store:
/// no claim, no release, no migration, no writes of any kind.
///
/// Default output is metadata + redacted event summaries only. With
/// `--include-content`, operator/model/tool text travels verbatim and
/// the export is marked sensitive AND content-bearing — but credentials,
/// native raw provider payloads, epoch/config snapshots and recovery
/// free-text rationale never enter either mode.
struct SessionExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export one session's durable records as versioned JSONL (read-only).")

    @Argument(help: "Session ID to export (as shown by the run's session records).")
    var sessionID: String

    @Option(name: .long, help: "Output JSONL file path. Created new with private (0600) permissions; never overwritten.")
    var output: String

    @Flag(name: .long, help: "Include redacted content fields verbatim (transcript/tool text, receipts). The export is marked content-bearing; it makes no claim that user text is secret-free.")
    var includeContent: Bool = false

    mutating func run() throws {
        let stateDir: String
        do {
            stateDir = try RunCommand.resolveStateDirectory()
        } catch let code as ExitCode {
            throw code
        }
        let dbPath = (stateDir as NSString).appendingPathComponent("store.sqlite")
        let lines: [String]
        do {
            lines = try SessionExport.lines(
                dbPath: dbPath, session: SessionID(sessionID), includeContent: includeContent,
                exportedAt: UInt64(Date().timeIntervalSince1970 * 1000),
                limits: SessionExport.Limits.default)
        } catch let error as SessionExport.ExportError {
            switch error {
            case .missingStore(let path):
                eprint("export error: no durable store at \(terminalSafe(path))")
                throw ExitCode(4)
            case .unreadableStore(let detail):
                eprint("store error: cannot export: \(terminalSafe(detail))")
                throw ExitCode(6)
            case .unknownSession(let id):
                eprint("export error: session '\(terminalSafe(id))' has no records in this store")
                throw ExitCode(4)
            case .recordLimitExceeded(let limit):
                eprint("export error: session exceeds the export record bound (\(limit)); refusing to truncate")
                throw ExitCode(4)
            case .byteLimitExceeded(let limit):
                eprint("export error: session exceeds the export byte bound (\(limit)); refusing to truncate")
                throw ExitCode(4)
            case .targetExists, .outputUnwritable:
                // writeLines errors surface below; unreachable here.
                throw ExitCode(4)
            }
        }
        do {
            try SessionExport.writeLines(lines, toFileAtPath: output)
        } catch let error as SessionExport.ExportError {
            switch error {
            case .targetExists(let path):
                eprint("export error: refusing to overwrite existing output at \(terminalSafe(path))")
            case .outputUnwritable(let detail):
                eprint("export error: cannot write output: \(terminalSafe(detail))")
            default:
                eprint("export error: \(terminalSafe(String(describing: error)))")
            }
            throw ExitCode(4)
        }
        if includeContent {
            eprint("warning: content-bearing export written to \(terminalSafe(output)) — it carries verbatim operator/model/tool text and makes no claim that user text is secret-free")
        } else {
            eprint("exported session '\(terminalSafe(sessionID))' (\(lines.count - 2) records) to \(terminalSafe(output))")
        }
    }
}
