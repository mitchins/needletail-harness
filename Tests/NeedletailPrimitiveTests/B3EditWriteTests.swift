import Testing
import Foundation
import NeedletailCore
@testable import NeedletailRuntime
import NeedletailTestSupport
import Crypto
import SystemPackage
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// B3-A: exact edit/write operations. Real filesystem + real GRDB store,
/// per-test writer ownership. Every leg asserts byte-exactness, receipts,
/// preimages and cleanup — plus counterfactuals proving the safeguards are
/// load-bearing (fuzzy matcher, normalization shim, naive no-gate replay,
/// silent overwrite).
struct B3EditWriteTests {
    private static func tempRoot() throws -> (URL, FilePath) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("b3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return (url, FilePath(url.path))
    }

    private static func tempStore() throws -> (URL, GRDBSessionStore, SessionID, WriterIdentity) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("b3-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try GRDBSessionStore(path: dir.appendingPathComponent("store.sqlite").path)
        let session = SessionID("s-b3")
        let writer = WriterIdentity(session: session, writer: "w")
        try store.claimWriterOwnership(session: session, writer: "w")
        return (dir, store, session, writer)
    }

    private static func sha(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func shaData(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    private static func makeReservation(batch: ToolBatch) -> EffectReservation {
        EffectReservation(effectID: EffectID("eff-1"), runID: RunID("r1"), requestID: RequestID("req1"), generation: Revision(1), revision: Revision(1), mutating: true, batch: batch, kind: .executor, approvedPaths: [])
    }

    private static func preimageDigests(store: GRDBSessionStore, session: SessionID) throws -> [String] {
        var out: [String] = []
        var cursor: UInt64 = 0
        while true {
            let (page, next) = try store.records(session: session, since: cursor, limit: 500)
            for row in page {
                if case .artifactPublished(let ref) = row.record, ref.kind == "preimage" {
                    out.append(ref.digest)
                }
            }
            guard let advanced = next else { break }
            cursor = advanced
        }
        return out
    }

    private static func tmpFiles(under url: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path).filter { $0.hasSuffix(".tmp") }) ?? []
    }

    // MARK: - TOOL-04 edit shape legs

    @Test("TOOL_04_zeroMatch")
    func tool04ZeroMatch() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        try "hello world\n".write(to: url.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        let h = Self.sha("hello world\n")
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"f\",\"expectedHash\":\"\(h)\",\"old_string\":\"xyz\",\"new_string\":\"abc\"}")])
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
        #expect(result.calls[0].status == "no-match", "zero matches must be no-match, got \(result.calls[0])")
        #expect(result.calls[0].started == true)
        #expect(result.calls[0].beforeHash == h)
        #expect(try String(contentsOf: url.appendingPathComponent("f"), encoding: .utf8) == "hello world\n", "file untouched")
        #expect(try Self.preimageDigests(store: store, session: session).isEmpty, "no-match publishes no preimage")
        #expect(Self.tmpFiles(under: url).isEmpty, "no tmp leftovers")
    }

    @Test("TOOL_04_oneMatch")
    func tool04OneMatch() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let file = url.appendingPathComponent("f")
        try "hello world\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        let h0 = Self.sha("hello world\n")
        let h1 = Self.sha("hello there\n")
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"f\",\"expectedHash\":\"\(h0)\",\"old_string\":\"world\",\"new_string\":\"there\"}")])
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
        let call = result.calls[0]
        #expect(call.status == "success", "one match must succeed, got \(call)")
        #expect(call.data == "edited")
        #expect(call.path == "f" && call.mode == "640", "receipt carries path and preserved mode, got \(call)")
        #expect(call.beforeHash == h0 && call.afterHash == h1, "receipt carries before/after hashes")
        #expect(try String(contentsOf: file, encoding: .utf8) == "hello there\n")
        #expect(call.artifactID == h0, "preimage digest travels in the receipt")
        let digests = try Self.preimageDigests(store: store, session: session)
        #expect(digests == [h0], "exactly one preimage reference committed")
        let roundTrip = try store.artifactRecord(session: session, digest: h0)
        #expect(roundTrip == Data("hello world\n".utf8), "preimage bytes recoverable")
        #expect(Self.tmpFiles(under: url).isEmpty, "no tmp leftovers")
    }

    @Test("TOOL_04_multipleMatch")
    func tool04MultipleMatch() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        try "aa aa\n".write(to: url.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        let h = Self.sha("aa aa\n")
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"f\",\"expectedHash\":\"\(h)\",\"old_string\":\"aa\",\"new_string\":\"bb\"}")])
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
        #expect(result.calls[0].status == "invalid-arguments", "multiple matches must be invalid-arguments, got \(result.calls[0])")
        #expect(try String(contentsOf: url.appendingPathComponent("f"), encoding: .utf8) == "aa aa\n", "file untouched")
        #expect(try Self.preimageDigests(store: store, session: session).isEmpty, "no preimage on multiple-match")
        #expect(Self.tmpFiles(under: url).isEmpty, "no tmp leftovers")
    }

    @Test("TOOL_04_emptyOld")
    func tool04EmptyOld() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        try "data".write(to: url.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        // Missing old_string and empty oldBytes are both invalid pre-dispatch.
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"f\",\"expectedHash\":\"\(String(repeating: "0", count: 64))\",\"new_string\":\"x\"}")])
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
        #expect(result.calls[0].status == "invalid-arguments")
        #expect(result.calls[0].started == false, "empty old must be pre-dispatch")
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent(".needletail/lock").path), "no lock on invalid args")
        #expect(Self.tmpFiles(under: url).isEmpty, "no tmp on invalid args")
    }

    @Test("TOOL_04_fuzzyCounterfactual")
    func tool04FuzzyCounterfactual() async throws {
        // A fuzzy matcher (case-insensitive / trimmed) WOULD match here; the
        // byte-exact executor must not. The in-test fuzzy predicate proves
        // the fixture is sensitive (would-match), so no-match is evidence.
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        try "hello world\n".write(to: url.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        let h = Self.sha("hello world\n")
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"f\",\"expectedHash\":\"\(h)\",\"old_string\":\"Hello\",\"new_string\":\"X\"}")])
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
        #expect(result.calls[0].status == "no-match", "case differs: byte-exact must not match, got \(result.calls[0])")
        let fuzzyWouldMatch = "hello world\n".lowercased().contains("hello")
        #expect(fuzzyWouldMatch, "sensitivity: a case-folding matcher would have matched")
        #expect(try String(contentsOf: url.appendingPathComponent("f"), encoding: .utf8) == "hello world\n")
    }

    // MARK: - TOOL-05 optimistic concurrency

    @Test("TOOL_05_injectedChange")
    func tool05InjectedChange() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let file = url.appendingPathComponent("f")
        try "original content\n".write(to: file, atomically: true, encoding: .utf8)
        let h0 = Self.sha("original content\n")
        // Injected change between read and commit (another writer, no lock).
        try "INJECTED\n".write(to: file, atomically: true, encoding: .utf8)
        let hInjected = Self.sha("INJECTED\n")
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"f\",\"expectedHash\":\"\(h0)\",\"old_string\":\"original\",\"new_string\":\"MUTANT\"}")])
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
        let call = result.calls[0]
        #expect(call.status == "conflict", "stale hash must conflict, got \(call)")
        #expect(call.beforeHash == hInjected, "receipt reports the hash actually present")
        #expect(try String(contentsOf: file, encoding: .utf8) == "INJECTED\n", "injected content untouched by us")
        #expect(try Self.preimageDigests(store: store, session: session).isEmpty, "conflict before commit publishes no preimage")
        #expect(Self.tmpFiles(under: url).isEmpty, "no tmp leftovers")
    }

    @Test("TOOL_05_lostUpdateCounterfactual")
    func tool05LostUpdateCounterfactual() async throws {
        // The naive sequence (read once, no re-read, tmp+rename) demonstrably
        // loses an injected update. This is the hazard the executor's
        // re-read-under-lock gate closes (TOOL_05_injectedChange conflicts).
        let (url, _) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("f")
        try "original content\n".write(to: file, atomically: true, encoding: .utf8)
        let naiveRead = try String(contentsOf: file, encoding: .utf8)
        // Injected change after the naive read.
        try "INJECTED\n".write(to: file, atomically: true, encoding: .utf8)
        // Naive commit: no re-read, no hash check — silent lost update.
        // (Direct overwrite stands in for naive tmp+rename; either way the
        // injected bytes vanish without any conflict signal.)
        let naiveNew = naiveRead.replacingOccurrences(of: "original", with: "MUTANT")
        try Data(naiveNew.utf8).write(to: file)
        let final = try String(contentsOf: file, encoding: .utf8)
        #expect(!final.contains("INJECTED"), "counterfactual: naive no-gate commit loses the injected update, got \(final.debugDescription)")
        #expect(final.contains("MUTANT"), "counterfactual: naive commit lands stale content")
    }

    @Test("TOOL_05_concurrentEdits")
    func tool05ConcurrentEdits() async throws {
        // The workspace lock serializes two concurrent edits: exactly one
        // wins. The loser either contends on the lock (typed failed, no side
        // effect) or runs after the winner and conflicts on the stale hash.
        // A loser retry with the original hash then conflicts deterministically.
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        try "v0\n".write(to: url.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        let h0 = Self.sha("v0\n")
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        func runEdit(new: String) async throws -> ToolCallOutcome {
            let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
            let batch = ToolBatch([ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"f\",\"expectedHash\":\"\(h0)\",\"old_string\":\"v0\",\"new_string\":\"\(new)\"}")])
            return try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch)).calls[0]
        }
        async let a = runEdit(new: "va")
        async let b = runEdit(new: "vb")
        let (ra, rb) = try await (a, b)
        let successes = [ra, rb].filter { $0.status == "success" }
        let losers = [("va", ra), ("vb", rb)].filter { $0.1.status != "success" }
        #expect(successes.count == 1, "exactly one winner, got \(ra) / \(rb)")
        #expect(losers.count == 1 && (losers[0].1.status == "conflict" || losers[0].1.summary.contains("lock contention")), "loser conflicts or contends, got \(String(describing: losers.first?.1))")
        let final = try String(contentsOf: url.appendingPathComponent("f"), encoding: .utf8)
        #expect(final == "va\n" || final == "vb\n", "winner's bytes land exactly, got \(final.debugDescription)")
        // Loser retry with the stale original hash conflicts deterministically.
        let retry = try await runEdit(new: "retry-\(losers[0].0)")
        #expect(retry.status == "conflict", "stale-hash retry must conflict, got \(retry)")
        #expect(try String(contentsOf: url.appendingPathComponent("f"), encoding: .utf8) == final, "retry changes nothing")
    }

    // MARK: - TOOL-06 byte preservation

    @Test("TOOL_06_crlf")
    func tool06Crlf() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let bytes = Data("a\r\nb\r\n".utf8)
        try bytes.write(to: url.appendingPathComponent("f"))
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        let h = Self.shaData(bytes)
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"f\",\"expectedHash\":\"\(h)\",\"old_string\":\"b\",\"new_string\":\"B\"}")])
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
        #expect(result.calls[0].status == "success", "CRLF edit must succeed, got \(result.calls[0])")
        let after = try Data(contentsOf: url.appendingPathComponent("f"))
        #expect(after == Data("a\r\nB\r\n".utf8), "CRLF conventions preserved byte-exactly, got \(after)")
    }

    @Test("TOOL_06_noFinalNewline")
    func tool06NoFinalNewline() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        try Data("x\ny".utf8).write(to: url.appendingPathComponent("f"))
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        let h = Self.sha("x\ny")
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"f\",\"expectedHash\":\"\(h)\",\"old_string\":\"x\",\"new_string\":\"X\"}")])
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
        #expect(result.calls[0].status == "success")
        let after = try Data(contentsOf: url.appendingPathComponent("f"))
        #expect(after == Data("X\ny".utf8), "missing final newline must not be added, got \(after)")
    }

    @Test("TOOL_06_unicode")
    func tool06Unicode() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        // a + combining acute + b + emoji + c, newline-terminated.
        let original = "áb😀c\n"
        try Data(original.utf8).write(to: url.appendingPathComponent("f"))
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        let h = Self.sha(original)
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"f\",\"expectedHash\":\"\(h)\",\"old_string\":\"😀\",\"new_string\":\"😎\"}")])
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
        #expect(result.calls[0].status == "success", "emoji edit must succeed, got \(result.calls[0])")
        let after = try Data(contentsOf: url.appendingPathComponent("f"))
        #expect(after == Data("áb😎c\n".utf8), "multi-byte sequences preserved byte-exactly")
        #expect(result.calls[0].afterHash == Self.sha("áb😎c\n"))
    }

    @Test("TOOL_06_modePreserved")
    func tool06ModePreserved() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let file = url.appendingPathComponent("f")
        try "mode me\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        let h = Self.sha("mode me\n")
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"f\",\"expectedHash\":\"\(h)\",\"old_string\":\"me\",\"new_string\":\"you\"}")])
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
        #expect(result.calls[0].status == "success")
        let st = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(st == 0o640, "mode must survive replace, got \(String(describing: st))")
        #expect(result.calls[0].mode == "640", "receipt must carry preserved mode, got \(String(describing: result.calls[0].mode))")
        // Read-only files stay readable for edit and keep their mode.
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        let h2 = Self.sha("mode you\n")
        let batch2 = ToolBatch([ToolProposal(callID: "c2", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"f\",\"expectedHash\":\"\(h2)\",\"old_string\":\"you\",\"new_string\":\"them\"}")])
        let result2 = try await exec.execute(batch: batch2, reservation: Self.makeReservation(batch: batch2))
        #expect(result2.calls[0].status == "success", "read-only target still editable, got \(result2.calls[0])")
        let st2 = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(st2 == 0o444, "read-only mode preserved, got \(String(describing: st2))")
    }

    @Test("TOOL_06_normalizationCounterfactual")
    func tool06NormalizationCounterfactual() async throws {
        // A normalizing shim (CRLF→LF) WOULD match here; byte-exact must not.
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        try Data("a\r\nb\r\n".utf8).write(to: url.appendingPathComponent("f"))
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        let h = Self.sha("a\r\nb\r\n")
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"f\",\"expectedHash\":\"\(h)\",\"old_string\":\"a\\nb\\n\",\"new_string\":\"X\"}")])
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
        #expect(result.calls[0].status == "no-match", "LF-only old must not match CRLF bytes, got \(result.calls[0])")
        let normalizedWouldMatch = "a\r\nb\r\n".replacingOccurrences(of: "\r\n", with: "\n").contains("a\nb\n")
        #expect(normalizedWouldMatch, "sensitivity: a normalizing shim would have matched")
        let after = try Data(contentsOf: url.appendingPathComponent("f"))
        #expect(after == Data("a\r\nb\r\n".utf8), "file untouched")
    }

    // MARK: - TOOL-08 write

    @Test("TOOL_08_createNew")
    func tool08CreateNew() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        // Missing parents are created confined under the workspace.
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "write", argumentsDigest: "d", arguments: "{\"path\":\"sub/dir/n.txt\",\"content\":\"fresh\\n\"}")])
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
        let call = result.calls[0]
        #expect(call.status == "success", "create must succeed, got \(call)")
        #expect(call.data == "written" && call.afterHash == Self.sha("fresh\n") && call.mode == "600")
        #expect(call.artifactID == nil && call.beforeHash == nil, "create carries no preimage")
        #expect(try String(contentsOf: url.appendingPathComponent("sub/dir/n.txt"), encoding: .utf8) == "fresh\n")
        let subAttrs = try FileManager.default.attributesOfItem(atPath: url.appendingPathComponent("sub").path)
        #expect((subAttrs[.posixPermissions] as? Int) == 0o700, "created parents are private")
    }

    @Test("TOOL_08_existsRefusal")
    func tool08ExistsRefusal() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        try "keep\n".write(to: url.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        // Silent overwrite refused…
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "write", argumentsDigest: "d", arguments: "{\"path\":\"f\",\"content\":\"evil\\n\"}")])
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
        #expect(result.calls[0].status == "failed" && result.calls[0].summary.contains("exists"), "existing file must refuse silent overwrite, got \(result.calls[0])")
        #expect(try String(contentsOf: url.appendingPathComponent("f"), encoding: .utf8) == "keep\n")
        // …but the same path with an authorizing hash replaces.
        let h = Self.sha("keep\n")
        let batch2 = ToolBatch([ToolProposal(callID: "c2", tool: "write", argumentsDigest: "d", arguments: "{\"path\":\"f\",\"content\":\"open\\n\",\"expectedHash\":\"\(h)\"}")])
        let result2 = try await exec.execute(batch: batch2, reservation: Self.makeReservation(batch: batch2))
        #expect(result2.calls[0].status == "success", "authorized replacement proceeds, got \(result2.calls[0])")
        #expect(try String(contentsOf: url.appendingPathComponent("f"), encoding: .utf8) == "open\n")
    }

    @Test("TOOL_08_staleHash")
    func tool08StaleHash() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        try "v1\n".write(to: url.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        let stale = Self.sha("stale\n")
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "write", argumentsDigest: "d", arguments: "{\"path\":\"f\",\"content\":\"v2\\n\",\"expectedHash\":\"\(stale)\"}")])
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
        #expect(result.calls[0].status == "conflict", "stale replacement hash must conflict, got \(result.calls[0])")
        #expect(try String(contentsOf: url.appendingPathComponent("f"), encoding: .utf8) == "v1\n", "file untouched")
        #expect(try Self.preimageDigests(store: store, session: session).isEmpty, "conflict publishes no preimage")
    }

    @Test("TOOL_08_replaceMissing")
    func tool08ReplaceMissing() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "write", argumentsDigest: "d", arguments: "{\"path\":\"ghost\",\"content\":\"x\\n\",\"expectedHash\":\"\(String(repeating: "0", count: 64))\"}")])
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
        #expect(result.calls[0].status == "no-match", "replacement of missing file is no-match, got \(result.calls[0])")
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("ghost").path), "nothing created")
    }

    @Test("TOOL_08_replaceSuccess")
    func tool08ReplaceSuccess() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let file = url.appendingPathComponent("f")
        try "old content\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        let h0 = Self.sha("old content\n")
        let h1 = Self.sha("new content\n")
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "write", argumentsDigest: "d", arguments: "{\"path\":\"f\",\"content\":\"new content\\n\",\"expectedHash\":\"\(h0)\"}")])
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
        let call = result.calls[0]
        #expect(call.status == "success" && call.data == "replaced", "authorized replace succeeds, got \(call)")
        #expect(call.beforeHash == h0 && call.afterHash == h1 && call.mode == "640" && call.path == "f")
        #expect(try String(contentsOf: file, encoding: .utf8) == "new content\n")
        #expect(call.artifactID == h0, "preimage digest in receipt")
        let roundTrip = try store.artifactRecord(session: session, digest: h0)
        #expect(roundTrip == Data("old content\n".utf8), "preimage bytes recoverable")
        let st = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(st == 0o640, "mode preserved across replacement")
        #expect(Self.tmpFiles(under: url).isEmpty, "no tmp leftovers")
    }

    @Test("TOOL_08_replaceEmptyOriginal")
    func tool08ReplaceEmptyOriginal() async throws {
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        try Data().write(to: url.appendingPathComponent("f"))
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        let hEmpty = Self.sha("")
        let hNew = Self.sha("now\n")
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "write", argumentsDigest: "d", arguments: "{\"path\":\"f\",\"content\":\"now\\n\",\"expectedHash\":\"\(hEmpty)\"}")])
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
        #expect(result.calls[0].status == "success", "empty-original replace succeeds, got \(result.calls[0])")
        #expect(result.calls[0].artifactID == nil, "zero-byte original: hash-only receipt, no publish")
        #expect(result.calls[0].beforeHash == hEmpty && result.calls[0].afterHash == hNew)
        #expect(try Self.preimageDigests(store: store, session: session).isEmpty)
    }

    @Test("TOOL_08_symlinkSwap")
    func tool08SymlinkSwap() async throws {
        // A swapped-in symlink is never followed: create refuses, edit and
        // authorized replacement fail, and the link target is untouched.
        let (url, fp) = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: url) }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let outside = url.appendingPathComponent("outside.txt")
        try "SECRET\n".write(to: outside, atomically: true, encoding: .utf8)
        try "victim\n".write(to: url.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: url.appendingPathComponent("f"))
        try FileManager.default.createSymbolicLink(at: url.appendingPathComponent("f"), withDestinationURL: outside)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        let hVictim = Self.sha("victim\n")
        let batchW = ToolBatch([ToolProposal(callID: "c1", tool: "write", argumentsDigest: "d", arguments: "{\"path\":\"f\",\"content\":\"x\\n\"}")])
        let rW = try await exec.execute(batch: batchW, reservation: Self.makeReservation(batch: batchW))
        #expect(rW.calls[0].status == "failed", "create through symlink must fail, got \(rW.calls[0])")
        let batchE = ToolBatch([ToolProposal(callID: "c2", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"f\",\"expectedHash\":\"\(hVictim)\",\"old_string\":\"victim\",\"new_string\":\"x\"}")])
        let rE = try await exec.execute(batch: batchE, reservation: Self.makeReservation(batch: batchE))
        #expect(rE.calls[0].status == "failed" || rE.calls[0].status == "denied", "edit through symlink must fail, got \(rE.calls[0])")
        let batchR = ToolBatch([ToolProposal(callID: "c3", tool: "write", argumentsDigest: "d", arguments: "{\"path\":\"f\",\"content\":\"x\\n\",\"expectedHash\":\"\(hVictim)\"}")])
        let rR = try await exec.execute(batch: batchR, reservation: Self.makeReservation(batch: batchR))
        #expect(rR.calls[0].status == "failed" || rR.calls[0].status == "denied", "replacement through symlink must fail, got \(rR.calls[0])")
        #expect(try String(contentsOf: outside, encoding: .utf8) == "SECRET\n", "link target untouched")
    }

    @Test("TOOL_08_injectedCommitFailure")
    func tool08InjectedCommitFailure() async throws {
        // Read-only parent: tmp creation fails, so nothing is committed, no
        // tmp remains, and no preimage is published for unmodified content.
        let (url, fp) = try Self.tempRoot()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.appendingPathComponent("sub").path)
            try? FileManager.default.removeItem(at: url)
        }
        let (dir, store, session, writer) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: dir); try? store.close() }
        let sub = url.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "precious\n".write(to: sub.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sub.path)
        let resolver = try WorkspaceResolver(workspace: fp, readRoots: [])
        let exec = NativeToolExecutor(resolver: resolver, store: store, sessionID: session, writer: writer)
        let h = Self.sha("precious\n")
        let batch = ToolBatch([ToolProposal(callID: "c1", tool: "edit", argumentsDigest: "d", arguments: "{\"path\":\"sub/f\",\"expectedHash\":\"\(h)\",\"old_string\":\"precious\",\"new_string\":\"ruin\"}")])
        let result = try await exec.execute(batch: batch, reservation: Self.makeReservation(batch: batch))
        #expect(result.calls[0].status == "failed", "read-only parent must fail the commit, got \(result.calls[0])")
        #expect(try String(contentsOf: sub.appendingPathComponent("f"), encoding: .utf8) == "precious\n", "file untouched")
        #expect(Self.tmpFiles(under: sub).isEmpty, "no tmp leftovers")
        #expect(try Self.preimageDigests(store: store, session: session).isEmpty, "nothing modified, nothing preserved")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sub.path)
    }
}
