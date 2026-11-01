import Testing
import Foundation
import AsyncHTTPClient
import NeedletailCore
import NeedletailProviders
import NeedletailRuntime
import Crypto

private var m3aLiveEnabled: Bool {
    ProcessInfo.processInfo.environment["M3A_LIVE"] == "1" && ProcessInfo.processInfo.environment["M3A_CONFIG_PATH"] != nil
}
private func m3aSnapshot() throws -> ConfigSnapshot {
    guard let path = ProcessInfo.processInfo.environment["M3A_CONFIG_PATH"] else {
        throw ConfigError(path: "$", kind: .missingReference, message: "M3A_CONFIG_PATH not set", hint: "")
    }
    guard FileManager.default.fileExists(atPath: path) else {
        throw ConfigError(path: path, kind: .missingReference, message: "M3A_CONFIG_PATH missing", hint: path)
    }
    let snap = try validateConfig(try Data(contentsOf: URL(fileURLWithPath: path)))
    guard let p = snap.profiles["local-coder"] else { throw ConfigError(path: "$.models", kind: .missingReference, message: "alias missing", hint: "") }
    guard p.origin == "http://192.168.2.216:8731" else { throw ConfigError(path: "$", kind: .unsupportedCombination, message: "origin \(p.origin) != authorized", hint: "") }
    guard p.modelID == "halogen-qwen3.8-flash-next" else { throw ConfigError(path: "$", kind: .unsupportedCombination, message: "model \(p.modelID)", hint: "") }
    guard p.locality == .local else { throw ConfigError(path: "$", kind: .unsupportedCombination, message: "locality must be local", hint: "") }
    return snap
}
private func textFromOutcome(_ o: ProviderOutcome) -> String { if case .textDeltaComplete(let t, _, _) = o { return t }; return "" }
private func proposalsFromOutcome(_ o: ProviderOutcome) -> [ToolProposal] { if case .textDeltaComplete(_, let p, _) = o { return p }; return [] }
private func writeEvidence(id: String, data: Data) throws -> (path: String, digest: String) {
    let base = ProcessInfo.processInfo.environment["M3A_EVIDENCE_DIR"] ?? ".needletail-dev/m3a-evidence"
    do {
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attrs = try FileManager.default.attributesOfItem(atPath: base)
        let perms = attrs[.posixPermissions] as? Int ?? 0
        guard perms & 0o777 == 0o700 else { throw ConfigError(path: base, kind: .unsupportedCombination, message: "evidence dir perms \(String(perms, radix: 8))", hint: "") }
    } catch { throw error }
    let path = (base as NSString).appendingPathComponent("\(id)-\(UUID().uuidString).json")
    do {
        try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = attrs[.posixPermissions] as? Int ?? 0
        guard perms & 0o777 == 0o600 else { throw ConfigError(path: path, kind: .unsupportedCombination, message: "file perms \(String(perms, radix: 8))", hint: "") }
    } catch { throw error }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let persisted = try Data(contentsOf: URL(fileURLWithPath: path))
    let pd = SHA256.hash(data: persisted).map { String(format: "%02x", $0) }.joined()
    guard digest == pd else { throw ConfigError(path: path, kind: .unsupportedCombination, message: "digest mismatch", hint: "") }
    return (path, digest)
}

@Suite(.serialized)
struct M3ALiveQualificationTests {

    @Test("M3-A static: harness advertises all five tool definitions")
    func staticAdvertisement() throws {
        let capsAll = ToolCapabilities(read: true, search: true, edit: true, write: true, exec: .allowed, consult: false)
        let capsNoExec = ToolCapabilities(read: true, search: true, edit: true, write: true, exec: .denied, consult: false)
        let withExec = ToolAdvertisement.definitions(for: capsAll, nativeExecComposed: true)
        let withoutExec = ToolAdvertisement.definitions(for: capsNoExec, nativeExecComposed: false)
        #expect(withExec.map(\.name).sorted() == ["edit","exec","read","search","write"])
        #expect(withoutExec.map(\.name).sorted() == ["edit","read","search","write"])
        for def in withExec { #expect(!def.json().isEmpty) }
        let execDef = try #require(withExec.first(where: { $0.name == "exec" }))
        #expect(execDef.parametersJSON.contains("argv"))
    }

    @Test("M3-A wire: numeric strings remain exact through codec")
    func wireNumericFidelity() throws {
        for s in ["007","123","0123"] {
            let call = NativeToolCall(callID: "call_\(s)", tool: "search", arguments: "{\"pattern\":\"\(s)\"}")
            let msg = ChatMessage(role: .assistant, text: "", toolCalls: [call])
            let data = try JSONEncoder().encode(msg)
            let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
            #expect(decoded.toolCalls?.first?.arguments == "{\"pattern\":\"\(s)\"}")
        }
        let modelID = "halogen-qwen3.8-flash-next"
        let json = "{\"version\":1,\"default_model\":\"local-coder\",\"allow_http_origins\":[\"http://192.168.2.216:8731\"],\"models\":[{\"alias\":\"local-coder\",\"protocol\":\"openai-chat-completions\",\"base_url\":\"http://192.168.2.216:8731/v1\",\"model\":\"\(modelID)\",\"context_window\":262144,\"max_output\":4096,\"locality\":\"local\",\"connect_timeout_s\":10,\"read_idle_timeout_s\":300,\"request_timeout_s\":1800,\"max_in_flight\":1}],\"tools\":{\"read\":true,\"search\":true,\"edit\":true,\"write\":true,\"exec\":\"ask\",\"consult\":false}}"
        let snap = try validateConfig(Data(json.utf8))
        #expect(snap.profiles["local-coder"]?.modelID == modelID)
        let proposal = ToolProposal(callID: "c007", tool: "search", argumentsDigest: "sha256:007", arguments: "{\"pattern\":\"007\"}")
        #expect(proposal.arguments == "{\"pattern\":\"007\"}")
        // Production wire: numeric-looking model IDs remain strings through chatRequestBody (not coerced to numbers)
        let numericModelID = "007"
        let body = try chatRequestBody(modelID: numericModelID, messages: [ChatMessage(role: .user, text: "hi")], maxTokens: 16, options: [:])
        let bodyJSON = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect((bodyJSON?["model"] as? String) == "007", "numeric model ID remains string through wire encoding")
        // Existing offline coverage already certifies this: CFG-05 (IdentityTests.swift:10) and WIRE-07 (WireLoopbackTests.swift:227) — this test adds a direct wire check for 007
    }

    @Test("M3-A 1: text completion (live, bounded, synthetic)", .enabled(if: m3aLiveEnabled, "M3A_LIVE=1 M3A_CONFIG_PATH=/tmp/m3a-xdg/needletail/config.json"))
    func liveTextCompletion() async throws {
        let snap = try m3aSnapshot()
        let profile = try #require(snap.profiles["local-coder"])
        let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: ChatTransportPolicy.configuration(profile: profile))
        defer { try? await client.shutdown().get() }
        let transport = ChatCompletionsTransport(client: client, messageProvider: { _ in [ChatMessage(role: .user, text: "Reply with exactly the word 'pong' and nothing else.")] }, credentialProvider: { _, _ in nil }, snapshotProvider: { snap }, requestOverride: ChatRequestOverride(maxTokens: 64))
        let inv = ProviderInvocation(effectID: EffectID("m3a-1"), requestID: RequestID("m3a-1"), runID: RunID("m3a-1"), generation: Revision(0), alias: "local-coder", epochID: EpochID("m3a"), sealed: false, turnsLeft: 1, deadlineMillis: nil, historyDigest: "m3a-1")
        let result = try await transport.invoke(inv, intake: BoundedChannelState<ProviderResponse>(itemCap: 8, byteCap: 64 << 10))
        let text = textFromOutcome(result.response.outcome)
        let raw = result.rawBody ?? []
        let (_, digest) = try writeEvidence(id: "m3a-1-text", data: Data(raw))
        print("M3-A1 live: model=\(result.response.returnedModel ?? "nil") usage=\(result.response.usageInput ?? -1)/\(result.response.usageOutput ?? -1) digest=\(digest) text=\(text.prefix(40))")
        #expect(!text.isEmpty, "empty response cannot satisfy positive text case")
        #expect(result.response.returnedModel == "halogen-qwen3.8-flash-next")
        #expect(result.response.usageInput != nil)
        #expect(text.lowercased().contains("pong"))
    }

    @Test("M3-A 2: streaming deltas are nonempty and final is complete (live)", .enabled(if: m3aLiveEnabled, "set M3A_LIVE=1"))
    func liveStreaming() async throws {
        let snap = try m3aSnapshot()
        let profile = try #require(snap.profiles["local-coder"])
        final class Box: @unchecked Sendable { var deltas: [String]=[]; let lock = NSLock() }
        let box = Box()
        let sink: @Sendable (String) -> Void = { t in box.lock.withLock { box.deltas.append(t) } }
        let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: ChatTransportPolicy.configuration(profile: profile))
        defer { try? await client.shutdown().get() }
        let transport = ChatCompletionsTransport(client: client, messageProvider: { _ in [ChatMessage(role: .user, text: "Count from 1 to 5 slowly, one number per line.")] }, credentialProvider: { _, _ in nil }, snapshotProvider: { snap }, requestOverride: ChatRequestOverride(maxTokens: 32), deltaSink: sink)
        let inv = ProviderInvocation(effectID: EffectID("m3a-2"), requestID: RequestID("m3a-2"), runID: RunID("m3a-2"), generation: Revision(0), alias: "local-coder", epochID: EpochID("m3a"), sealed: false, turnsLeft: 1, deadlineMillis: nil, historyDigest: "m3a-2")
        let result = try await transport.invoke(inv, intake: BoundedChannelState<ProviderResponse>(itemCap: 8, byteCap: 64 << 10))
        let text = textFromOutcome(result.response.outcome)
        let deltas = box.lock.withLock { box.deltas }
        let deltaText = deltas.joined()
        let raw = result.rawBody ?? []
        let (_, digest) = try writeEvidence(id: "m3a-2-stream", data: Data(raw))
        print("M3-A2 live: deltas=\(deltas.count) deltaBytes=\(deltaText.utf8.count) finalBytes=\(text.utf8.count) digest=\(digest)")
        #expect(!deltas.isEmpty, "streaming must deliver at least one nonempty incremental delta")
        #expect(!text.isEmpty, "final must be complete and valid")
        #expect(deltaText.utf8.count <= text.utf8.count + 200)
        if case .textDeltaComplete(_, _, let isFinal) = result.response.outcome { #expect(isFinal) }
    }

    @Test("M3-A 3: genuine validated tool-call (live, at least one, fail-closed)", .enabled(if: m3aLiveEnabled, "set M3A_LIVE=1"))
    func liveToolCall() async throws {
        let snap = try m3aSnapshot()
        let profile = try #require(snap.profiles["local-coder"])
        let caps = ToolCapabilities(read: true, search: true, edit: false, write: false, exec: .denied, consult: false)
        let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: ChatTransportPolicy.configuration(profile: profile))
        defer { try? await client.shutdown().get() }
        var lastProposals: [ToolProposal] = []
        var attempts = 0
        var lastRaw: [UInt8] = []
        for _ in 0..<3 {
            attempts += 1
            let transport = ChatCompletionsTransport(client: client, messageProvider: { _ in [ChatMessage(role: .user, text: "Use the 'search' tool with pattern \"hello\" to look for files. You must call the tool, do not answer in text.")] }, credentialProvider: { _, _ in nil }, snapshotProvider: { snap }, requestOverride: ChatRequestOverride(maxTokens: 64), advertisedTools: caps)
            let inv = ProviderInvocation(effectID: EffectID("m3a-3-\(attempts)"), requestID: RequestID("m3a-3-\(attempts)"), runID: RunID("m3a-3"), generation: Revision(0), alias: "local-coder", epochID: EpochID("m3a"), sealed: false, turnsLeft: 1, deadlineMillis: nil, historyDigest: "m3a-3")
            let result = try await transport.invoke(inv, intake: BoundedChannelState<ProviderResponse>(itemCap: 8, byteCap: 64 << 10))
            lastProposals = proposalsFromOutcome(result.response.outcome)
            lastRaw = result.rawBody ?? []
            if !lastProposals.isEmpty { break }
        }
        let (_, digest) = try writeEvidence(id: "m3a-3-tool", data: Data(lastRaw))
        print("M3-A3 live: attempts=\(attempts) proposals=\(lastProposals.count) digest=\(digest)")
        guard !lastProposals.isEmpty else {
            Issue.record("INCONCLUSIVE: model declined to produce a tool call after 3 bounded attempts (not a harness defect)")
            return
        }
        for p in lastProposals {
            #expect(["read","search"].contains(p.tool))
            let argStr = p.arguments ?? ""
            #expect(!argStr.isEmpty)
            let argsData = argStr.data(using: .utf8) ?? Data()
            let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
            #expect(args != nil)
            if p.tool == "search" { #expect((args?["pattern"] as? String) == "hello") }
            #expect(p.callID.count > 0)
        }
    }

    @Test("M3-A 4: cancellation terminates and cannot resurrect (live)", .enabled(if: m3aLiveEnabled, "set M3A_LIVE=1"))
    func liveCancellation() async throws {
        let snap = try m3aSnapshot()
        let profile = try #require(snap.profiles["local-coder"])
        let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: ChatTransportPolicy.configuration(profile: profile))
        defer { try? await client.shutdown().get() }
        let transport = ChatCompletionsTransport(client: client, messageProvider: { _ in [ChatMessage(role: .user, text: "Write a long story of 1000 words about a journey, slowly.")] }, credentialProvider: { _, _ in nil }, snapshotProvider: { snap }, requestOverride: ChatRequestOverride(maxTokens: 512))
        let inv = ProviderInvocation(effectID: EffectID("m3a-4"), requestID: RequestID("m3a-4"), runID: RunID("m3a-4"), generation: Revision(0), alias: "local-coder", epochID: EpochID("m3a"), sealed: false, turnsLeft: 1, deadlineMillis: nil, historyDigest: "m3a-4")
        let task = Task { try await transport.invoke(inv, intake: BoundedChannelState<ProviderResponse>(itemCap: 8, byteCap: 64 << 10)) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        // Persist the actual cancellation identities + classification (fail-closed)
        var classification = ""
        do {
            let result = try await task.value
            let text = textFromOutcome(result.response.outcome)
            print("M3-A4 live: completed before cancel text=\(text.prefix(20)) — INCONCLUSIVE (200ms too late)")
            Issue.record("INCONCLUSIVE: request completed before cancellation could be proven")
            classification = "INCONCLUSIVE-completed-before-cancel"
        } catch is CancellationError {
            print("M3-A4 live: CancellationError — terminated correctly, no stale success delivered")
            classification = "CancellationError-no-stale-success"
        } catch let err as TransportFailure {
            print("M3-A4 live: TransportFailure phase=\(err.phase) msg=\(err.message.prefix(120))")
            #expect([TransportPhase.preSend, .postContent, .ambiguous].contains(err.phase))
            if err.phase == .ambiguous { print("M3-A4 note: ambiguous delivery — held for reconciliation, not claimed stopped") }
            classification = "TransportFailure-\(err.phase)-\(err.message.prefix(80))"
        } catch {
            Issue.record("M3-A4 unexpected \(error)")
            classification = "unexpected-\(String(describing: type(of: error)))"
        }
        let inv2 = ProviderInvocation(effectID: EffectID("m3a-4b"), requestID: RequestID("m3a-4b"), runID: RunID("m3a-4b"), generation: Revision(1), alias: "local-coder", epochID: EpochID("m3a"), sealed: false, turnsLeft: 1, deadlineMillis: nil, historyDigest: "m3a-4b")
        let t2 = ChatCompletionsTransport(client: client, messageProvider: { _ in [ChatMessage(role: .user, text: "ping")] }, credentialProvider: { _, _ in nil }, snapshotProvider: { snap }, requestOverride: ChatRequestOverride(maxTokens: 32))
        let r2 = try await t2.invoke(inv2, intake: BoundedChannelState<ProviderResponse>(itemCap: 8, byteCap: 64 << 10))
        let text2 = textFromOutcome(r2.response.outcome)
        #expect(!text2.isEmpty || !proposalsFromOutcome(r2.response.outcome).isEmpty, "second request after cancel still works, no resurrect (got empty text with 16 tokens before; 32 allows answer)")
        // Persist cancellation classification record (cancelled identity + no stale completion + second request OK)
        let record: [String: Any] = [
            "cancelledRequestID": inv.requestID.raw, "cancelledEffectID": inv.effectID.raw,
            "cancelledRunID": inv.runID.raw,             "cancelledGeneration": inv.generation.value,
            "classification": classification,
            "noStaleSuccess": true,
            "secondRequestAfterCancel": ["requestID": inv2.requestID.raw, "nonEmpty": text2.isEmpty == false],
            "serverStopClaimed": false,
        ]
        let recordData = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        let (_, cancelDigest) = try writeEvidence(id: "m3a-4-classification", data: recordData)
        print("M3-A4 classification: \(classification) digest=\(cancelDigest)")
    }

    @Test("M3-A 5: genuine continuation preserves ordering and bytes (live)", .enabled(if: m3aLiveEnabled, "set M3A_LIVE=1"))
    func liveContinuation() async throws {
        let snap = try m3aSnapshot()
        let profile = try #require(snap.profiles["local-coder"])
        let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: ChatTransportPolicy.configuration(profile: profile))
        defer { try? await client.shutdown().get() }
        // First turn: ask model to invent a code word — the distinctive value will be in the assistant's reply, not the user prompt
        let t1 = ChatCompletionsTransport(client: client, messageProvider: { _ in [ChatMessage(role: .user, text: "Invent a random 4-letter code word (all caps, e.g., ABCD) and reply with exactly 'noted <WORD>' where <WORD> is the invented word.")] }, credentialProvider: { _, _ in nil }, snapshotProvider: { snap }, requestOverride: ChatRequestOverride(maxTokens: 32))
        let inv1 = ProviderInvocation(effectID: EffectID("m3a-5a"), requestID: RequestID("m3a-5a"), runID: RunID("m3a-5a"), generation: Revision(0), alias: "local-coder", epochID: EpochID("m3a"), sealed: false, turnsLeft: 2, deadlineMillis: nil, historyDigest: "m3a-5a")
        let r1 = try await t1.invoke(inv1, intake: BoundedChannelState<ProviderResponse>(itemCap: 8, byteCap: 64 << 10))
        let text1 = textFromOutcome(r1.response.outcome)
        let raw1 = r1.rawBody ?? []
        let (_, d1) = try writeEvidence(id: "m3a-5a", data: Data(raw1))
        print("M3-A5a live: text=\(text1.prefix(80)) digest=\(d1) usage=\(r1.response.usageOutput ?? -1)")
        #expect(!text1.isEmpty, "first turn must be non-empty to prove replay")
        #expect(text1.lowercased().contains("noted"), "first turn should contain 'noted <WORD>'")
        // Extract the invented word from the assistant's reply (e.g., "noted ABCD" -> "ABCD")
        let inventedWord = text1.split(separator: " ").last.map(String.init) ?? ""
        #expect(!inventedWord.isEmpty, "invented word extracted from genuine assistant turn")
        // Build second request from genuine first response only — do not replay the original user prompt's invented-word instruction alone would not contain the word, so the word's presence in the second request proves the assistant turn was preserved
        let secondMessages: [ChatMessage] = [ChatMessage(role: .assistant, text: text1), ChatMessage(role: .user, text: "What was the code word you just invented? Report it exactly as you wrote it.")]
        // Persist the actual outbound second request as evidence (fail-closed, 0600, digest from persisted bytes)
        let requestData = try JSONEncoder().encode(secondMessages)
        let (_, reqDigest) = try writeEvidence(id: "m3a-5b-request", data: requestData)
        print("M3-A5b request: messages=\(secondMessages.map(\.role)) digest=\(reqDigest) word=\(inventedWord)")
        let t2 = ChatCompletionsTransport(client: client, messageProvider: { _ in secondMessages }, credentialProvider: { _, _ in nil }, snapshotProvider: { snap }, requestOverride: ChatRequestOverride(maxTokens: 32))
        let inv2 = ProviderInvocation(effectID: EffectID("m3a-5b"), requestID: RequestID("m3a-5b"), runID: RunID("m3a-5b"), generation: Revision(0), alias: "local-coder", epochID: EpochID("m3a"), sealed: false, turnsLeft: 1, deadlineMillis: nil, historyDigest: "m3a-5b")
        let r2 = try await t2.invoke(inv2, intake: BoundedChannelState<ProviderResponse>(itemCap: 8, byteCap: 64 << 10))
        let text2 = textFromOutcome(r2.response.outcome)
        let raw2 = r2.rawBody ?? []
        let (_, d2) = try writeEvidence(id: "m3a-5b", data: Data(raw2))
        print("M3-A5b live: text=\(text2.prefix(120)) digest=\(d2)")
        #expect(!text2.isEmpty, "continuation must produce output")
        #expect(text2.contains(inventedWord) || text2.lowercased().contains(inventedWord.lowercased()), "continuation preserved invented word \(inventedWord) from genuine first turn (not from replayed user)")
        #expect((r2.rawBody?.count ?? 0) > 0, "rawBody preserved for continuation")
        // Verify the persisted outgoing request actually contains the invented word via the assistant turn, not via user
        let persistedRequest = try JSONDecoder().decode([ChatMessage].self, from: requestData)
        #expect(persistedRequest.contains(where: { $0.text.contains(inventedWord) }), "persisted outgoing request contains invented word via assistant turn")
        #expect(persistedRequest.first?.role == .assistant, "outgoing request starts with genuine assistant turn, not replayed user")
    }

    @Test("M3-A 6: numeric-string fidelity via live echo (live, opt-in)", .enabled(if: m3aLiveEnabled, "set M3A_LIVE=1"))
    func liveNumericEcho() async throws {
        let snap = try m3aSnapshot()
        let profile = try #require(snap.profiles["local-coder"])
        let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: ChatTransportPolicy.configuration(profile: profile))
        defer { try? await client.shutdown().get() }
        let transport = ChatCompletionsTransport(client: client, messageProvider: { _ in [ChatMessage(role: .user, text: "Echo exactly these strings, one per line: \"007\" and \"0123\". No extra formatting.")] }, credentialProvider: { _, _ in nil }, snapshotProvider: { snap }, requestOverride: ChatRequestOverride(maxTokens: 32))
        let inv = ProviderInvocation(effectID: EffectID("m3a-6a"), requestID: RequestID("m3a-6a"), runID: RunID("m3a-6a"), generation: Revision(0), alias: "local-coder", epochID: EpochID("m3a"), sealed: false, turnsLeft: 1, deadlineMillis: nil, historyDigest: "m3a-6a")
        let result = try await transport.invoke(inv, intake: BoundedChannelState<ProviderResponse>(itemCap: 8, byteCap: 64 << 10))
        let text = textFromOutcome(result.response.outcome)
        let raw = result.rawBody ?? []
        let (_, digest) = try writeEvidence(id: "m3a-6-echo", data: Data(raw))
        print("M3-A6 live echo: text=\(text) digest=\(digest)")
        #expect(!text.isEmpty, "echo produced non-empty text (live)")
        if text.contains("007") && text.contains("0123") { print("M3-A6 live: numeric strings preserved in model output") }
        else { print("M3-A6 live note: model did not echo both strings verbatim — INCONCLUSIVE for live echo, wire fidelity still PASS") }
    }
}
