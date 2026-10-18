import Testing
import Foundation
import NeedletailCore
import NeedletailRuntime

/// A0 support evidence (UNLABELED — no catalogue case): the durable record
/// codec must round-trip ALL NINE `DurableRecord` cases losslessly, encode
/// canonically (identical values → identical bytes), and FAIL CLOSED on
/// corrupted or semantically invalid payloads instead of substituting.
/// The nativeStorage/STORE evidence this enables lands in A1+; this file
/// pins the codec itself.
struct RecordCodecTests {

    // MARK: - Fixtures (minimal but real: built through the validating inits)

    private static func profile(alias: String, locality: Locality = .local,
                                credential: CredentialReference? = CredentialReference(kind: .env(name: "NT_STORE_KEY"))) throws -> ModelProfile {
        let rawOptions = Data(#"{"temperature":0.2}"#.utf8)
        return try ModelProfile(
            alias: alias, wireProtocol: .openAIChatCompletions,
            baseURL: "http://127.0.0.1:11434", modelID: "qwen2.5-coder-32b",
            contextWindow: 262144, maxOutput: 4096, locality: locality,
            credential: credential, connectTimeout: 10, readIdleTimeout: 300,
            requestTimeout: 1800, maxInFlight: 1,
            requestOptions: ["temperature": .number(0.2)],
            requestOptionsRaw: rawOptions)
    }

    private static func snapshot(profile: ModelProfile) -> ConfigSnapshot {
        ConfigSnapshot(
            version: 1, profiles: [profile.alias: profile],
            defaultAlias: profile.alias,
            allowHTTPOrigins: ["http://127.0.0.1:11434"],
            tools: .allDenied)
    }

    private static func epoch(id: String, parent: EpochID? = nil, route: Route) throws -> EpochDescriptor {
        let profile = try Self.profile(alias: "local-coder")
        let caps = EffectiveCapabilities(
            tools: .allDenied, route: .localOnly, deniedBy: ["build", "userConfig"])
        return EpochDescriptor(
            epochID: EpochID(id), parentEpochID: parent,
            configSnapshot: Self.snapshot(profile: profile), profile: profile,
            effectiveCaps: caps, route: route)
    }

    private static let opID = OperationID("op-1")

    private static func allNineCases() throws -> [DurableRecord] {
        [
            .sessionOpened(session: SessionID("s-1"), atMillis: 1000),
            .epochOpened(try epoch(id: "epoch-1", parent: nil,
                                   route: .allowed(endpoint: "http://127.0.0.1:11434/v1", alias: "local-coder"))),
            .epochOpened(try epoch(id: "epoch-2", parent: EpochID("epoch-1"),
                                   route: .denied(RouteDenial(kind: .originNotAllowlisted, message: "origin denied")))),
            .eventAppended(seq: SequenceNumber(7), kind: "cancelling", digest: "a1b2c3"),
            .operationIntent(OperationRef(operationID: opID, callID: "call-1", state: .intent, mutating: true)),
            .operationResult(OperationRef(operationID: opID, callID: nil, state: .done, mutating: false),
                             outcome: "denied: exec"),
            .queueAdmitted(QueueEntry(entryID: "q-1", commandID: CommandID("cmd-1"), kind: .followUp,
                                      state: .queued, revision: 3, text: "fix the bug",
                                      targetEpochID: EpochID("epoch-1"), orderKey: 42, sealed: true)),
            .queueUpdated(QueueEntry(entryID: "q-1", commandID: CommandID("cmd-1"), kind: .steer,
                                     state: .dispatched, revision: 4, text: "fix the bug NOW",
                                     targetEpochID: EpochID("epoch-1"), orderKey: 42, sealed: false)),
            .checkpointCommitted(try epoch(id: "epoch-3", parent: EpochID("epoch-1"),
                                           route: .allowed(endpoint: "http://127.0.0.1:11434/v1", alias: "local-coder"))),
        ]
    }

    /// The transcript shapes ride DurableRecord.transcriptAppended; every
    /// TranscriptEntry case round-trips too (toolCall carries an already
    /// Codable payload).
    private static func allTranscriptEntries() -> [TranscriptEntry] {
        [
            .user("hello"),
            .assistantText("hi there"),
            .toolCall(NativeToolCall(callID: "c-1", tool: "read", arguments: #"{"path":"f"}"#)),
            .toolResponse(callID: "c-1", text: "file body"),
        ]
    }

    // MARK: - Round trip (the oracle)

    @Test("record codec round-trips every DurableRecord case losslessly")
    func roundTripEveryDurableRecordCase() throws {
        for (index, record) in try Self.allNineCases().enumerated() {
            let data = try RecordCodec.encode(record)
            let decoded = try RecordCodec.decode(data)
            #expect(decoded == record, "case \(index) must survive encode/decode unchanged")
        }
    }

    @Test("record codec round-trips every TranscriptEntry case losslessly")
    func roundTripEveryTranscriptEntry() throws {
        for entry in Self.allTranscriptEntries() {
            let record = DurableRecord.transcriptAppended(entry)
            let decoded = try RecordCodec.decode(RecordCodec.encode(record))
            #expect(decoded == record, "\(entry) must survive encode/decode unchanged")
        }
    }

    // MARK: - Canonicality

    @Test("record codec encodes canonically: identical values produce identical bytes")
    func encodingIsCanonical() throws {
        let record = try Self.allNineCases()[1] // epochOpened with a full snapshot
        let first = try RecordCodec.encode(record)
        let second = try RecordCodec.encode(record)
        #expect(first == second, "sortedKeys canonical form must be byte-stable")
        // Dictionary iteration order must not leak into the bytes.
        let withTwoProfiles = ConfigSnapshot(
            version: 1,
            profiles: ["b-model": try Self.profile(alias: "b-model"), "a-model": try Self.profile(alias: "a-model")],
            defaultAlias: "a-model", allowHTTPOrigins: [], tools: .allDenied)
        let snapshotRecord = DurableRecord.epochOpened(EpochDescriptor(
            epochID: EpochID("epoch-9"), parentEpochID: nil,
            configSnapshot: withTwoProfiles, profile: try Self.profile(alias: "a-model"),
            effectiveCaps: EffectiveCapabilities(tools: .allDenied, route: .localOnly, deniedBy: []),
            route: .allowed(endpoint: "http://127.0.0.1:11434/v1", alias: "a-model")))
        #expect(try RecordCodec.encode(snapshotRecord) == RecordCodec.encode(snapshotRecord),
                "multi-profile snapshots encode byte-stably")
    }

    // MARK: - Fail-closed integrity oracles

    @Test("record codec rejects corrupted payloads instead of substituting")
    func decodeRejectsCorruptedPayload() throws {
        func assertIntegrityFailure(_ payload: Data, sourceLocation: SourceLocation = #_sourceLocation) {
            do {
                _ = try RecordCodec.decode(payload)
                Issue.record("decoding must fail closed, not substitute", sourceLocation: sourceLocation)
            } catch let error as StoreError {
                guard case .integrity = error else {
                    Issue.record("expected .integrity, got \(error)", sourceLocation: sourceLocation)
                    return
                }
            } catch {
                Issue.record("expected StoreError.integrity, got \(error)", sourceLocation: sourceLocation)
            }
        }
        let data = try RecordCodec.encode(.sessionOpened(session: SessionID("s-1"), atMillis: 1))
        // Truncated / non-JSON garbage must throw .integrity, never a value.
        assertIntegrityFailure(data.prefix(data.count / 2))
        assertIntegrityFailure(Data("not json".utf8))
    }

    @Test("record codec refuses a semantically invalid profile row (validating decode)")
    func decodeRefusesInvalidProfileRow() throws {
        // Hand-built JSON with an out-of-range limit and a base URL whose
        // origin disagrees with the stored one: the VALIDATING init must
        // reject it — synthesis would have accepted both silently.
        let tampered = """
        {"epochOpened":{"configSnapshot":{"allowHTTPOrigins":[],"defaultAlias":"x","profiles":{"x":{"alias":"x","baseURL":"https://evil.example/v1","connectTimeout":10,"contextWindow":-5,"credential":{"env":"K"},"locality":{"_0":"local"},"maxInFlight":1,"maxOutput":4096,"modelID":"m","readIdleTimeout":300,"requestOptions":{},"requestOptionsRaw":"e30i","requestTimeout":1800,"unqualifiedOptions":[],"wireProtocol":{"_0":"openai-chat-completions"}}},"tools":{"consult":false,"edit":false,"exec":{"_0":"denied"},"read":false,"search":false,"write":false}},"effectiveCaps":{"deniedBy":[],"route":{"_0":"localOnly"},"tools":{"consult":false,"edit":false,"exec":{"_0":"denied"},"read":false,"search":false,"write":false}},"epochID":{"_0":"epoch-x"},"parentEpochID":null,"profile":{"alias":"x","baseURL":"https://evil.example/v1","connectTimeout":10,"contextWindow":-5,"credential":{"env":"K"},"locality":{"_0":"local"},"maxInFlight":1,"maxOutput":4096,"modelID":"m","readIdleTimeout":300,"requestOptions":{},"requestOptionsRaw":"e30i","requestTimeout":1800,"unqualifiedOptions":[],"wireProtocol":{"_0":"openai-chat-completions"}},"route":{"allowed":{"_0":{"_0":"https://evil.example/v1","_1":"x"}}}}}
        """
        do {
            _ = try RecordCodec.decode(Data(tampered.utf8))
            Issue.record("a semantically invalid profile row must fail the decode")
        } catch let error as StoreError {
            guard case .integrity = error else {
                Issue.record("expected .integrity, got \(error)"); return
            }
        } catch {
            Issue.record("expected StoreError.integrity, got \(error)"); return
        }
    }
}
