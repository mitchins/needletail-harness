import Testing
import Foundation
import AsyncHTTPClient
import NeedletailCore
import NeedletailProviders
import NeedletailTestSupport
#if canImport(Glibc)
import Glibc
#endif

/// NET-02..05 over the REAL adapter + loopback HTTP. Given refusal and
/// failure scripts, when the production transport runs, then every failure
/// is typed with the correct retry phase and nothing retries, follows, or
/// dials before authorization. Forbidden: retries, backoff sleeps,
/// redirect-following, proxy use, pre-authorization traffic.
///
/// Serialized: same rationale as WireLoopbackTests (parallel-only
/// ECONNREFUSED flake in test-support lifecycle, owned by M1C3-3).
@Suite(.serialized)
struct NetLoopbackTests {

    private static func invoke(
        server: LoopbackSSEServer, alias: String = "loop",
        invocationAlias: String? = nil,
        credential: String? = nil,
        connectTimeout: Int = 5, readIdleTimeout: Int = 10, requestTimeout: Int = 60
    ) async throws -> (response: ProviderResponse, requests: [CapturedRequest], connections: Int) {
        let (transport, _) = try LoopbackFixtures.transport(
            server: server, alias: alias, credential: credential,
            connectTimeout: connectTimeout, readIdleTimeout: readIdleTimeout,
            requestTimeout: requestTimeout)
        // Unwind-safe: a throwing invoke must still drain the client or
        // AHC traps on un-shut-down deinit and masks the real failure.
        defer { await LoopbackFixtures.shutdown(transport.client) }
        let result = try await transport.invoke(
            LoopbackFixtures.invocation(alias: invocationAlias ?? alias),
            intake: BoundedChannelState<ProviderResponse>(itemCap: 8, byteCap: 64 << 10))
        return (result.response, server.requests, server.connectionCount)
    }

    @Test("NET-02a unknown alias and stripped allow-list refuse with zero traffic")
    func NET_02a_refuseBeforeDial() async throws {
        let server = try LoopbackSSEServer()
        server.start()
        defer { server.stop() }
        // Unknown alias: no profile, no destination, no dial. The transport
        // is built against the valid profile; only the INVOCATION names the
        // ghost, so authorization (not fixture setup) is what refuses.
        do {
            _ = try await Self.invoke(server: server, alias: "loop", invocationAlias: "ghost")
            Issue.record("unknown alias must refuse")
        } catch let failure as TransportFailure {
            #expect(failure.phase == .preSend, "nothing left the process: \(failure)")
        } catch {
            Issue.record("wrong error class: \(error)")
        }
        // Tampered snapshot: origin dropped from the allow-list after issue.
        // The CURRENT snapshot at dispatch decides (never a cached route).
        let base = try LoopbackFixtures.snapshot(alias: "loop", baseURL: server.baseURL)
        let stripped = ConfigSnapshot(
            version: base.version, profiles: base.profiles, defaultAlias: base.defaultAlias,
            allowHTTPOrigins: [], tools: base.tools)
        let profile = try #require(stripped.profiles["loop"])
        let client = LoopbackFixtures.client(profile: profile)
        let transport = ChatCompletionsTransport(
            client: client,
            messageProvider: { _ in [ChatMessage(role: .user, text: "x")] },
            credentialProvider: { _, _ in "loopback-test-secret" },
            snapshotProvider: { stripped })
        do {
            _ = try await transport.invoke(
                LoopbackFixtures.invocation(alias: "loop"),
                intake: BoundedChannelState<ProviderResponse>(itemCap: 8, byteCap: 64 << 10))
            Issue.record("stripped allow-list must refuse")
        } catch let failure as TransportFailure {
            #expect(failure.phase == .preSend, "nothing left the process: \(failure)")
        } catch {
            Issue.record("wrong error class: \(error)")
        }
        await LoopbackFixtures.shutdown(client)
        #expect(server.requests.isEmpty, "authorize-before-dial: zero bytes sent")
        #expect(server.connectionCount == 0, "no connection was opened")
    }

    @Test("NET-02b redirect to an outside origin is refused and never followed")
    func NET_02b_redirectNeverFollowed() async throws {
        let server = try LoopbackSSEServer()
        // External TEST-NET destination: following it would leave loopback.
        server.enqueue(.redirect(to: "http://203.0.113.9:9/evil"))
        server.start()
        defer { server.stop() }
        do {
            _ = try await Self.invoke(server: server)
            Issue.record("redirect must refuse")
        } catch let failure as TransportFailure {
            #expect(failure.phase == .postContent, "head arrived, body refused: \(failure)")
            #expect(failure.message.contains("redirectRefused"), "typed redirect refusal: \(failure.message)")
        } catch {
            Issue.record("wrong error class: \(error)")
        }
        #expect(server.connectionCount == 1, "exactly one request: no follow-up dial")
        let sent = try #require(server.requests.first)
        #expect(sent.path == "/chat/completions", "exact endpoint path, no query: \(sent.path)")
    }

    @Test("NET-03 hostile proxy env ignored; https refusal typed preSend")
    func NET_03_hostileEnvIgnored() async throws {
        // Every proxy variable a client could conceivably honor points at a
        // blackhole. AsyncHTTPClient reads proxy ONLY from its configuration
        // (verified: no getenv/proxy lookup in its sources); this test pins
        // that the environment can never divert or observe traffic.
        let hostile = ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"]
        var saved: [String: String?] = [:]
        for key in hostile {
            saved[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, "http://203.0.113.9:9/", 1)
        }
        defer {
            for (key, value) in saved {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        // (a) Loopback still succeeds direct: the server saw the request.
        let server = try LoopbackSSEServer()
        server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: Array(CannedTurn.text("direct").utf8))]))
        server.start()
        defer { server.stop() }
        let run = try await Self.invoke(server: server)
        guard case .textDeltaComplete(let text, _, _) = run.response.outcome else {
            Issue.record("direct loopback must succeed, got \(run.response.outcome)"); return
        }
        #expect(text == "direct")
        #expect(run.connections == 1, "one direct connection: no proxy, no retry")
        // (b) https against the plaintext loopback fails the TLS handshake
        // with a TYPED preSend verdict — never raw NIO noise, never an http
        // fallback, never a retry. (No dedicated self-signed-cert fixture:
        // the classification path is identical — handshake failure before
        // any head byte — so it would pin no new behavior. See report.)
        let tlsServer = try LoopbackSSEServer()
        tlsServer.start()
        defer { tlsServer.stop() }
        let httpsBase = tlsServer.baseURL.replacingOccurrences(of: "http://", with: "https://")
        let snapshot = try LoopbackFixtures.snapshot(
            alias: "tls", baseURL: httpsBase,
            connectTimeout: 2, readIdleTimeout: 2, requestTimeout: 60)
        let profile = try #require(snapshot.profiles["tls"])
        let client = LoopbackFixtures.client(profile: profile)
        defer { await LoopbackFixtures.shutdown(client) }
        let transport = ChatCompletionsTransport(
            client: client,
            messageProvider: { _ in [ChatMessage(role: .user, text: "x")] },
            credentialProvider: { _, _ in "loopback-test-secret" },
            snapshotProvider: { snapshot })
        do {
            _ = try await transport.invoke(
                LoopbackFixtures.invocation(alias: "tls"),
                intake: BoundedChannelState<ProviderResponse>(itemCap: 8, byteCap: 64 << 10))
            Issue.record("https-against-plaintext must fail")
        } catch let failure as TransportFailure {
            #expect(failure.phase == .preSend, "no head byte ever arrived: \(failure)")
        } catch {
            Issue.record("wrong error class (must be typed): \(error)")
        }
        #expect(tlsServer.requests.isEmpty, "handshake never completed: no valid request")
    }

    @Test("NET-02a pre-dial failures classify preSend, never ambiguous")
    func NET_02a_preDialPreSend() async throws {
        // Empty history and oversized bodies fail BEFORE any socket exists:
        // the adapter classifies every pre-dial failure preSend at its site
        // (the actor maps anything else to ambiguous — that must be
        // unreachable for requests that never left the process).
        let server = try LoopbackSSEServer()
        server.start()
        defer { server.stop() }
        let (base, _) = try LoopbackFixtures.transport(server: server)
        defer { await LoopbackFixtures.shutdown(base.client) }
        let empty = ChatCompletionsTransport(
            client: base.client,
            messageProvider: { _ in [] },
            credentialProvider: { _, _ in "loopback-test-secret" },
            snapshotProvider: base.snapshotProvider)
        do {
            _ = try await empty.invoke(
                LoopbackFixtures.invocation(),
                intake: BoundedChannelState<ProviderResponse>(itemCap: 8, byteCap: 64 << 10))
            Issue.record("empty history must refuse")
        } catch let failure as TransportFailure {
            #expect(failure.phase == .preSend, "nothing was sent: \(failure)")
            #expect(failure.message.contains("emptyMessages"), "typed: \(failure.message)")
        } catch {
            Issue.record("wrong error class (must be typed preSend): \(error)")
        }
        #expect(server.requests.isEmpty, "zero bytes sent")
    }

    @Test("NET-03 429 and 500 never retry and never sleep")
    func NET_03_noRetryNoBackoff() async throws {
        for status in [429, 500] {
            let server = try LoopbackSSEServer()
            server.enqueue(SSEScript(
                status: status,
                headers: [("Content-Type", "text/event-stream"), ("Retry-After", "120")],
                chunks: []))
            server.start()
            let started = Date()
            do {
                _ = try await Self.invoke(server: server)
                server.stop()
                Issue.record("HTTP \(status) must fail")
            } catch let failure as TransportFailure {
                server.stop()
                #expect(failure.phase == .postContent, "status arrived over the wire: \(failure)")
                #expect(failure.message.contains("httpStatus: \(status)"), "typed status: \(failure.message)")
            } catch {
                server.stop()
                Issue.record("wrong error class for \(status): \(error)")
            }
            let elapsed = Date().timeIntervalSince(started)
            #expect(server.connectionCount == 1, "HTTP \(status): single flight, no retry")
            #expect(elapsed < 10, "HTTP \(status): no backoff sleep (\(elapsed)s)")
        }
    }

    @Test("NET-04 read-idle and whole-request deadlines fire with correct phases")
    func NET_04_deadlinesFire() async throws {
        // Read-idle: one chunk flows, then silence past the 1 s idle cap.
        let idleServer = try LoopbackSSEServer()
        idleServer.enqueue(SSEScript(chunks: [
            ScriptChunk(bytes: Array("data: {\"choices\":[{\"delta\":{\"content\":\"part\"}}]}\n\n".utf8)),
            ScriptChunk(bytes: Array("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n".utf8), delayMillis: 5_000),
        ]))
        idleServer.start()
        do {
            _ = try await Self.invoke(
                server: idleServer, connectTimeout: 1, readIdleTimeout: 1, requestTimeout: 60)
            idleServer.stop()
            Issue.record("idle stall must fail")
        } catch let failure as TransportFailure {
            idleServer.stop()
            #expect(failure.phase == .postContent, "head arrived before the stall: \(failure)")
            #expect(failure.message.contains("read-idle"), "typed idle expiry: \(failure.message)")
        } catch {
            idleServer.stop()
            Issue.record("wrong error class: \(error)")
        }
        // Whole-request: steady 300 ms chunks for 6 s against a 3 s cap.
        // Idle (2 s) never fires — gaps stay at 300 ms — so only the whole
        // cap can produce this failure (no boundary race by construction).
        let wholeServer = try LoopbackSSEServer()
        var paced: [ScriptChunk] = [ScriptChunk(bytes: Array("data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\n".utf8))]
        for _ in 0..<20 {
            paced.append(ScriptChunk(
                bytes: Array("data: {\"choices\":[{\"delta\":{\"content\":\"b\"}}]}\n\n".utf8),
                delayMillis: 300))
        }
        wholeServer.enqueue(SSEScript(chunks: paced))
        wholeServer.start()
        do {
            _ = try await Self.invoke(
                server: wholeServer, connectTimeout: 1, readIdleTimeout: 2, requestTimeout: 3)
            wholeServer.stop()
            Issue.record("whole-cap overrun must fail")
        } catch let failure as TransportFailure {
            wholeServer.stop()
            #expect(failure.phase == .postContent, "bytes flowed before the cap: \(failure)")
            #expect(failure.message.contains("whole-request"), "typed whole-cap expiry: \(failure.message)")
        } catch {
            wholeServer.stop()
            Issue.record("wrong error class: \(error)")
        }
    }

    @Test("NET-05 401 and mid-stream abort fail typed with a single flight")
    func NET_05_credentialAndAbortTyped() async throws {
        // Wrong secret passes through byte-exact; the 401 surfaces typed.
        let authServer = try LoopbackSSEServer()
        authServer.enqueue(SSEScript(status: 401, headers: [("Content-Type", "text/event-stream")], chunks: []))
        authServer.start()
        do {
            _ = try await Self.invoke(server: authServer, credential: "wrong-secret")
            authServer.stop()
            Issue.record("401 must fail")
        } catch let failure as TransportFailure {
            authServer.stop()
            #expect(failure.phase == .postContent, "status arrived: \(failure)")
            #expect(failure.message.contains("httpStatus: 401"), "typed: \(failure.message)")
        } catch {
            authServer.stop()
            Issue.record("wrong error class: \(error)")
        }
        #expect(authServer.connectionCount == 1, "no retry on credential failure")
        let sent = try #require(authServer.requests.first)
        #expect(sent.header("authorization") == "Bearer wrong-secret",
                "credentials pass through unmodified, never truncated")
        // Mid-stream FIN after one chunk: assembly fails closed, zero proposals.
        let abortServer = try LoopbackSSEServer()
        abortServer.enqueue(SSEScript(
            chunks: [
                ScriptChunk(bytes: Array("data: {\"choices\":[{\"delta\":{\"content\":\"part\"}}]}\n\n".utf8)),
                ScriptChunk(bytes: Array("data: {\"choices\":[{\"delta\":{\"content\":\"more\"}}]}\n\n".utf8)),
            ],
            abortAfterChunks: 1))
        abortServer.start()
        defer { abortServer.stop() }
        // FIN mid-stream is an ASSEMBLY-level failure: invoke returns a
        // typed failed outcome with zero proposals (never a throw, never
        // partial execution) — the same contract WIRE-08 pins.
        let aborted = try await Self.invoke(server: abortServer)
        guard case .failed(let message) = aborted.response.outcome else {
            Issue.record("truncated stream must fail typed, got \(aborted.response.outcome)"); return
        }
        #expect(message.contains("no authoritative completion"), "typed: \(message)")
        #expect(aborted.connections == 1, "no resume, no retry after abort")
    }

    @Test("NET-06 nondeterminism probes: three identical runs, identical outcomes")
    func NET_06_nondeterminismProbes() async throws {
        // P1 byte-split flicker, P2 paced-vs-bulk, P3 abort-vs-clean:
        // same logical turn under transport nondeterminism must converge.
        let body = CannedTurn.text("converge")
        let bytes = Array(body.utf8)
        var results: [ProviderResponse] = []
        for variant in 0..<3 {
            let server = try LoopbackSSEServer()
            switch variant {
            case 0:
                server.enqueue(SSEScript(chunks: [ScriptChunk(bytes: bytes)]))
            case 1:
                server.enqueue(SSEScript(chunks: bytes.map { ScriptChunk(bytes: [$0]) }))
            default:
                let chunks = stride(from: 0, to: bytes.count, by: 32).map { offset in
                    ScriptChunk(
                        bytes: Array(bytes[offset..<min(offset + 32, bytes.count)]),
                        delayMillis: 15)
                }
                server.enqueue(SSEScript(chunks: chunks))
            }
            server.start()
            let run = try await Self.invoke(server: server)
            server.stop()
            results.append(run.response)
            #expect(run.connections == 1, "variant \(variant): single flight")
        }
        #expect(results[0] == results[1] && results[1] == results[2],
                "delivery shape must not move adapter output")
        guard case .textDeltaComplete(let text, _, let fin) = results[0].outcome else {
            Issue.record("converged turn must complete, got \(results[0].outcome)"); return
        }
        #expect(text == "converge" && fin)
    }
}
