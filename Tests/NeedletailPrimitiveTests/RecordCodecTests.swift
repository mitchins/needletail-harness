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

    private static func allCases() throws -> [DurableRecord] {
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
            .queueDispatched(QueueDispatchLink(
                entryID: "q-1", commandID: CommandID("cmd-1"),
                runID: RunID("r-1"), requestID: RequestID("req-1"),
                effectID: EffectID("eff-1"), epochID: EpochID("epoch-1"))),
            .checkpointCommitted(try epoch(id: "epoch-3", parent: EpochID("epoch-1"),
                                           route: .allowed(endpoint: "http://127.0.0.1:11434/v1", alias: "local-coder"))),
            .transcriptAppended(.assistantText("covered here too, not only in the sibling test")),
            .artifactPublished(ArtifactRef(
                digest: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
                size: 4, kind: "exec-output", operationID: opID)),
            .writerRecovered(WriterRecovery(
                previousWriter: "w-old", newWriter: "w-new",
                operatorID: "op-9", reference: "ticket-42", reason: "operator rotation",
                atMillis: 7000,
                unresolvedOperations: [OperationRef(
                    operationID: opID, callID: "call-1", state: .unknown, mutating: true)])),
            .cancelledPendingMarker(OperationRef(operationID: opID, callID: "call-1", state: .unknown, mutating: true), outcome: "cancelled: pending"),
            .cancelledPendingError(CancelledPendingError(effectID: EffectID("eff-1"), operationIDs: [opID], error: "cancelled", atMillis: 8000)),
            .acknowledgedUnresolved(Acknowledgment(subjectSessions: [SessionID("s-1")], operationIDs: [opID], determination: "operator-accepted-risk", atMillis: 9000)),
            .changeGroup(ChangeGroup(
                groupID: "chg-1", runID: RunID("r-1"), effectID: EffectID("eff-1"),
                members: [ChangeGroupMember(
                    operationID: opID, callID: "call-1", path: "notes/plan.txt",
                    grantedRoot: "/tmp/ws", created: false,
                    beforeHash: String(repeating: "b", count: 64),
                    afterHash: String(repeating: "a", count: 64),
                    deviceBefore: 11, inodeBefore: 22, modeBefore: "644",
                    preimageDigest: String(repeating: "b", count: 64), emptyOriginal: false,
                    deviceAfter: 11, inodeAfter: 23, modeAfter: "644",
                    receiptStatus: "success", receiptSummary: "edited notes/plan.txt")],
                hadExecProposals: false, hadReadProposals: true)),
            .undoDisposition(UndoDispositionRecord(
                undoCommandID: "undo-1", groupID: "chg-1",
                outcome: .completed,
                fileOutcomes: [UndoFileOutcome(
                    inverseID: "undo/undo-1/chg-1/\(opID.raw)", path: "notes/plan.txt",
                    result: "applied", detail: "restored notes/plan.txt")],
                reason: "all 1 inverse(s) applied", atMillis: 9500)),
            .lineageFork(LineageFork(
                forkID: "fork-1", sessionID: SessionID("s-1"),
                parentEpochID: EpochID("epoch-1"),
                boundary: LineageBoundary(epochID: EpochID("epoch-1"), throughSequence: 7),
                divergenceNote: "history preserved; workspace NOT restored", atMillis: 9600)),
        ]
    }

    /// NO default arm on purpose: a new DurableRecord case must fail the
    /// BUILD here before it can silently dodge the round-trip oracle.
    private static func caseName(_ record: DurableRecord) -> String {
        switch record {
        case .sessionOpened: return "sessionOpened"
        case .epochOpened: return "epochOpened"
        case .eventAppended: return "eventAppended"
        case .operationIntent: return "operationIntent"
        case .operationResult: return "operationResult"
        case .queueAdmitted: return "queueAdmitted"
        case .queueUpdated: return "queueUpdated"
        case .queueDispatched: return "queueDispatched"
        case .checkpointCommitted: return "checkpointCommitted"
        case .transcriptAppended: return "transcriptAppended"
        case .writerRecovered: return "writerRecovered"
        case .artifactPublished: return "artifactPublished"
        case .cancelledPendingMarker: return "cancelledPendingMarker"
        case .cancelledPendingError: return "cancelledPendingError"
        case .acknowledgedUnresolved: return "acknowledgedUnresolved"
        case .changeGroup: return "changeGroup"
        case .undoDisposition: return "undoDisposition"
        case .lineageFork: return "lineageFork"
        }
    }

    private static let expectedCaseNames: Set<String> = [
        "sessionOpened", "epochOpened", "eventAppended", "operationIntent",
        "operationResult", "queueAdmitted", "queueUpdated", "queueDispatched",
        "checkpointCommitted", "transcriptAppended", "writerRecovered",
        "artifactPublished", "cancelledPendingMarker", "cancelledPendingError",
        "acknowledgedUnresolved", "changeGroup", "undoDisposition", "lineageFork",
    ]

    /// The transcript shapes ride DurableRecord.transcriptAppended; every
    /// TranscriptEntry case round-trips too (toolCall carries an already
    /// Codable payload).
    private static func allTranscriptEntries() -> [TranscriptEntry] {
        [
            .user("hello"),
            .assistantText("hi there"),
            .toolCall(NativeToolCall(callID: "c-1", tool: "read", arguments: #"{"path":"f"}"#)),
            .toolResponse(callID: "c-1", text: "file body"),
            .workspaceChangeNotice(WorkspaceChangeNotice(
                undoCommandID: "undo-1", groupID: "chg-1", outcome: .completed,
                files: [UndoFileOutcome(
                    inverseID: "undo/undo-1/chg-1/op-1", path: "notes/plan.txt",
                    result: "applied", detail: "restored")],
                hadExecProposals: false, reason: "all 1 inverse(s) applied")),
        ]
    }

    // MARK: - Round trip (the oracle)

    @Test("record codec round-trips EVERY DurableRecord case losslessly (exhaustiveness pinned)")
    func roundTripEveryDurableRecordCase() throws {
        let records = try Self.allCases()
        var covered: Set<String> = []
        for (index, record) in records.enumerated() {
            let data = try RecordCodec.encode(record)
            let decoded = try RecordCodec.decode(data)
            #expect(decoded == record, "case \(index) must survive encode/decode unchanged")
            covered.insert(Self.caseName(record))
        }
        // The table must have exercised every case exactly by name; a new
        // case without a fixture fails here even before the build break.
        #expect(covered == Self.expectedCaseNames,
                "fixture table must cover all eighteen cases, covered=\(covered.sorted())")
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

    @Test("record codec encodes canonically: insertion order must not change the bytes")
    func encodingIsCanonical() throws {
        // Equal-by-value records whose dictionary LITERALS are written
        // in different orders (profiles map and requestOptions map) must
        // produce BYTE-identical rows: the encoder's canonical form must
        // not depend on construction order, and the golden pin catches
        // any encoder change.
        // Only LITERAL INSERTION ORDER differs between the two builds —
        // the values (including the verbatim requestOptionsRaw bytes) are
        // identical, so the records are equal by value and the bytes must
        // not depend on construction order.
        let optionsA = ["temperature": JSONValue.number(0.2), "top_p": .number(0.9)]
        let optionsB = ["top_p": JSONValue.number(0.9), "temperature": .number(0.2)]
        let raw = Data(#"{"temperature":0.2,"top_p":0.9}"#.utf8)
        func make(_ alias: String, options: [String: JSONValue], raw: Data, order: (String, String)) throws -> DurableRecord {
            let p1 = try Self.profile(alias: order.0)
            let p2 = try Self.profile(alias: order.1)
            var profiles = [p1.alias: p1, p2.alias: p2]
            // Rebuild the chosen profile with this option ordering.
            let chosen = try ModelProfile(
                alias: alias, wireProtocol: .openAIChatCompletions,
                baseURL: "http://127.0.0.1:11434", modelID: "qwen2.5-coder-32b",
                contextWindow: 262144, maxOutput: 4096, locality: .local,
                credential: CredentialReference(kind: .env(name: "NT_STORE_KEY")),
                connectTimeout: 10, readIdleTimeout: 300, requestTimeout: 1800,
                maxInFlight: 1, requestOptions: options, requestOptionsRaw: raw)
            profiles[alias] = chosen
            let snapshot = ConfigSnapshot(
                version: 1, profiles: profiles, defaultAlias: alias,
                allowHTTPOrigins: ["http://127.0.0.1:11434"], tools: .allDenied)
            return .epochOpened(EpochDescriptor(
                epochID: EpochID("epoch-order"), parentEpochID: nil,
                configSnapshot: snapshot, profile: chosen,
                effectiveCaps: EffectiveCapabilities(tools: .allDenied, route: .localOnly, deniedBy: []),
                route: .allowed(endpoint: "http://127.0.0.1:11434/v1", alias: alias)))
        }
        let insertionOne = try make("a-model", options: optionsA, raw: raw, order: ("a-model", "b-model"))
        let insertionTwo = try make("a-model", options: optionsB, raw: raw, order: ("b-model", "a-model"))
        #expect(insertionOne == insertionTwo, "the two built records must be equal by value")
        let bytesOne = try RecordCodec.encode(insertionOne)
        let bytesTwo = try RecordCodec.encode(insertionTwo)
        #expect(bytesOne == bytesTwo, "insertion order must not leak into the bytes")
        // Golden pin: any encoder change (key order, casing, shape)
        // breaks this equality and must be a conscious decision.
        // Captured verbatim from the encoder on this toolchain
        // (Swift 6.4 synthesized shapes: _0 payloads, {"raw":...} IDs,
        // bare-string raw-value enums) — never hand-authored.
        let golden = #"""
{"epochOpened":{"_0":{"configSnapshot":{"allowHTTPOrigins":["http://127.0.0.1:11434"],"defaultAlias":"a-model","profiles":{"a-model":{"alias":"a-model","baseURL":"http://127.0.0.1:11434","connectTimeout":10,"contextWindow":262144,"credential":{"kind":{"env":{"name":"NT_STORE_KEY"}}},"locality":"local","maxInFlight":1,"maxOutput":4096,"modelID":"qwen2.5-coder-32b","readIdleTimeout":300,"requestOptions":{"temperature":0.2,"top_p":0.9},"requestOptionsRaw":"eyJ0ZW1wZXJhdHVyZSI6MC4yLCJ0b3BfcCI6MC45fQ==","requestTimeout":1800,"unqualifiedOptions":[],"wireProtocol":"openai-chat-completions"},"b-model":{"alias":"b-model","baseURL":"http://127.0.0.1:11434","connectTimeout":10,"contextWindow":262144,"credential":{"kind":{"env":{"name":"NT_STORE_KEY"}}},"locality":"local","maxInFlight":1,"maxOutput":4096,"modelID":"qwen2.5-coder-32b","readIdleTimeout":300,"requestOptions":{"temperature":0.2},"requestOptionsRaw":"eyJ0ZW1wZXJhdHVyZSI6MC4yfQ==","requestTimeout":1800,"unqualifiedOptions":[],"wireProtocol":"openai-chat-completions"}},"tools":{"consult":false,"edit":false,"exec":"denied","read":false,"search":false,"write":false},"version":1},"effectiveCaps":{"deniedBy":[],"route":"localOnly","tools":{"consult":false,"edit":false,"exec":"denied","read":false,"search":false,"write":false}},"epochID":{"raw":"epoch-order"},"execComposed":false,"profile":{"alias":"a-model","baseURL":"http://127.0.0.1:11434","connectTimeout":10,"contextWindow":262144,"credential":{"kind":{"env":{"name":"NT_STORE_KEY"}}},"locality":"local","maxInFlight":1,"maxOutput":4096,"modelID":"qwen2.5-coder-32b","readIdleTimeout":300,"requestOptions":{"temperature":0.2,"top_p":0.9},"requestOptionsRaw":"eyJ0ZW1wZXJhdHVyZSI6MC4yLCJ0b3BfcCI6MC45fQ==","requestTimeout":1800,"unqualifiedOptions":[],"wireProtocol":"openai-chat-completions"},"route":{"allowed":{"alias":"a-model","endpoint":"http://127.0.0.1:11434/v1"}}}}}
"""#;
        #expect(String(data: bytesOne, encoding: .utf8) == golden,
                "golden bytes drifted — an encoder change must be a conscious decision")
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

    @Test("pre-D0 acknowledgment rows without queueEntryIDs still decode")
    func decodeLegacyAcknowledgmentWithoutQueueEntryIDs() throws {
        // Backward compatibility: synthesized Codable omits nil optionals,
        // so a pre-D0 row (no such key) is byte-identical to a new row
        // with nil queueEntryIDs — decoding either must yield nil.
        let ack = Acknowledgment(
            subjectSessions: [SessionID("s-old")],
            operationIDs: [OperationID("eo/c1")],
            determination: "operator-accepted-risk", atMillis: 4242)
        let full = String(decoding: try RecordCodec.encode(.acknowledgedUnresolved(ack)), as: UTF8.self)
        #expect(!full.contains("queueEntryIDs"), "nil queueEntryIDs writes no key — old and new rows match")
        let decoded = try RecordCodec.decode(Data(full.utf8))
        #expect(decoded == .acknowledgedUnresolved(ack), "nil round-trips losslessly")
        // Non-nil values round-trip with the key present.
        let withQ = Acknowledgment(
            subjectSessions: [SessionID("s-old")],
            operationIDs: [OperationID("eo/c1")],
            determination: "operator-accepted-risk", atMillis: 4242,
            queueEntryIDs: ["q-9"])
        let back = try RecordCodec.decode(try RecordCodec.encode(.acknowledgedUnresolved(withQ)))
        #expect(back == .acknowledgedUnresolved(withQ), "queue entry IDs round-trip")
    }

    @Test("pre-D1 queue rows without attachment keys still decode")
    func decodeLegacyQueueEntryWithoutAttachments() throws {
        // Backward compatibility: a D0-era row (no `attachments` /
        // `attachmentConsentEpoch` keys — stripped here to simulate the
        // old writer) decodes with empty snapshots and nil consent; new
        // rows round-trip with snapshots preserved.
        let bare = QueueEntry(
            entryID: "q-old", commandID: CommandID("cmd-old"), kind: .followUp,
            state: .queued, revision: 1, text: "old text",
            targetEpochID: EpochID("epoch-1"), orderKey: 7, sealed: false)
        let encoded = try RecordCodec.encode(.queueAdmitted(bare))
        var outer = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        // The associated-value wrapper nests the entry one level deeper.
        func strip(_ dict: [String: Any]) -> [String: Any] {
            var dict = dict
            dict.removeValue(forKey: "attachments")
            dict.removeValue(forKey: "attachmentConsentEpoch")
            for (key, value) in dict {
                if let nested = value as? [String: Any] {
                    dict[key] = strip(nested)
                }
            }
            return dict
        }
        outer["queueAdmitted"] = strip(try #require(outer["queueAdmitted"] as? [String: Any]))
        let legacy = try JSONSerialization.data(withJSONObject: outer, options: [.sortedKeys])
        let decoded = try RecordCodec.decode(legacy)
        guard case .queueAdmitted(let entry) = decoded else {
            Issue.record("legacy row must decode as queueAdmitted"); return
        }
        #expect(entry.attachments.isEmpty, "missing key defaults to no snapshots")
        #expect(entry.attachmentConsentEpoch == nil, "missing key defaults to no consent")
        #expect(entry.text == "old text", "other fields intact")
        // Snapshot-bearing rows round-trip exactly.
        let snap = AttachmentSnapshot(
            path: "n.txt", grantedRoot: "workspace", device: 1, inode: 2,
            size: 3, contentHash: "h", lineRange: AttachmentLineRange(start: 1, end: 1),
            totalLines: 1, content: .included(excerpt: "x\n", truncated: false),
            captureEpochID: EpochID("epoch-1"),
            routeGrant: AttachmentRouteGrant(alias: "a", locality: .local, sealed: false),
            intent: "mention")
        let fresh = QueueEntry(
            entryID: "q-new", commandID: CommandID("cmd-new"), kind: .steer,
            state: .held, revision: 2, text: "new", targetEpochID: EpochID("epoch-1"),
            orderKey: 9, sealed: false, attachments: [snap],
            attachmentConsentEpoch: EpochID("epoch-1"))
        let back = try RecordCodec.decode(try RecordCodec.encode(.queueUpdated(fresh)))
        #expect(back == .queueUpdated(fresh), "snapshots + consent round-trip")
    }

    @Test("encoded rows never carry derived origin/pathPrefix; decode re-derives them")
    func derivedFieldsAreNeverEncoded() throws {
        let record = try Self.allCases()[1] // epochOpened with a full snapshot
        let json = String(data: try RecordCodec.encode(record), encoding: .utf8)!
        #expect(!json.contains("\"origin\""), "derived origin must never be encoded")
        #expect(!json.contains("\"pathPrefix\""), "derived pathPrefix must never be encoded")
        // Positive oracle: decoding re-derives the origin from baseURL.
        guard case .epochOpened(let descriptor) = try RecordCodec.decode(try RecordCodec.encode(record)) else {
            Issue.record("expected epochOpened"); return
        }
        #expect(descriptor.profile.origin == "http://127.0.0.1:11434",
                "origin must be re-derived from baseURL, got \(descriptor.profile.origin)")
        #expect(descriptor.profile.pathPrefix == "")
    }

    @Test("record codec refuses a semantically invalid profile row (validating decode)")
    func decodeRefusesInvalidProfileRow() throws {
        // Build the tampered row from REAL encoded bytes (the synthesized
        // wire format is an implementation detail we must not hand-guess):
        // flip contextWindow to an out-of-range value in BOTH copies of the
        // profile (configSnapshot.profiles and the top-level profile). The
        // VALIDATING init must reject the row — synthesized decoding would
        // assign -5 silently. A structural-JSON failure would also throw,
        // so the RED probe for this oracle swaps the custom conformance for
        // synthesized Codable and expects THIS test to fail.
        let record = try Self.allCases()[1]
        var object = try JSONSerialization.jsonObject(
            with: RecordCodec.encode(record)) as! [String: Any]
        // The synthesized shape wraps a single associated value under "_0".
        guard var payload = object["epochOpened"] as? [String: Any],
              var inner = payload["_0"] as? [String: Any],
              var snapshot = inner["configSnapshot"] as? [String: Any],
              var profiles = snapshot["profiles"] as? [String: Any],
              var topProfile = inner["profile"] as? [String: Any] else {
            Issue.record("unexpected encoded shape"); return
        }
        for (alias, anyProfile) in profiles {
            guard var profile = anyProfile as? [String: Any] else {
                Issue.record("unexpected profile shape"); return
            }
            profile["contextWindow"] = -5
            profiles[alias] = profile
        }
        topProfile["contextWindow"] = -5
        snapshot["profiles"] = profiles
        inner["configSnapshot"] = snapshot
        inner["profile"] = topProfile
        payload["_0"] = inner
        object["epochOpened"] = payload
        let tampered = try JSONSerialization.data(withJSONObject: object)

        do {
            _ = try RecordCodec.decode(tampered)
            Issue.record("an out-of-range profile row must fail the decode, not decode silently")
        } catch let error as StoreError {
            guard case .integrity(let message) = error else {
                Issue.record("expected .integrity, got \(error)"); return
            }
            #expect(message.contains("context_window"),
                    "failure must come from the validating init, got: \(message)")
        } catch {
            Issue.record("expected StoreError.integrity, got \(error)"); return
        }
    }
}
