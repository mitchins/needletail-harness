import Testing
import Foundation
import NeedletailCore
import NeedletailProviders
import NeedletailTestSupport

/// DX-04/05 over loopback: the operator probe path end to end. Given a
/// configured alias and a fixed-credential store, when probing, then the
/// returned record carries endpoint/model/usage and the captured packet is
/// fixed literals only. Secrets travel the wire but never enter
/// descriptions, errors, or logs.
///
/// Serialized: same rationale as WireLoopbackTests (parallel-only
/// ECONNREFUSED flake in test-support lifecycle, owned by M1C3-3).
@Suite(.serialized)
struct DXLoopbackTests {
    struct FixedCredentialStore: CredentialStore, Sendable {
        let secret: String
        func resolve(_ reference: CredentialReference, for operation: String) throws -> String {
            secret
        }
    }

    @Test("DX-04 probe returns endpoint, models and usage over one connection")
    func DX_04_probeRecord() async throws {
        let server = try LoopbackSSEServer()
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(CannedTurn.text("probe ok").utf8))]))
        server.start()
        defer { server.stop() }
        // Profile carries operator options AND a large budget: neither may
        // move the probe packet (max_tokens 16, no options — R9).
        let snapshot = try LoopbackFixtures.snapshot(
            alias: "loop", baseURL: server.baseURL,
            requestOptions: "{\"temperature\":0.9,\"top_p\":0.5}")
        let result = try await probeRoute(
            snapshot: snapshot, alias: "loop",
            credentialStore: FixedCredentialStore(secret: "loopback-test-secret"))
        #expect(result.endpoint == "\(server.baseURL)/chat/completions", "authorized endpoint echoed")
        #expect(result.configuredModel == "test-model", "configured model echoed")
        #expect(result.returnedModel == "test-model", "served model passed through exactly")
        #expect(result.usageInput == 5 && result.usageOutput == 2, "usage passed through, never estimated")
        #expect(result.elapsedMillis < 60_000, "probe is a liveness check, bounded")
        #expect(server.connectionCount == 1, "single flight: no retry, no discovery")
        // Traffic half of NET-06: the packet is fixed literals, never
        // session/history/workspace bytes.
        let sent = try #require(server.requests.first, "probe must send exactly one packet")
        let body = String(decoding: sent.body, as: UTF8.self)
        #expect(body.contains("probe ping"), "synthetic packet on the wire")
        #expect(!body.contains("synthetic probe input"), "session messages never leak into the probe")
        #expect(sent.header("authorization") == "Bearer loopback-test-secret", "credential resolved per-operation")
        #expect(sent.path == "/chat/completions", "exact path, no query")
        // R9 fixed packet, byte-exact on the captured wire bytes (not the
        // dead helper the pure test used to cover): profile budgets and
        // operator options must not move these bytes.
        let packet = try JSONSerialization.jsonObject(with: Data(sent.body)) as! [String: Any]
        #expect(packet["max_tokens"] as? Int == ProbePacket.maxTokens, "probe output bound, not profile max_output")
        #expect(packet["temperature"] == nil, "operator options never ride the probe: \(packet.keys.sorted())")
        #expect(sent.body.count <= ProbePacket.bodyByteCap, "whole probe packet fits 4 KiB")
        let wireMessages = (packet["messages"] as! [[String: Any]]).map { $0["content"] as! String }
        #expect(wireMessages == ["needletail probe", "probe ping"], "fixed literals only: \(wireMessages)")
    }

    @Test("DX-04 probe against a refused alias fails before any traffic")
    func DX_04_probeRefusedPreDial() async throws {
        let server = try LoopbackSSEServer()
        server.start()
        defer { server.stop() }
        let snapshot = try LoopbackFixtures.snapshot(alias: "loop", baseURL: server.baseURL)
        // Unknown alias is a CONFIG error (missing reference), not a
        // transport verdict — still pre-dial, still zero traffic.
        do {
            _ = try await probeRoute(
                snapshot: snapshot, alias: "ghost",
                credentialStore: FixedCredentialStore(secret: "loopback-test-secret"))
            Issue.record("unknown alias must refuse")
        } catch let config as ConfigError {
            #expect(config.kind == .missingReference, "typed config refusal: \(config)")
        } catch {
            Issue.record("wrong error class: \(error)")
        }
        #expect(server.requests.isEmpty, "refused probe sends nothing")
    }

    @Test("DX-05 secrets never enter descriptions, errors, or redacted renders")
    func DX_05_redactionEverywhere() async throws {
        let server = try LoopbackSSEServer()
        server.enqueue(SSEScript(status: 401, headers: [("Content-Type", "text/event-stream")], chunks: []))
        server.start()
        defer { server.stop() }
        let snapshot = try LoopbackFixtures.snapshot(alias: "loop", baseURL: server.baseURL)
        // Snapshot and profile renders carry no secret bytes.
        #expect(!snapshot.redactedDescription.contains("loopback-test-secret"), "snapshot render is secret-free")
        #expect(!snapshot.profiles["loop"]!.redactedDescription.contains("loopback-test-secret"),
                "profile render is secret-free")
        // Failure paths carry status and typing, never the credential.
        do {
            _ = try await probeRoute(
                snapshot: snapshot, alias: "loop",
                credentialStore: FixedCredentialStore(secret: "loopback-test-secret"))
            Issue.record("401 probe must fail")
        } catch {
            let text = String(describing: error)
            #expect(!text.contains("loopback-test-secret"), "errors never echo credentials: \(text)")
            #expect(text.contains("401"), "status preserved while secret withheld: \(text)")
        }
        // The wire still carried the credential (redaction is display-side).
        let sent = try #require(server.requests.first)
        #expect(sent.header("authorization") == "Bearer loopback-test-secret", "wire intact")
    }
}
