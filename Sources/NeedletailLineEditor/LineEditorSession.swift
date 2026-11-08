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
    private var modifyHandler: (@Sendable (String, Int) -> Void)?
    private var keyHandlers: [Int32: @Sendable () -> KeyResult] = [:]

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

    /// Live-edit mirror (M4-C): reports the current buffer text and
    /// cursor (Unicode-scalar offset) after every modification. Fires
    /// on replxx's thread; must be set before `readLine`. The handler
    /// observes only — it must never rewrite the buffer (the adapter
    /// reconciles at submit/clear boundaries via `replaceDraft`).
    public func setModifyHandler(_ handler: (@Sendable (String, Int) -> Void)?) {
        modifyHandler = handler
        if handler != nil {
            let userData = Unmanaged.passUnretained(self).toOpaque()
            replxx_set_modify_callback(handle, { input, cursor, userData in
                guard let userData, let input, let cursor else { return }
                let session = Unmanaged<LineEditorSession>.fromOpaque(userData).takeUnretainedValue()
                guard let cstr = input.pointee else { return }
                session.modifyHandler?(String(cString: cstr), Int(cursor.pointee))
            }, userData)
        } else {
            replxx_set_modify_callback(handle, nil, nil)
        }
    }

    /// Binds a custom key handler (M4-C: Ctrl+C / Ctrl+J / Esc). The
    /// Swift handler runs on replxx's input thread; returning `.return`
    /// commits the line, `.bail` cancels input (nil line), `.continue`
    /// resumes editing. Must be set before `readLine`.
    ///
    /// After the handler runs, the trampoline re-reads the live buffer
    /// and fires the modify handler (if set): custom handlers edit via
    /// `set_state` (replxx does NOT fire the modify callback for them),
    /// so this explicit sync keeps the adapter mirror exact.
    public func bindKey(code: Int32, handler: (@Sendable () -> KeyResult)?) {
        if let handler {
            keyHandlers[code] = handler
            let userData = Unmanaged.passUnretained(self).toOpaque()
            replxx_bind_key(handle, code, { code, userData in
                guard let userData else { return REPLXX_ACTION_RESULT_CONTINUE }
                let session = Unmanaged<LineEditorSession>.fromOpaque(userData).takeUnretainedValue()
                let result = session.keyHandlers[code]?().rawValue ?? REPLXX_ACTION_RESULT_CONTINUE
                session.syncMirror()
                return result
            }, userData)
        } else {
            keyHandlers[code] = nil
            replxx_bind_key(handle, code, nil, nil)
        }
    }

    /// Re-reads the live buffer and fires the modify handler (mirror
    /// sync after handler-driven `set_state` edits).
    private func syncMirror() {
        var state = ReplxxState(text: nil, cursorPosition: 0)
        replxx_get_state(handle, &state)
        let text = state.text.map { String(cString: $0) } ?? ""
        modifyHandler?(text, Int(state.cursorPosition))
    }

    /// Clears the live buffer (M4-C idle Ctrl+C). Mirror syncs via the
    /// key-handler trampoline (or the next modify event); the adapter
    /// converges without a separate action.
    public func clearBuffer() {
        "".withCString { cstr in
            var state = ReplxxState(text: cstr, cursorPosition: 0)
            replxx_set_state(handle, &state)
        }
    }

    /// Inserts a newline at the live cursor (M4-C Ctrl+J multiline).
    /// replxx positions are UTF-32 code points = Swift scalar offsets.
    public func insertNewline() {
        var state = ReplxxState(text: nil, cursorPosition: 0)
        replxx_get_state(handle, &state)
        let text = state.text.map { String(cString: $0) } ?? ""
        let cursor = Int(state.cursorPosition)
        let scalars = Array(text.unicodeScalars)
        let at = min(max(0, cursor), scalars.count)
        let updated = String(String.UnicodeScalarView(scalars[..<at])) + "\n"
            + String(String.UnicodeScalarView(scalars[at...]))
        updated.withCString { cstr in
            var next = ReplxxState(text: cstr, cursorPosition: Int32(at + 1))
            replxx_set_state(handle, &next)
        }
    }

    public enum KeyResult: Sendable {
        case `continue`
        case commit
        case abort

        var rawValue: ReplxxActionResult {
            switch self {
            case .continue: return REPLXX_ACTION_RESULT_CONTINUE
            case .commit: return REPLXX_ACTION_RESULT_RETURN
            case .abort: return REPLXX_ACTION_RESULT_BAIL
            }
        }
    }

    /// Enables bracketed paste (M4-C SPEC ¶751: pasted `@` stays literal
    /// via the `pasteLiteral` mirror path).
    public func enableBracketedPaste() {
        replxx_enable_bracketed_paste(handle)
    }

    /// Preloads the buffer (M4-C draft restore after confirm mode).
    /// Consumed by the NEXT `readLine` (replxx loads the preload buffer
    /// after clearing — verified `replxx_impl.cxx` input path), so the
    /// saved draft returns verbatim. Cursor lands at end; the adapter
    /// mirror converges it on the next edit (scalar-exact positions).
    public func preload(_ text: String) {
        text.withCString { replxx_set_preload_buffer(handle, $0) }
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
