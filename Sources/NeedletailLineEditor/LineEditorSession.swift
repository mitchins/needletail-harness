import CReplxx
import Foundation

/// NeedletailLineEditor is the Swift seam over the vendored replxx C API
/// (target `CReplxx`). M0-C scope ONLY: session lifecycle, a blocking line
/// read, concurrent streamed output, and a completion callback. It is
/// deliberately not the M4 line-editor adapter — no bracket-paste policy,
/// no mention grammar, no renderer. M4 will wrap `NeedletailCLI` around
/// this seam; recorded as an architecture note in plans/m0-c-d-plan.md.
///
/// Concurrency contract (SPEC §4.1): `readLine` BLOCKS the calling thread
/// and must run on a dedicated blocking thread, never on a Swift
/// cooperative-executor task. `emit` is safe to call from another thread
/// while input is live — that is exactly the property the M0-C PTY
/// feasibility scenario exists to prove, not to assume (UX-DX §4).

/// `@unchecked Sendable` boundary: replxx's C API is designed for
/// `replxx_write`/`replxx_print` from other threads while `replxx_input`
/// runs (that concurrency is the property the M0-C scenario proves). The
/// wrapper's own mutable state (`completionHandler`) is set before the
/// input thread starts, and thread creation supplies the happens-before.
public final class LineEditorSession: @unchecked Sendable {
    private let handle: OpaquePointer
    private var completionHandler: (@Sendable (String) -> [String])?

    public init?() {
        guard let handle = replxx_init() else { return nil }
        self.handle = handle
        // Without this, SIGWINCH never reaches replxx: resizes change the
        // kernel winsize but the editor never repaints (M0-C evidence).
        _ = replxx_install_window_change_handler(handle)
    }

    deinit {
        replxx_end(handle)
    }

    /// Reads one line with the given prompt. Returns `nil` on cancel/EOF.
    /// The returned pointer is library-managed and must not be freed
    /// (replxx.h:372). Blocks the calling thread; call from a dedicated
    /// blocking thread.
    public func readLine(prompt: String) -> String? {
        let result: UnsafePointer<CChar>? = prompt.withCString { promptC in
            replxx_input(handle, promptC)
        }
        guard let result else { return nil }
        return String(cString: result)
    }

    /// Writes streamed output above the live composer. This is the
    /// concurrent-output path the feasibility scenario exercises. Uses the
    /// non-variadic `replxx_write` (the variadic `replxx_print` is not
    /// callable from Swift).
    public func emit(_ text: String) {
        text.withCString { textC in
            _ = replxx_write(handle, textC, Int32(strlen(textC)))
        }
    }

    /// Registers the completion handler. Must be set before `readLine`
    /// (the callback fires on replxx's thread while input is live; the
    /// handler is immutable by then).
    public func setCompletionHandler(_ handler: @escaping @Sendable (String) -> [String]) {
        completionHandler = handler
        let userData = Unmanaged.passUnretained(self).toOpaque()
        replxx_set_completion_callback(handle, { input, completions, contextLen, userData in
            guard let userData else { return }
            let session = Unmanaged<LineEditorSession>.fromOpaque(userData).takeUnretainedValue()
            session.invokeCompletion(input: input, completions: completions, contextLen: contextLen)
        }, userData)
    }

    private func invokeCompletion(
        input: UnsafePointer<CChar>?,
        completions: OpaquePointer?,
        contextLen: UnsafeMutablePointer<Int32>?
    ) {
        guard let completions else { return }
        let typed = input.map { String(cString: $0) } ?? ""
        guard let handler = completionHandler else { return }
        for candidate in handler(typed) {
            candidate.withCString { candidateC in
                replxx_add_completion(completions, candidateC)
            }
        }
    }
}
