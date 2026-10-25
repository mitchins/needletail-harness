import Testing
import Foundation
import NeedletailTestSupport

/// Loopback fixture shutdown contract (FINAL-03 CodeRabbit review): a
/// client that connects without completing a request head must not pin
/// the server thread past stop(). stop() returns promptly and the
/// thread exits; the bounded join is real, not notional.
///
/// Linux-only fixture coverage (LoopbackSSEServer refuses non-Linux at
/// init); the file contributes no tests elsewhere.
#if os(Linux)
struct LoopbackServerShutdownTests {

    @Test("silent client does not pin the server thread past stop")
    func silentClientReleasesOnStop() async throws {
        let server = try LoopbackSSEServer()
        server.start()
        defer { server.stop() }
        // Raw client: connect, send nothing (no request head).
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        try #require(fd >= 0, "test socket creation failed")
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        address.sin_port = server.port.bigEndian
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(connected == 0, "test client could not connect to the loopback server")
        // Wait until the server is actually blocked inside readHead:
        // connect() alone can complete while the client sits in the
        // backlog, which would let stop() win before the blocked read
        // starts and pass vacuously.
        let reading = server.waitUntilReadingHead(timeout: 5)
        try #require(reading, "server never entered readHead for the silent client")
        // Control: without stop(), the thread must stay blocked in the
        // 30 s slow-start tolerance (it must NOT return spuriously).
        // The client socket stays open for the whole test, so an early
        // return here would mean a spurious readHead exit; every other
        // loopback test independently proves heads are consumed.
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(!server.threadExited, "server thread must stay blocked in readHead without stop")
        // Shutdown with a silent client connected: the accept/read path
        // must notice promptly (100 ms poll slices), not wait out the
        // 30 s slow-start tolerance.
        let stopStart = Date()
        server.stop()
        let deadline = Date().addingTimeInterval(5)
        while !server.threadExited && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(server.threadExited, "server thread must exit promptly after stop with a silent client")
        #expect(Date().timeIntervalSince(stopStart) < 5.0, "stop() must return promptly")
    }
}
#endif
