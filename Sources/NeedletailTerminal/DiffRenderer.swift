import Foundation
import NeedletailPresentation

/// M4-C unified-diff + tool-receipt line renderer.
///
/// Diff lines classify by PREFIX from semantic hunk strings (never
/// re-parsed as Markdown — a `+` line is display, not syntax):
/// `+++`/`---` file headers and `@@` hunks → `.diffHunk`;
/// `+` additions → `.diffAdd`; `-` deletions → `.diffDel`;
/// context and everything else → `.normal`. Every line passes through
/// `displaySafe` first, so hostile file bytes cannot inject terminal
/// operations (UX-RENDER-03/04 adapter legs).
public enum DiffRenderer {
    public static func renderHunks(_ hunks: [String]) -> [RenderedLine] {
        hunks.map { hunk in
            let safe = displaySafe(hunk)
            let role: StyleRole
            if safe.hasPrefix("@@") || safe.hasPrefix("+++") || safe.hasPrefix("---") || safe.hasPrefix("diff ") {
                role = .diffHunk
            } else if safe.hasPrefix("+") {
                role = .diffAdd
            } else if safe.hasPrefix("-") {
                role = .diffDel
            } else {
                role = .normal
            }
            return RenderedLine(spans: [TextSpan(text: safe, role: role)])
        }
    }

    /// Tool result receipt (actual lifecycle state from the projection —
    /// never inferred success). `tone` selects `.toolReceipt` (ok),
    /// `.warning` (held/partial) or `.errorNotice` (failed/denied).
    public static func receipt(_ text: String, tone: StyleRole) -> RenderedLine {
        RenderedLine(spans: [TextSpan(text: displaySafe(text), role: tone)])
    }
}
