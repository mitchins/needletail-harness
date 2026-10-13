import Testing
import AsyncHTTPClient
import Foundation

/// NET-04 primitive tier — transport cancellation over the production HTTP
/// client. Given an in-flight request against a synthetic loopback server
/// that has received the request but will never respond, when the operator
/// cancels, then the request task completes within a bounded deadline and
/// the client shuts down cleanly. No automatic resend is attempted.
///
/// This exercises NET-04's "explicit cancellation works" obligation only.
/// NET-05 (bounded pre-stream retry vs mid-stream disconnect partial-output
/// handling) is NOT covered here: it requires the harness's retry policy
/// and partial-stream accumulation, which do not exist yet — it stays
/// DEFERRED_BY_PLAN (due M1). CORE-02's session-state cancellation
/// obligations likewise land with the session state machine (M1-B).
///
/// The server is test-only code using OS socket interfaces; no additional
/// package dependency is introduced.

private enum TestServerError: Error { case socketFailed, bindFailed, listenFailed }

private func bindTestServerSocket(_ listenFD: Int32) throws -> UInt16 {
    var yes: Int32 = 1
    setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = INADDR_ANY
    address.sin_port = 0
    let bindResult = withUnsafePointer(to: &address) { pointer -> Int32 in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else { throw TestServerError.bindFailed }
    guard listen(listenFD, 1) == 0 else { throw TestServerError.listenFailed }
    var bound = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &bound) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(listenFD, $0, &length)
        }
    }
    return UInt16(bigEndian: bound.sin_port)
}

private final class SyntheticLoopbackServer: @unchecked Sendable {

    private let listenFD: Int32
    let port: UInt16
    private let requestReceivedStream: AsyncStream<Void>
    private let requestReceivedContinuation: AsyncStream<Void>.Continuation
    private let holdSemaphore = DispatchSemaphore(value: 0)

    init() throws {
        listenFD = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard listenFD >= 0 else { throw TestServerError.socketFailed }
        let boundPort = try bindTestServerSocket(listenFD)
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.port = boundPort
        self.requestReceivedStream = stream
        self.requestReceivedContinuation = continuation
    }

    var requestReceived: AsyncStream<Void> { requestReceivedStream }

    func start() {
        let continuation = requestReceivedContinuation
        let listenFD = self.listenFD
        let holdSemaphore = self.holdSemaphore
        Thread.detachNewThread {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else { continuation.finish(); return }
            var buffer = [UInt8](repeating: 0, count: 1024)
            _ = read(clientFD, &buffer, buffer.count)
            continuation.yield()   // readiness: the request head arrived
            // Hold the connection open, deliberately never responding, so
            // cancellation is the only way the request can finish. Bounded
            // so a test process cannot leak the thread indefinitely: the
            // wait is a semaphore timed wait, not a polling loop.
            _ = holdSemaphore.wait(timeout: .now() + 10)
            close(clientFD)
            continuation.finish()
        }
    }

    func stop() {
        holdSemaphore.signal()
    }

    /// Finishes the readiness stream so a waiter suspended on it
    /// terminates instead of lingering. Test-only cleanup for the timeout
    /// path; finishing an already-finished stream is a no-op.
    func abandon() {
        requestReceivedContinuation.finish()
    }

    deinit { close(listenFD) }
}

/// Maps a request-task error to its outcome string. Only a genuine
/// cancellation reports cancellation. Observed on the wire: cancelling the
/// awaiting task surfaces Swift's own `CancellationError` at the suspension
/// point (AsyncHTTPClient's `HTTPClientError.cancelled`, produced via its
/// task-cancellation handler, is accepted too for other/older paths). Any
/// other error — refused connection, server-side close, deadline — reports
/// as a failure and can never masquerade as a cancellation.
private func classifyRequestError(_ error: Error) -> String {
    if error is CancellationError { return "cancelled" }
    if (error as? HTTPClientError) == HTTPClientError.cancelled { return "cancelled" }
    return "failed: \(error)"
}

/// Races `produce` against a wall-clock deadline WITHOUT a task group. A
/// task-group race cannot return past a stalled child: the group awaits
/// cancelled children at scope exit, and awaiting a task value is not
/// itself cancellable. The unstructured waiter may outlive this call on
/// the timeout path; the caller must release the underlying work (e.g.
/// `server.stop()`) so cleanup stays bounded.
private func raceToCompletion(
    produce: @Sendable @escaping () async -> String,
    deadlineSeconds: Double
) async -> String {
    final class Latch: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func set(_ string: String) {
            lock.lock()
            defer { lock.unlock() }
            if value == nil { value = string }
        }
        func get() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }
    let latch = Latch()
    Task { await latch.set(await produce()) }
    let deadline = Date().addingTimeInterval(deadlineSeconds)
    while Date() < deadline {
        if let done = latch.get() { return done }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return latch.get() ?? "timeout"
}

/// A loopback port with nothing listening: bind, read the port back, close.
/// Connecting there fails fast with connection-refused (no cancellation).
private func bindThenCloseLoopbackPort() throws -> UInt16 {
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    guard fd >= 0 else { throw TestServerError.socketFailed }
    let port = try bindTestServerSocket(fd)
    close(fd)
    return port
}

/// Bounded readiness handshake: true once the server observes the request
/// head, false on deadline. Never sleeps in place of readiness — the wait
/// itself is the bounded gate, so a silent server fails fast instead of
/// hanging the suite (an unbounded `for await` over the stream would wait
/// forever when nothing ever yields nor finishes it). On timeout the
/// stream is finished so the producer task terminates and releases the
/// server instead of lingering suspended.
private func awaitRequestHead(_ server: SyntheticLoopbackServer, deadlineSeconds: Double) async -> Bool {
    let outcome = await raceToCompletion(produce: {
        for await _ in server.requestReceived { return "ready" }
        return "closed"
    }, deadlineSeconds: deadlineSeconds)
    if outcome == "timeout" {
        server.abandon()
    }
    return outcome == "ready"
}

struct TransportCancellationTests {

    @Test("NET-04 cancelling an in-flight request completes bounded with no resend")
    func NET_04_cancellationCompletesBounded() async throws {
        let server = try SyntheticLoopbackServer()
        server.start()
        let client = HTTPClient(eventLoopGroupProvider: .singleton)

        var request = HTTPClientRequest(url: "http://127.0.0.1:\(server.port)/v1/chat/completions")
        request.method = .POST
        // AsyncHTTPClient's cancellation-aware execute: task cancellation
        // fails the in-flight request. No automatic resend or retry exists
        // in this path; a second request would have to be issued explicitly.
        let requestTask = Task { () -> String in
            do {
                _ = try await client.execute(request, timeout: .seconds(60))
                return "completed-with-response"
            } catch {
                return classifyRequestError(error)
            }
        }

        // Readiness handshake: never sleep in place of readiness; the wait
        // itself is bounded so a server regression fails fast.
        let ready = await awaitRequestHead(server, deadlineSeconds: 10)
        #expect(ready, "synthetic server never received the request head")

        requestTask.cancel()

        // Bounded completion: cancellation must resolve, not hang. The
        // deadline race must be able to RETURN on timeout, so it does not
        // use a task group (a group awaits even cancelled children, and
        // awaiting a task value is not itself cancellable). server.stop()
        // releases a stalled request, so cleanup stays bounded too.
        let outcome = await raceToCompletion(produce: { await requestTask.value }, deadlineSeconds: 10)
        server.stop()
        #expect(outcome == "cancelled", "expected a cancellation error, got \(outcome)")

        try await client.shutdown()
    }

    @Test("NET-04 cancellation errors classify as cancelled")
    func NET_04_cancellationErrorClassifies() {
        #expect(classifyRequestError(CancellationError()) == "cancelled")
        #expect(classifyRequestError(HTTPClientError.cancelled) == "cancelled")
    }

    @Test("NET-04 non-cancellation errors never classify as cancelled")
    func NET_04_otherErrorsNeverClassifyAsCancelled() {
        #expect(classifyRequestError(TestServerError.bindFailed) != "cancelled")
        #expect(classifyRequestError(HTTPClientError.cancelled) == "cancelled")
    }

    @Test("NET-04 a refused connection is not reported as a cancellation")
    func NET_04_refusedConnectionIsNotCancellation() async throws {
        // No cancellation happens on the refused path; the cancel path
        // cancels against a holding server. The two outcomes must differ —
        // the old mapping returned "completed-with-error" for both.
        let refused = try await runRefusedRequest()
        let cancelled = try await runCancelledRequest()
        #expect(refused != cancelled, "refused (\(refused)) and cancelled (\(cancelled)) must report differently")
    }

    @Test("NET-04 a stalled request does not hold the deadline past its bound")
    func NET_04_stalledRequestReleasesAtDeadline() async {
        // Mechanism regression test for the deadline race: a producer that
        // ignores cancellation must not prevent the deadline from firing.
        // The gate is released afterwards so the waiter finishes and
        // nothing leaks past the test.
        actor ReleaseGate {
            var released = false
            func release() { released = true }
        }
        let gate = ReleaseGate()
        let start = Date()
        let outcome = await raceToCompletion(produce: {
            while await gate.released == false {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return "released"
        }, deadlineSeconds: 1)
        let elapsed = Date().timeIntervalSince(start)
        #expect(outcome == "timeout", "a stalled producer must hit the deadline, got \(outcome)")
        #expect(elapsed >= 1.0, "the full deadline must elapse, returned after \(elapsed)s")
        #expect(elapsed < 5.0, "the deadline must fire at ~1s, took \(elapsed)s")
        await gate.release()
    }

    private func runRefusedRequest() async throws -> String {
        let port = try bindThenCloseLoopbackPort()
        let client = HTTPClient(eventLoopGroupProvider: .singleton)
        var request = HTTPClientRequest(url: "http://127.0.0.1:\(port)/v1/chat/completions")
        request.method = .POST
        // AsyncHTTPClient retries a refused connection until the request
        // deadline, so this resolves at ~2 s with a non-cancellation error —
        // deterministically different from a cancellation either way.
        let outcome: String
        do {
            _ = try await client.execute(request, timeout: .seconds(2))
            outcome = "completed-with-response"
        } catch {
            outcome = classifyRequestError(error)
        }
        try await client.shutdown()
        return outcome
    }

    private func runCancelledRequest() async throws -> String {
        let server = try SyntheticLoopbackServer()
        server.start()
        let client = HTTPClient(eventLoopGroupProvider: .singleton)
        var request = HTTPClientRequest(url: "http://127.0.0.1:\(server.port)/v1/chat/completions")
        request.method = .POST
        let requestTask = Task { () -> String in
            do {
                _ = try await client.execute(request, timeout: .seconds(60))
                return "completed-with-response"
            } catch {
                return classifyRequestError(error)
            }
        }
        guard await awaitRequestHead(server, deadlineSeconds: 10) else {
            server.stop()
            try await client.shutdown()
            return "failed: request head never arrived"
        }
        requestTask.cancel()
        let outcome = await raceToCompletion(produce: { await requestTask.value }, deadlineSeconds: 10)
        server.stop()
        try await client.shutdown()
        return outcome
    }

    @Test("NET-04 a silent server fails readiness fast instead of hanging")
    func NET_04_silentServerFailsReadinessFast() async throws {
        // The server is never started, so no request head can arrive and
        // the stream never finishes: an unbounded wait would hang (see
        // cr-red-readiness-hang.log, killed by timeout). The bounded
        // handshake must report false at ~the deadline instead.
        let server = try SyntheticLoopbackServer()
        let start = Date()
        let ready = await awaitRequestHead(server, deadlineSeconds: 1)
        let elapsed = Date().timeIntervalSince(start)
        #expect(!ready, "an unstarted server must not report readiness")
        #expect(elapsed >= 1.0, "the full deadline must elapse, returned after \(elapsed)s")
        #expect(elapsed < 5.0, "readiness must fail at ~1s, took \(elapsed)s")
    }

    @Test("NET-04 a timed-out readiness wait releases the server")
    func NET_04_timedOutReadinessReleasesServer() async throws {
        // The timed-out producer must terminate (via abandon) instead of
        // lingering suspended on the unfinished stream while retaining the
        // server. A weak reference proves the release: it must drain once
        // the waiter finishes.
        weak var weakServer: SyntheticLoopbackServer?
        do {
            let server = try SyntheticLoopbackServer()
            weakServer = server
            let ready = await awaitRequestHead(server, deadlineSeconds: 1)
            #expect(!ready, "an unstarted server must not report readiness")
        }
        let deadline = Date().addingTimeInterval(5)
        while weakServer != nil && Date() < deadline {
            await Task.yield()
        }
        #expect(weakServer == nil, "timed-out producer must terminate and release the server")
    }
}
