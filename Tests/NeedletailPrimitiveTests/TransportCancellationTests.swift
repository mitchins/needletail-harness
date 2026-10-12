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

    deinit { close(listenFD) }
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
                return "completed-with-error"
            }
        }

        // Readiness handshake: never sleep in place of readiness; the wait
        // itself is bounded so a server regression fails fast.
        enum Readiness { case ready, timedOut }
        let readiness = await withTaskGroup(of: Readiness.self, returning: Readiness.self) { group in
            group.addTask {
                for await _ in server.requestReceived { return .ready }
                return .timedOut
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
        #expect(readiness == .ready, "synthetic server never received the request head")

        requestTask.cancel()

        // Bounded completion: cancellation must resolve, not hang.
        let outcome = await withTaskGroup(of: String.self, returning: String.self) { group in
            group.addTask { await requestTask.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return "timeout"
            }
            let first = await group.next() ?? "timeout"
            group.cancelAll()
            return first
        }
        server.stop()
        #expect(outcome != "timeout", "cancellation did not complete within the deadline")
        #expect(outcome == "completed-with-error", "expected a cancellation error, got \(outcome)")

        try await client.shutdown()
    }
}
