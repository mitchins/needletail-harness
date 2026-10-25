import Foundation
import NeedletailCore

/// M1-C scripted loopback HTTP server (test-only, Linux). Extends the M0-B
/// POSIX-socket pattern (no new dependency): binds 127.0.0.1:0, serves
/// scripted responses chunk-by-chunk with per-chunk delays, captures full
/// requests for assertions, and counts connections (redirect/proxy proofs).
/// Bounded poll + wakeup pipe + thread-exit latch throughout — no bare
/// blocking accept, no sleeps standing in for readiness on the test side
/// (tests poll the capture log / latch with loud bounds).

public struct SSEScript: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var chunks: [ScriptChunk]
    /// Close the connection abruptly after this many chunks (mid-stream RST
    /// simulation); nil = orderly close after all chunks.
    public var abortAfterChunks: Int?

    public init(
        status: Int = 200,
        headers: [(String, String)] = ["Content-Type": "text/event-stream"].map { ($0.key, $0.value) },
        chunks: [ScriptChunk] = [],
        abortAfterChunks: Int? = nil
    ) {
        self.status = status
        self.headers = headers
        self.chunks = chunks
        self.abortAfterChunks = abortAfterChunks
    }

    public static func sse(_ bodies: String..., delaysMillis: [UInt64] = []) -> SSEScript {
        SSEScript(chunks: bodies.enumerated().map { index, body in
            ScriptChunk(
                bytes: Array(("data: \(body)\n\n").utf8),
                delayMillis: index < delaysMillis.count ? delaysMillis[index] : 0)
        })
    }

    public static func redirect(to location: String) -> SSEScript {
        SSEScript(status: 302, headers: [("Location", location)], chunks: [])
    }
}

public struct ScriptChunk: Sendable {
    public var bytes: [UInt8]
    public var delayMillis: UInt64

    public init(bytes: [UInt8], delayMillis: UInt64 = 0) {
        self.bytes = bytes
        self.delayMillis = delayMillis
    }
}

public struct CapturedRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [(String, String)]
    public var body: [UInt8]

    public init(method: String, path: String, headers: [(String, String)], body: [UInt8]) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first(where: { $0.0.lowercased() == name })?.1
    }
}

public enum LoopbackError: Error, Sendable {
    case socketFailed
    case bindFailed
    case pipeFailed
    case unsupportedPlatform
    case overlargeRequest
}

public final class LoopbackSSEServer: @unchecked Sendable {
    public static let maxRequestHeadBytes = 64 << 10
    public static let maxRequestBodyBytes = 4 << 20

    private let lock = NSLock()
    private var scripts: [SSEScript] = []
    private var captured: [CapturedRequest] = []
    private var connections = 0
    private var _exited = false

    private let listenFD: Int32
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private var stopped = false
    public let port: UInt16

    public var connectionCount: Int { lock.withLock { connections } }
    public var requests: [CapturedRequest] { lock.withLock { captured } }
    public var threadExited: Bool { lock.withLock { _exited } }

    public init() throws {
#if os(Linux)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { throw LoopbackError.socketFailed }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 128) == 0 else {
            close(fd)
            throw LoopbackError.bindFailed
        }
        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else {
            close(fd)
            throw LoopbackError.pipeFailed
        }
        self.listenFD = fd
        self.port = UInt16(bigEndian: boundAddress.sin_port)
        self.wakeRead = pipeFDs[0]
        self.wakeWrite = pipeFDs[1]
#else
        throw LoopbackError.unsupportedPlatform
#endif
    }

    deinit {
        stop()
    }

    public var baseURL: String { "http://127.0.0.1:\(port)" }

    public func enqueue(_ script: SSEScript) {
        lock.withLock { scripts.append(script) }
    }

    public func start() {
        let listenFD = self.listenFD
        let wakeRead = self.wakeRead
        Thread.detachNewThread { [weak self] in
            self?.serveLoop(listenFD: listenFD, wakeRead: wakeRead)
        }
    }

    public func stop() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
        }
        var byte: UInt8 = 1
        _ = write(wakeWrite, &byte, 1)
        // Bounded join: poll the latch instead of sleeping blindly.
        for _ in 0..<200 {
            if threadExited { break }
            usleep(5_000)
        }
        // Descriptors are closed only by serveLoop after it exits.
    }

    private func markExited() {
        lock.withLock { _exited = true }
    }

    private func nextScript() -> SSEScript {
        lock.withLock {
            guard !scripts.isEmpty else {
                return SSEScript(status: 200, headers: [("Content-Type", "text/event-stream")], chunks: [])
            }
            return scripts.removeFirst()
        }
    }

    private func record(_ request: CapturedRequest) {
        lock.withLock {
            captured.append(request)
            connections += 1
        }
    }

    private func serveLoop(listenFD: Int32, wakeRead: Int32) {
        defer { close(listenFD); close(wakeRead); close(wakeWrite); markExited() }
        while true {
            var fds = [
                pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&fds, 2, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if fds[1].revents & Int16(POLLIN) != 0 {
                return
            }
            guard fds[0].revents & Int16(POLLIN) != 0 else { continue }
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { continue }
            // FINAL-03: generous client-head timeout. The spawned CLI
            // binary can take seconds to write its request head on a
            // saturated runner (cold page cache, descheduled startup);
            // the old 1 s timeout closed such connections, surfacing as
            // persistent ECONNREFUSED/ECONNRESET across the product's
            // full pre-send retry budget. 30 s still bounds a dead
            // client (test-level deadlines and stop() bound the suite);
            // no certified timeout is changed.
            var timeout = timeval(tv_sec: 30, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            handleClient(client)
        }
    }

    private func handleClient(_ client: Int32) {
        defer { close(client) }
        guard let head = readHead(client) else { return }
        let script = nextScript()
        record(CapturedRequest(
            method: head.method, path: head.path,
            headers: head.headers, body: head.body))
        var response = "HTTP/1.1 \(script.status) \(reason(script.status))\r\n"
        for (name, value) in script.headers {
            response += "\(name): \(value)\r\n"
        }
        if script.abortAfterChunks == nil {
            let total = script.chunks.reduce(0) { $0 + $1.bytes.count }
            response += "Content-Length: \(total)\r\n"
        }
        response += "Connection: close\r\n\r\n"
        _ = response.withCString { pointer in
            write(client, pointer, strlen(pointer))
        }
        for (index, chunk) in script.chunks.enumerated() {
            if let abort = script.abortAfterChunks, index >= abort {
                return // Abrupt close: no end, no Content-Length framing.
            }
            if lock.withLock({ stopped }) { return }
            if chunk.delayMillis > 0 {
                usleep(useconds_t(min(chunk.delayMillis, 60_000) * 1_000))
            }
            chunk.bytes.withUnsafeBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                _ = write(client, base, pointer.count)
            }
        }
    }

    private struct Head {
        var method: String
        var path: String
        var headers: [(String, String)]
        var body: [UInt8]
    }

    private func readHead(_ client: Int32) -> Head? {
        // Bounded slow-start tolerance with prompt shutdown (FINAL-03):
        // poll the client in 100 ms slices so stop() never waits out a
        // 30 s receive stall; the overall deadline still tolerates slow
        // children on saturated runners. Returns nil on shutdown, error,
        // oversize input, or deadline expiry.
        var buffer: [UInt8] = []
        buffer.reserveCapacity(4096)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            switch pollReadable(client) {
            case .failure: return nil
            case .success(false): continue
            case .success(true): break
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = chunk.withUnsafeMutableBytes { pointer in
                recv(client, pointer.baseAddress, pointer.count, 0)
            }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk.prefix(count))
            guard buffer.count <= Self.maxRequestHeadBytes + Self.maxRequestBodyBytes else { return nil }
            if let end = findHeaderEnd(buffer) {
                return parseHead(Array(buffer[..<end]), rest: Array(buffer[end...]), client: client, deadline: deadline)
            }
            if buffer.count > Self.maxRequestHeadBytes, findHeaderEnd(buffer) == nil {
                return nil
            }
        }
        return nil
    }

    /// Client readability within one 100 ms poll slice: `.success(true)`
    /// means bytes are ready, `.success(false)` means the slice elapsed
    /// (caller re-checks its own deadline), `.failure` means shutdown was
    /// requested or the fd errored — stop waiting.
    private func pollReadable(_ fd: Int32) -> Result<Bool, Error> {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while true {
            if lock.withLock({ stopped }) { return .failure(LoopbackError.pipeFailed) }
            let ready = poll(&pfd, 1, 100)
            if ready > 0 { return .success(true) }
            if ready < 0 {
                if errno == EINTR { continue }
                return .failure(LoopbackError.pipeFailed)
            }
            return .success(false)
        }
    }

    private func readBody(_ client: Int32, initial: [UInt8], need: Int, deadline: Date) -> [UInt8]? {
        // Matches the original break-on-EOF semantics: a client that
        // closes mid-body yields what arrived (unrecorded oversize still
        // fails); only shutdown, error, or deadline expiry drops the
        // request.
        var body = initial
        while body.count < need {
            if Date() >= deadline { return nil }
            switch pollReadable(client) {
            case .failure: return nil
            case .success(false): continue
            case .success(true): break
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = chunk.withUnsafeMutableBytes { pointer in
                recv(client, pointer.baseAddress, pointer.count, 0)
            }
            guard count > 0 else { break }
            body.append(contentsOf: chunk.prefix(count))
            guard body.count <= Self.maxRequestBodyBytes else { return nil }
        }
        return body
    }

    private func findHeaderEnd(_ buffer: [UInt8]) -> Int? {
        guard buffer.count >= 4 else { return nil }
        for i in 0...(buffer.count - 4) {
            if buffer[i] == 0x0D, buffer[i + 1] == 0x0A, buffer[i + 2] == 0x0D, buffer[i + 3] == 0x0A {
                return i + 4
            }
        }
        return nil
    }

    private func parseHead(_ head: [UInt8], rest: [UInt8], client: Int32, deadline: Date) -> Head? {
        guard let text = String(bytes: head, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [(String, String)] = []
        var contentLength = 0
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
            if name.lowercased() == "content-length" {
                contentLength = Int(value) ?? 0
            }
        }
        guard contentLength <= Self.maxRequestBodyBytes else { return nil }
        guard rest.count <= Self.maxRequestBodyBytes else { return nil }
        guard let body = readBody(client, initial: rest, need: contentLength, deadline: deadline) else { return nil }
        return Head(method: String(parts[0]), path: String(parts[1]), headers: headers, body: Array(body.prefix(contentLength)))
    }

    private func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 302: return "Found"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}
