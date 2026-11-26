import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// M4-C terminal capability probe (adapter-owned).
///
/// Width/caps live in the ADAPTER, outside the reducer (`UIAction.
/// terminal` stays a no-op — no reducer change). Plain mode keeps all
/// semantic text with zero ANSI bytes; `needletail run` JSONL output is
/// unaffected (that path never consults caps).
public struct TerminalCaps: Sendable, Equatable {
    /// SGR color spans enabled.
    public var color: Bool
    /// Cursor-addressed redraw (transient progress line, composer
    /// overlay in dumb-inline mode). False ⇒ append-only output.
    public var cursorAddressing: Bool
    /// Content width in columns, always ≥ 20.
    public var width: Int

    public init(color: Bool = true, cursorAddressing: Bool = true, width: Int = 80) {
        self.color = color
        self.cursorAddressing = cursorAddressing
        self.width = max(20, width)
    }

    public static let plain = TerminalCaps(color: false, cursorAddressing: false, width: 80)

    /// Adapter-side width derivation: explicit `columns` wins, else
    /// `COLUMNS` env (positive integers only), else the stdout ioctl
    /// winsize, else 80. Always clamped ≥ 20.
    public static func resolveColumns(env: [String: String], explicit: Int?, ioctlWidth: Int?) -> Int {
        if let explicit, explicit > 0 { return max(20, explicit) }
        if let raw = env["COLUMNS"], let parsed = Int(raw.trimmingCharacters(in: .whitespaces)), parsed > 0 {
            return max(20, parsed)
        }
        if let ioctlWidth, ioctlWidth > 0 { return max(20, ioctlWidth) }
        return 80
    }

    /// Stdout ioctl width (nil when unavailable — non-TTY, pipes).
    public static func ioctlColumns() -> Int? {
#if canImport(Glibc)
        var ws = winsize()
        guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0 else { return nil }
        return Int(ws.ws_col)
#elseif canImport(Darwin)
        var ws = winsize()
        guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0 else { return nil }
        return Int(ws.ws_col)
#else
        return nil
#endif
    }

    /// Derives caps from the process environment (injectable for tests).
    /// - `NO_COLOR` present AND non-empty ⇒ no color (no-color.org rule).
    /// - `TERM=dumb` ⇒ no color, no cursor addressing.
    /// - Non-TTY stdout ⇒ plain (append-only, no ANSI).
    /// - Width via `resolveColumns` (explicit/`COLUMNS`/ioctl/80).
    ///   A TTY with no other signal keeps color (documented, not plain).
    public static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment,
        isTTYStdout: Bool,
        columns: Int?
    ) -> TerminalCaps {
        guard isTTYStdout else { return TerminalCaps(color: false, cursorAddressing: false, width: columns ?? 80) }
        if env["TERM"] == "dumb" {
            return TerminalCaps(color: false, cursorAddressing: false, width: columns ?? 80)
        }
        if let noColor = env["NO_COLOR"], !noColor.isEmpty {
            return TerminalCaps(color: false, cursorAddressing: true, width: columns ?? 80)
        }
        return TerminalCaps(color: true, cursorAddressing: true, width: columns ?? 80)
    }
}
