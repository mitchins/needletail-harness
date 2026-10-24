import Testing
import Foundation
import NeedletailCore
import NeedletailRuntime
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// B5-C interactive approval gateway: deterministic PTY evidence (no
/// human, no TUI). The gateway decides through injected handles; a real
/// PTY pair proves TTY detection, prompt sanitization and the explicit
/// approve/deny contract byte-for-byte.
///
/// NOTE: these tests certify gateway behavior only (tier pty). TOOL-case
/// certification lives in the native-process binary legs, which drive the
/// same gateway through a PTY-backed child stdin.
struct TerminalGatewayTests {

    private struct PTYError: Error {}

    private static func ptyPair() throws -> (master: Int32, slave: Int32) {
        var master: Int32 = -1
        var slave: Int32 = -1
#if canImport(Glibc)
        guard Glibc.openpty(&master, &slave, nil, nil, nil) == 0 else { throw PTYError() }
#elseif canImport(Darwin)
        guard Darwin.openpty(&master, &slave, nil, nil, nil) == 0 else { throw PTYError() }
#endif
        return (master, slave)
    }

    private static func closeFD(_ fd: Int32) {
#if canImport(Glibc)
        Glibc.close(fd)
#elseif canImport(Darwin)
        Darwin.close(fd)
#endif
    }

    /// Bounded master-side read: polls for readability, then drains
    /// whatever arrived (PTY output is buffered, so post-decide reads are
    /// race-free). Returns after 500ms of consecutive idleness — the
    /// prompt is always fully queued before `decide` returns.
    private static func readMaster(_ master: Int32, timeoutMS: Int32 = 5000) throws -> Data {
        var collected = Data()
        var remaining = timeoutMS
        var idlePolls = 0
        while remaining > 0 {
            var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
#if canImport(Glibc)
            let ready = Glibc.poll(&pfd, 1, 100)
#elseif canImport(Darwin)
            let ready = Darwin.poll(&pfd, 1, 100)
#endif
            if ready > 0 {
                idlePolls = 0
                var buf = [UInt8](repeating: 0, count: 4096)
                let count = buf.withUnsafeMutableBytes { raw in
#if canImport(Glibc)
                    Glibc.read(master, raw.baseAddress, 4096)
#elseif canImport(Darwin)
                    Darwin.read(master, raw.baseAddress, 4096)
#endif
                }
                if count > 0 { collected.append(contentsOf: buf.prefix(count)) }
                if count <= 0 { break }
                continue
            }
            idlePolls += 1
            if !collected.isEmpty && idlePolls >= 5 { break }
            remaining -= 100
        }
        return collected
    }

    private static func writeMaster(_ master: Int32, _ text: String) throws {
        let bytes = Array(text.utf8)
        try bytes.withUnsafeBufferPointer { buf in
            var written = 0
            while written < buf.count {
#if canImport(Glibc)
                let count = Glibc.write(master, buf.baseAddress!.advanced(by: written), buf.count - written)
#elseif canImport(Darwin)
                let count = Darwin.write(master, buf.baseAddress!.advanced(by: written), buf.count - written)
#endif
                guard count > 0 else { throw PTYError() }
                written += count
            }
        }
    }

    private static func request(operation: String = "tool batch: edit", paths: [String] = ["/ws/notes.txt"]) -> ApprovalRequest {
        ApprovalRequest(
            requestID: RequestID("req-1"), runID: RunID("run-1"),
            generation: Revision(1), operation: operation,
            requiredGrant: "explicit approval", protectedPaths: paths)
    }

    @Test("B5-C TTY + explicit y approves")
    func ttyExplicitYesApproves() async throws {
        let (master, slave) = try Self.ptyPair()
        defer { Self.closeFD(master); Self.closeFD(slave) }
        let gateway = TerminalApprovalGateway(
            input: FileHandle(fileDescriptor: slave, closeOnDealloc: false),
            output: FileHandle(fileDescriptor: slave, closeOnDealloc: false))
        #expect(gateway.isInteractive, "PTY slave is an interactive TTY")
        try Self.writeMaster(master, "y\n")
        let decision = await gateway.decide(Self.request())
        #expect(decision == .approve)
        let prompt = try Self.readMaster(master)
        #expect(String(data: prompt, encoding: .utf8)?.contains("Approve and execute?") == true)
    }

    @Test("B5-C TTY + explicit n denies, zero approval")
    func ttyExplicitNoDenies() async throws {
        let (master, slave) = try Self.ptyPair()
        defer { Self.closeFD(master); Self.closeFD(slave) }
        let gateway = TerminalApprovalGateway(
            input: FileHandle(fileDescriptor: slave, closeOnDealloc: false),
            output: FileHandle(fileDescriptor: slave, closeOnDealloc: false))
        try Self.writeMaster(master, "n\n")
        let decision = await gateway.decide(Self.request())
        guard case .deny = decision else {
            Issue.record("expected deny, got \(decision)")
            return
        }
    }

    @Test("B5-C EOF on a TTY denies, never approves")
    func ttyEOFDenies() async throws {
        // Ctrl+D (VEOF) on an OPEN master: the slave read returns EOF
        // while the TTY itself stays interactive — the gateway must deny,
        // never hang and never approve.
        let (master, slave) = try Self.ptyPair()
        defer { Self.closeFD(master); Self.closeFD(slave) }
        let gateway = TerminalApprovalGateway(
            input: FileHandle(fileDescriptor: slave, closeOnDealloc: false),
            output: FileHandle(fileDescriptor: slave, closeOnDealloc: false))
        #expect(gateway.isInteractive, "open PTY slave is an interactive TTY")
        try Self.writeMaster(master, "\u{04}")
        let decision = await gateway.decide(Self.request())
        guard case .deny = decision else {
            Issue.record("EOF must deny, got \(decision)")
            return
        }
    }

    @Test("B5-C pipes are not interactive: unavailable, never a decision")
    func pipesAreUnavailable() async throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let gateway = TerminalApprovalGateway(
            input: inputPipe.fileHandleForReading, output: outputPipe.fileHandleForWriting)
        #expect(!gateway.isInteractive, "pipes are not TTYs")
        let decision = await gateway.decide(Self.request())
        guard case .unavailable = decision else {
            Issue.record("expected unavailable, got \(decision)")
            return
        }
    }

    @Test("B5-C prompt sanitizes model-controlled bytes at the TTY boundary")
    func promptSanitizesModelBytes() async throws {
        let (master, slave) = try Self.ptyPair()
        defer { Self.closeFD(master); Self.closeFD(slave) }
        let gateway = TerminalApprovalGateway(
            input: FileHandle(fileDescriptor: slave, closeOnDealloc: false),
            output: FileHandle(fileDescriptor: slave, closeOnDealloc: false))
        // CSI erase + bidi override in the operation, zero-width in a path.
        let hostileOp = "tool batch: edit \u{1B}[2J \u{202E}evil"
        let hostilePath = "/ws/\u{200B}bad"
        try Self.writeMaster(master, "y\n")
        let decision = await gateway.decide(Self.request(operation: hostileOp, paths: [hostilePath]))
        #expect(decision == .approve)
        let prompt = try Self.readMaster(master)
        let text = String(data: prompt, encoding: .utf8) ?? ""
        let bytes = [UInt8](prompt)
        #expect(!bytes.contains(0x1B), "no ESC byte may reach the terminal")
        #expect(!text.contains("\u{202E}"), "bidi override neutralized")
        #expect(!text.contains("\u{200B}"), "zero-width neutralized")
        #expect(text.contains("\u{FFFD}"), "neutralization marker present")
        #expect(text.contains("Approve and execute?") == true)
    }

    @Test("B5-C garbage line denies (only y/yes approves)")
    func garbageLineDenies() async throws {
        let (master, slave) = try Self.ptyPair()
        defer { Self.closeFD(master); Self.closeFD(slave) }
        let gateway = TerminalApprovalGateway(
            input: FileHandle(fileDescriptor: slave, closeOnDealloc: false),
            output: FileHandle(fileDescriptor: slave, closeOnDealloc: false))
        try Self.writeMaster(master, "approve it please\n")
        let decision = await gateway.decide(Self.request())
        guard case .deny = decision else {
            Issue.record("non-y input must deny, got \(decision)")
            return
        }
    }
}
