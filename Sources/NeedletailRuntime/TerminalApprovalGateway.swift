import Foundation
import NeedletailCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// B5-C minimal interactive terminal approval gateway (SPEC §9.1, REV25
/// §5/B5): presents a validated tool batch on a real TTY and requires an
/// explicit operator decision. No TUI, no M4 expansion.
///
/// Fail-closed contract:
/// - Both standard input AND standard output must be interactive TTYs;
///   anything else (pipe, redirect, closed) returns `.unavailable` — the
///   headless path (exit 3, no mutation) is unchanged.
/// - The prompt renders only harness-validated content (`operation` is
///   terminal-safe at construction; paths re-sanitized at the display
///   boundary). No model-controlled byte reaches the terminal unsanitized.
/// - Only an explicit `y`/`yes` line approves. EOF, read errors, empty
///   input and any other line deny. Nothing implies approval — not EOF,
///   not interruption, not a missing TTY.
/// - Approved paths travel structurally: the actor builds the executor
///   reservation from the request's validated `protectedPaths`
///   (`grantApproval` → `dispatchTrustedBatch`), so the gateway's job is
///   the decision, never path minting.
///
/// Handles are injectable for deterministic PTY tests; production reads
/// the decision from standard input and renders the prompt on standard
/// ERROR — standard output stays reserved for program output (pure JSONL
/// in `--format jsonl` mode).
public struct TerminalApprovalGateway: ApprovalGateway, Sendable {
    public var input: FileHandle
    public var output: FileHandle

    public init(input: FileHandle = .standardInput, output: FileHandle = .standardError) {
        self.input = input
        self.output = output
    }

    /// True only when BOTH handles are interactive TTYs (stdin for the
    /// decision, stderr for the visible prompt). Either side
    /// piped/redirected/closed fails closed to `.unavailable`.
    public var isInteractive: Bool {
        isatty(input.fileDescriptor) != 0 && isatty(output.fileDescriptor) != 0
    }

    public func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
        guard isInteractive else {
            return .unavailable("no interactive terminal: headless approval unavailable")
        }
        var prompt = "needletail approval required\n"
        // M2-C C0 (plan REV12 §3.3): bounded display. The constructor
        // already bounds `operation` at 8 KiB (the validator rejects
        // unrenderable commands); this is defense in depth for any
        // construction path — truncation is explicit and marked.
        var operationDisplay = terminalSafe(request.operation)
        if operationDisplay.utf8.count > 8 * 1024 {
            operationDisplay = String(operationDisplay.prefix(8 * 1024)) + "…[elided]"
        }
        prompt += "  operation: \(operationDisplay)\n"
        if !request.execIdentities.isEmpty {
            prompt += "  bound identities (content-digest verified at dispatch):\n"
            for id in request.execIdentities {
                prompt += "    - \(terminalSafe(id.resolvedPath)) digest=\(terminalSafe(String(id.contentDigest.prefix(16))))…\n"
            }
        }
        prompt += "  grant: \(terminalSafe(request.requiredGrant))\n"
        if request.protectedPaths.isEmpty {
            prompt += "  paths: (none)\n"
        } else {
            prompt += "  paths:\n"
            for path in request.protectedPaths {
                prompt += "    - \(terminalSafe(path))\n"
            }
        }
        prompt += "Approve and execute? [y/N] "
        do {
            try output.write(contentsOf: Data(prompt.utf8))
        } catch {
            // The operator cannot see the request: approval is impossible.
            return .deny("cannot present approval request")
        }
        guard let line = readDecisionLine(),
              ["y", "yes"].contains(line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
              !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .deny("operator did not explicitly approve")
        }
        return .approve
    }

    /// One bounded decision line (4096 bytes cap): EOF/read-error/no-input
    /// returns nil (deny upstream), never blocks past a closed input.
    private func readDecisionLine() -> String? {
        var bytes: [UInt8] = []
        while bytes.count < 4096 {
            let chunk: Data
            do {
                guard let data = try input.read(upToCount: 1), !data.isEmpty else {
                    return nil
                }
                chunk = data
            } catch {
                return nil
            }
            guard let byte = chunk.first else { return nil }
            if byte == UInt8(ascii: "\n") { break }
            bytes.append(byte)
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}
