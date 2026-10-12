import Testing
import OpenAPIRuntime

/// WIRE-01 / WIRE-02 primitive tier — SSE framing over the production
/// parser. Given the same raw wire bytes emitted as different chunk
/// splittings, when OpenAPIRuntime decodes them, then the decoded events are
/// identical to the unsplit reference. Forbidden: duplicate/lost events,
/// comment/heartbeat lines becoming model content, split UTF-8 corruption.
struct SSEFramingTests {

    /// A payload exercising comments/heartbeats, multi-line data fields,
    /// multi-byte UTF-8 (2- and 4-byte sequences) and CRLF framing.
    static let payload = """
    : heartbeat comment\r
    id: evt-1\r
    event: message\r
    data: {"delta":"héllo 🌍"}\r
    \r
    id: evt-2\r
    event: message\r
    data: line-one\r
    data: line-two\r
    \r

    """

    private static func decode(_ payload: [UInt8], chunkSize: Int) async throws -> [ServerSentEvent] {
        let chunks: [ArraySlice<UInt8>] = stride(from: 0, to: payload.count, by: max(chunkSize, 1)).map {
            payload[$0..<min($0 + max(chunkSize, 1), payload.count)]
        }
        let stream = AsyncStream<ArraySlice<UInt8>> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
        var events: [ServerSentEvent] = []
        for try await event in stream.asDecodedServerSentEvents() {
            events.append(event)
        }
        return events
    }

    @Test("WIRE-01 identical decoded events across every chunk boundary")
    func WIRE_01_identicalEventsAcrossChunkBoundaries() async throws {
        let bytes = Array(Self.payload.utf8)
        let reference = try await Self.decode(bytes, chunkSize: bytes.count)
        #expect(reference.count == 2, "expected two events, got \(reference.count)")

        // Split at every byte boundary, including inside multi-byte UTF-8.
        let perByte = try await Self.decode(bytes, chunkSize: 1)
        #expect(perByte == reference, "per-byte chunking changed the decoded events")

        // A few intermediate splittings; chunking is a transport detail.
        for size in [2, 3, 7, 16, 64] where size < bytes.count {
            let split = try await Self.decode(bytes, chunkSize: size)
            #expect(split == reference, "chunk size \(size) changed the decoded events")
        }
    }

    @Test("WIRE-02 comments, heartbeats and multi-line data are not model content")
    func WIRE_02_commentsAndMultiLineData() async throws {
        let bytes = Array(Self.payload.utf8)
        let events = try await Self.decode(bytes, chunkSize: 5)
        #expect(events.count == 2)
        #expect(events[0].id == "evt-1")
        #expect(events[0].event == "message")
        #expect(events[0].data?.contains(": heartbeat") != true, "comment lines must not leak into data")
        #expect(events[0].data?.contains("🌍") == true, "multi-byte UTF-8 must survive splitting")
        #expect(events[1].id == "evt-2")
        #expect(events[1].data == "line-one\nline-two", "multi-line data fields join per SSE semantics, got \(events[1].data ?? "nil")")
    }
}
