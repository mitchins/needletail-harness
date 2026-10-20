import Testing
import Foundation
import NeedletailCore
@testable import NeedletailRuntime

/// A4-1 artifact publication, read-back and orphan-scan over the
/// production GRDB store. Every test drives real files beside a real
/// database: publication ordering (tmp → fsync → rename → dirsync →
/// fenced reference), typed read integrity, fencing, and orphan
/// reporting. Mock evidence stays in the scripted suites; everything
/// here is the production mechanism.
struct ArtifactPublicationTests {

    private static func freshPath() throws -> (directory: URL, path: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("needletail-artifact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("store.sqlite").path)
    }

    private static func payload(_ text: String) -> Data { Data(text.utf8) }

    private static func artifactsRoot(for path: String) -> String {
        (path as NSString).deletingPathExtension + "-artifacts"
    }

    @Test("A4-1 sqlite publication round-trips bytes with a fenced reference")
    func publicationRoundTripsWithFencedReference() throws {
        let (directory, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionID("s-pub")
        let store = try GRDBSessionStore(path: path)
        try store.claimWriterOwnership(session: session, writer: "w-1")
        let identity = WriterIdentity(session: session, writer: "w-1")
        let ref = try store.publishArtifact(
            session: session, as: identity, kind: "exec-output",
            operationID: OperationID("e1/c1"), bytes: Self.payload("artifact body"))
        #expect(ref.size == 13, "byte count travels with the reference")
        #expect(ref.kind == "exec-output")
        #expect(ref.operationID == OperationID("e1/c1"))
        #expect(ref.digest.count == 64, "SHA-256 hex digest")
        #expect(ref.relativePath == ref.digest, "content-addressed flat layout")
        // Private permissions on the managed root and the file.
        let rootAttrs = try FileManager.default.attributesOfItem(atPath: Self.artifactsRoot(for: path))
        #expect((rootAttrs[.posixPermissions] as? Int) == 0o700, "managed root is private")
        let fileAttrs = try FileManager.default.attributesOfItem(
            atPath: Self.artifactsRoot(for: path) + "/" + ref.digest)
        #expect((fileAttrs[.posixPermissions] as? Int) == 0o600, "artifact files are private")
        // Read-back returns the exact bytes.
        let roundTripped = try store.readArtifact(ref)
        #expect(roundTripped == Self.payload("artifact body"))
        // The reference is a durable ledger row: a fresh handle replays it.
        try store.close()
        let reopened = try GRDBSessionStore(path: path)
        let (page, _) = try reopened.records(session: session, since: 0, limit: 100)
        #expect(page.contains { $0.record == .artifactPublished(ref) },
                "committed reference survives reopen")
        let again = try reopened.readArtifact(ref)
        #expect(again == Self.payload("artifact body"), "bytes survive reopen")
        try reopened.close()
    }

    @Test("A4-1 sqlite artifact digests match SHA-256 known answers")
    func artifactDigestsMatchKnownAnswers() throws {
        // NIST FIPS 180-4 vectors: the digest function is independently
        // pinned, not just self-consistent.
        #expect(artifactSHA256Hex(Data()) ==
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(artifactSHA256Hex(Data("abc".utf8)) ==
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(artifactSHA256Hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)) ==
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    @Test("A4-1 sqlite stale writer publishes nothing and commits no reference")
    func staleWriterPublishesNothing() throws {
        let (directory, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionID("s-stale-pub")
        let oldHandle = try GRDBSessionStore(path: path)
        try oldHandle.claimWriterOwnership(session: session, writer: "w-old")
        let recoveryHandle = try GRDBSessionStore(path: path)
        let auth = RecoveryAuthorization(
            session: session, expectedWriter: "w-old", newWriter: "w-new",
            operatorID: "op-1", reference: "ticket-1", reason: "rotation", atMillis: 1)
        try recoveryHandle.recoverWriterOwnership(
            session: session, expectedWriter: "w-old", newWriter: "w-new", authorization: auth)
        // The old identity (handle still open) fails BEFORE any file work.
        #expect(throws: StoreError.notWriter(session: "s-stale-pub", writer: "w-old")) {
            try oldHandle.publishArtifact(
                session: session, as: WriterIdentity(session: session, writer: "w-old"),
                kind: "exec-output", operationID: nil, bytes: Self.payload("stale"))
        }
        // No file was created, no reference committed.
        let orphans = try recoveryHandle.detectArtifactOrphans()
        #expect(orphans.orphaned.isEmpty && orphans.interrupted.isEmpty,
                "stale publication leaves no filesystem trace")
        let (page, _) = try recoveryHandle.records(session: session, since: 0, limit: 100)
        #expect(!page.contains { if case .artifactPublished = $0.record { return true }; return false })
        // The new writer publishes normally (fencing intact post-takeover).
        let ref = try recoveryHandle.publishArtifact(
            session: session, as: WriterIdentity(session: session, writer: "w-new"),
            kind: "exec-output", operationID: nil, bytes: Self.payload("fresh"))
        #expect(try recoveryHandle.readArtifact(ref) == Self.payload("fresh"))
        try oldHandle.close()
        try recoveryHandle.close()
    }

    @Test("STORE-03 sqlite renamed artifact without reference is reported orphan")
    func STORE_03_sqliteRenamedArtifactWithoutReferenceIsReportedOrphan() throws {
        let (directory, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionID("s-orphan")
        // Session quota of 1: the ledger row is full, but the file half of
        // publication has no quota — rename succeeds, commit fails.
        let store = try GRDBSessionStore(
            path: path, sessionRecordLimit: 1, globalRecordLimit: 100_000)
        try store.claimWriterOwnership(session: session, writer: "w-1")
        try store.append(.transcriptAppended(.user("fill")),
                         as: WriterIdentity(session: session, writer: "w-1"))
        let identity = WriterIdentity(session: session, writer: "w-1")
        #expect(throws: StoreError.quotaExceeded(limit: 1)) {
            try store.publishArtifact(
                session: session, as: identity, kind: "exec-output",
                operationID: OperationID("e9/c1"), bytes: Self.payload("orphaned bytes"))
        }
        // The file IS durable (rename happened) with NO database reference:
        // a textbook orphan — reported, never silently deleted, never
        // attached to the operation.
        let report = try store.detectArtifactOrphans()
        #expect(report.orphaned.count == 1, "exactly the renamed-but-unreferenced file, got \(report.orphaned)")
        #expect(report.interrupted.isEmpty)
        let (page, _) = try store.records(session: session, since: 0, limit: 100)
        #expect(!page.contains { if case .artifactPublished = $0.record { return true }; return false },
                "failed commit leaves no reference row")
        // Reconcile is unaffected: no operation records exist here, and the
        // orphan file is invisible to it.
        let reconciled = try store.reconcile(session: session)
        #expect(reconciled.completed.isEmpty && reconciled.heldOperations.isEmpty)
        // A planted interrupted tmp file is reported in its own bucket.
        try Self.payload("partial").write(
            to: URL(fileURLWithPath: Self.artifactsRoot(for: path) + "/.tmp-abandoned"))
        let report2 = try store.detectArtifactOrphans()
        #expect(report2.interrupted == [".tmp-abandoned"])
        #expect(report2.orphaned == report.orphaned, "buckets stay distinct")
        // A normally published artifact is never reported.
        let roomy = try GRDBSessionStore(path: directory.appendingPathComponent("roomy.sqlite").path)
        let session2 = SessionID("s-clean")
        try roomy.claimWriterOwnership(session: session2, writer: "w-1")
        let ref = try roomy.publishArtifact(
            session: session2, as: WriterIdentity(session: session2, writer: "w-1"),
            kind: "exec-output", operationID: nil, bytes: Self.payload("clean"))
        let clean = try roomy.detectArtifactOrphans()
        #expect(clean.orphaned.isEmpty && clean.interrupted.isEmpty,
                "referenced artifacts are not orphans")
        #expect(ref.digest.count == 64)
        try store.close()
        try roomy.close()
    }

    @Test("STORE-04 sqlite reference to absent artifact fails typed integrity")
    func STORE_04_sqliteReferenceToAbsentArtifactFailsTypedIntegrity() throws {
        let (directory, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionID("s-absent")
        let store = try GRDBSessionStore(path: path)
        try store.claimWriterOwnership(session: session, writer: "w-1")
        let identity = WriterIdentity(session: session, writer: "w-1")
        // A reference row with no file behind it (corrupt ledger): the
        // read must fail typed, never return substitute bytes.
        let ghost = ArtifactRef(
            digest: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            size: 0, kind: "exec-output", operationID: nil)
        try store.append(.artifactPublished(ghost), as: identity)
        #expect(throws: StoreError.self) { try store.readArtifact(ghost) }
        do {
            _ = try store.readArtifact(ghost)
            Issue.record("absent artifact must not read")
        } catch let error as StoreError {
            if case .integrity(let message) = error {
                #expect(message.contains("absent"), "typed absence, got: \(message)")
            } else {
                Issue.record("absent artifact must fail .integrity, got \(error)")
            }
        } catch {
            Issue.record("absent artifact must fail StoreError, got \(error)")
        }
        try store.close()
    }

    @Test("A4-1 sqlite tampered bytes fail digest verification on read")
    func tamperedBytesFailDigestVerification() throws {
        let (directory, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionID("s-tamper")
        let store = try GRDBSessionStore(path: path)
        try store.claimWriterOwnership(session: session, writer: "w-1")
        let identity = WriterIdentity(session: session, writer: "w-1")
        let ref = try store.publishArtifact(
            session: session, as: identity, kind: "exec-output",
            operationID: nil, bytes: Self.payload("genuine bytes"))
        #expect(try store.readArtifact(ref) == Self.payload("genuine bytes"))
        // Disk-level tamper (SAME size, different bytes — the size gate
        // cannot see it): the digest — not the database — is the authority.
        let filePath = Self.artifactsRoot(for: path) + "/" + ref.digest
        try Self.payload("tampered byt!").write(to: URL(fileURLWithPath: filePath))
        do {
            _ = try store.readArtifact(ref)
            Issue.record("tampered artifact must not read")
        } catch let error as StoreError {
            if case .integrity(let message) = error {
                #expect(message.contains("mismatch"), "typed mismatch, got: \(message)")
            } else {
                Issue.record("tampered artifact must fail .integrity, got \(error)")
            }
        } catch {
            Issue.record("tampered artifact must fail StoreError, got \(error)")
        }
        // Truncation (size drift) fails too.
        try Self.payload("short").write(to: URL(fileURLWithPath: filePath))
        #expect(throws: StoreError.self) { try store.readArtifact(ref) }
        try store.close()
    }

    @Test("A4-1 sqlite symlink and forged paths are refused")
    func symlinkAndForgedPathsRefused() throws {
        let (directory, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionID("s-links")
        let store = try GRDBSessionStore(path: path)
        try store.claimWriterOwnership(session: session, writer: "w-1")
        let identity = WriterIdentity(session: session, writer: "w-1")
        let ref = try store.publishArtifact(
            session: session, as: identity, kind: "preimage",
            operationID: nil, bytes: Self.payload("link target"))
        let filePath = Self.artifactsRoot(for: path) + "/" + ref.digest
        let linkFarm = directory.appendingPathComponent("farm").path
        try FileManager.default.createDirectory(atPath: linkFarm, withIntermediateDirectories: false)
        // Replace the published file with a symlink to attacker content:
        // the read must refuse the link, even though the target is readable.
        try FileManager.default.removeItem(atPath: filePath)
        try Self.payload("attacker bytes").write(
            to: URL(fileURLWithPath: linkFarm + "/evil"))
        try FileManager.default.createSymbolicLink(
            atPath: filePath, withDestinationPath: linkFarm + "/evil")
        #expect(throws: StoreError.self) { try store.readArtifact(ref) }
        // Forged digests never resolve: traversal, absolute, empty, non-hex.
        for forged in ["../../etc/passwd", "/abs/path", "", "nothex!!",
                       "ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789"] {
            let bad = ArtifactRef(digest: forged, size: 1, kind: "exec-output", operationID: nil)
            #expect(throws: StoreError.self) { try store.readArtifact(bad) }
        }
        // The confinement gate itself, white-box: every escaping name is
        // rejected (dotfiles stay confined by construction, so they need
        // no rejection — they cannot leave the root); conforming names
        // resolve under the root.
        for hostile in ["a/b", "..", ".", "/abs", "", "x\0y", "a/../../b"] {
            #expect(throws: StoreError.self) {
                try resolveArtifactPath(root: "/root", name: hostile)
            }
        }
        #expect(try resolveArtifactPath(root: "/root", name: ref.digest) == "/root/" + ref.digest)
        #expect(try resolveArtifactPath(root: "/root", name: ".tmp-abc") == "/root/.tmp-abc")
        try store.close()
    }

    @Test("A4-1 sqlite empty and oversize payloads fail closed before any file")
    func emptyAndOversizePayloadsFailClosed() throws {
        let (directory, path) = try Self.freshPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionID("s-bounds")
        let store = try GRDBSessionStore(path: path)
        try store.claimWriterOwnership(session: session, writer: "w-1")
        let identity = WriterIdentity(session: session, writer: "w-1")
        #expect(throws: StoreError.self) {
            try store.publishArtifact(
                session: session, as: identity, kind: "exec-output",
                operationID: nil, bytes: Data())
        }
        #expect(throws: StoreError.self) {
            try store.publishArtifact(
                session: session, as: identity, kind: "",
                operationID: nil, bytes: Self.payload("x"))
        }
        #expect(throws: StoreError.quotaExceeded(limit: 32 * 1024 * 1024)) {
            try store.publishArtifact(
                session: session, as: identity, kind: "exec-output",
                operationID: nil, bytes: Data(repeating: 0x61, count: 32 * 1024 * 1024 + 1))
        }
        // Nothing reached the filesystem: no root, no orphans.
        #expect(!FileManager.default.fileExists(atPath: Self.artifactsRoot(for: path)))
        let orphans = try store.detectArtifactOrphans()
        #expect(orphans.orphaned.isEmpty && orphans.interrupted.isEmpty)
        try store.close()
    }
}
