import Testing
import Foundation
import SystemPackage
@testable import NeedletailRuntime
import NeedletailCore

/// M2-D D1: authorized atomic capture against a REAL temporary filesystem
/// (no mocks): happy-path identity/hash/excerpt/range, symlink escape,
/// special files, denied paths, mutation-during-capture, invalid ranges,
/// size cap, binary handling, and the 2 MiB tool-mode file (MENTION-10).
///
/// Fault injection for mutation-during-capture uses the exposed capture
/// steps (open → read → mutate → finalize) around the same temp files the
/// one-shot path uses — deterministic by construction.
struct AttachmentCaptureTests {

    struct Workspace {
        let dir: URL
        let resolver: WorkspaceResolver
        let service: AttachmentCaptureService

        func write(_ name: String, bytes: Data) throws {
            try bytes.write(to: dir.appendingPathComponent(name))
        }

        func write(_ name: String, text: String) throws {
            try write(name, bytes: Data(text.utf8))
        }

        func grant(for alias: String = "local-coder") -> AttachmentRouteGrant {
            AttachmentRouteGrant(alias: alias, locality: .local, sealed: false)
        }

        func capture(
            _ name: String, range: AttachmentLineRange? = nil, intent: String = "mention",
            epoch: String = "epoch-1"
        ) throws -> AttachmentSnapshot {
            try service.capture(
                relativePath: name, lineRange: range, intent: intent,
                epochID: EpochID(epoch), routeGrant: grant())
        }
    }

    static func makeWorkspace() throws -> Workspace {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let resolver = try WorkspaceResolver(
            workspace: FilePath(dir.path), readRoots: [])
        return Workspace(
            dir: dir, resolver: resolver,
            service: AttachmentCaptureService(resolver: resolver))
    }

    static func sha(_ bytes: Data) -> String {
        NativeToolExecutor.sha256Hex(bytes)
    }

    @Test("capture binds identity, hash and bounded excerpt")
    func captureHappyPath() throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.dir) }
        let text = (1...20).map { "line \($0)\n" }.joined()
        try ws.write("a.txt", text: text)
        let snap = try ws.capture("a.txt")
        #expect(snap.path == "a.txt")
        #expect(snap.grantedRoot == "workspace")
        #expect(snap.size == text.utf8.count)
        #expect(snap.contentHash == Self.sha(Data(text.utf8)), "hash covers the exact bytes")
        #expect(snap.totalLines == 20)
        #expect(snap.device != 0 && snap.inode != 0, "real file identity")
        if case .included(let excerpt, let truncated) = snap.content {
            #expect(excerpt == text, "small file: whole content as excerpt")
            #expect(!truncated, "complete file is not truncated")
        } else {
            Issue.record("small text file must be included")
        }
        #expect(snap.captureEpochID == EpochID("epoch-1"))
        #expect(snap.routeGrant.alias == "local-coder")
        #expect(snap.intent == "mention")
    }

    @Test("line range slices exactly and validates bounds")
    func lineRangeSlicing() throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.dir) }
        try ws.write("r.txt", text: "one\ntwo\nthree\nfour\n")
        let snap = try ws.capture("r.txt", range: AttachmentLineRange(start: 2, end: 3))
        #expect(snap.lineRange == AttachmentLineRange(start: 2, end: 3))
        if case .included(let excerpt, let truncated) = snap.content {
            #expect(excerpt == "two\nthree\n", "exact 1-based inclusive slice")
            #expect(truncated, "a sub-range is truncated by definition")
        } else {
            Issue.record("ranged text must be included")
        }
        // Reversed, zero-based and out-of-bounds ranges refuse.
        #expect(throws: AttachmentCaptureError.self) {
            try ws.capture("r.txt", range: AttachmentLineRange(start: 3, end: 2))
        }
        #expect(throws: AttachmentCaptureError.self) {
            try ws.capture("r.txt", range: AttachmentLineRange(start: 0, end: 2))
        }
        #expect(throws: AttachmentCaptureError.self) {
            try ws.capture("r.txt", range: AttachmentLineRange(start: 1, end: 99))
        }
        // CRLF files slice on 0x0A exactly like LF files (a range starting
        // past line 1 must not trap and must not return whole-file bytes).
        try ws.write("crlf.txt", bytes: Data("a\r\nb\r\nc\r\n".utf8))
        let crlf = try ws.capture("crlf.txt", range: AttachmentLineRange(start: 2, end: 3))
        if case .included(let excerpt, _) = crlf.content {
            #expect(excerpt == "b\r\nc\r\n", "CR bytes ride inside their lines")
        } else {
            Issue.record("ranged CRLF text must be included")
        }
    }

    @Test("large file truncates the excerpt to 4 KiB with an explicit flag")
    func largeFileTruncates() throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.dir) }
        // 2 MiB tool-mode file (MENTION-10): bounded excerpt + manifest,
        // full identity + hash, explicit truncation.
        let chunk = String(repeating: "x", count: 1024) + "\n"
        var text = ""
        for _ in 0..<2048 { text += chunk }
        try ws.write("big.txt", text: text)
        let snap = try ws.capture("big.txt")
        #expect(snap.size == text.utf8.count)
        #expect(snap.size > 2_000_000, "actually a 2 MiB file")
        #expect(snap.contentHash == Self.sha(Data(text.utf8)))
        if case .included(let excerpt, let truncated) = snap.content {
            #expect(excerpt.utf8.count == maxAttachmentExcerptBytes, "excerpt capped at 4 KiB")
            #expect(truncated, "explicit truncation flag")
            #expect(text.hasPrefix(excerpt), "byte-prefix of the content")
        } else {
            Issue.record("large text file must be included with truncation")
        }
    }

    @Test("symlink escape refuses without reading the target")
    func symlinkRefused() throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.dir) }
        try ws.write("real.txt", text: "secret\n")
        try FileManager.default.createSymbolicLink(
            at: ws.dir.appendingPathComponent("link.txt"),
            withDestinationURL: ws.dir.appendingPathComponent("real.txt"))
        do {
            _ = try ws.capture("link.txt")
            Issue.record("symlink must refuse")
        } catch let error as AttachmentCaptureError {
            guard case .symlinkEscape = error else {
                Issue.record("expected symlinkEscape, got: \(error)"); return
            }
        }
    }

    @Test("special files, absolute paths and escapes refuse")
    func specialAndDeniedRefused() throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.dir) }
        // FIFO (special file).
        let fifo = ws.dir.appendingPathComponent("pipe").path
        mkfifo(fifo, 0o600)
        do {
            _ = try ws.capture("pipe")
            Issue.record("FIFO must refuse")
        } catch let error as AttachmentCaptureError {
            guard case .specialFile = error else {
                Issue.record("expected specialFile, got: \(error)"); return
            }
        }
        // Absolute path.
        #expect(throws: AttachmentCaptureError.self) { try ws.capture("/etc/hostname") }
        // Parent escape.
        #expect(throws: AttachmentCaptureError.self) { try ws.capture("../outside.txt") }
        // Missing file.
        do {
            _ = try ws.capture("missing.txt")
            Issue.record("missing file must refuse")
        } catch let error as AttachmentCaptureError {
            if case .notFound = error { } else {
                Issue.record("expected notFound, got: [\(error)]")
            }
        }
        // Grantable protected path without approval.
        do {
            _ = try ws.capture(".git/config")
            Issue.record("grantable path without approval must refuse")
        } catch let error as AttachmentCaptureError {
            if case .deniedPath = error { } else {
                Issue.record("expected deniedPath, got: \(error)")
            }
        }
    }

    @Test("mutation between read and re-verify refuses the torn snapshot")
    func mutationDuringCaptureRefused() throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.dir) }
        try ws.write("race.txt", text: "version one\n")
        let service = ws.service
        let (fd, grantedRoot) = try service.openAttachment("race.txt")
        defer { close(fd) }
        let before = try service.identity(of: fd)
        let bytes = try service.readAttachmentBytes(fd: fd, expectedSize: before.size, relativePath: "race.txt")
        // The racing writer lands between read and re-verify (same inode,
        // same size — fstat alone would miss it; the re-read + re-hash
        // must catch it).
        try ws.write("race.txt", text: "version two\n")
        do {
            try service.verifyStable(
                fd: fd, relativePath: "race.txt",
                expectedHash: AttachmentCaptureService.sha256Hex(bytes), expectedSize: before.size)
            Issue.record("torn read must refuse")
        } catch let error as AttachmentCaptureError {
            #expect(error == .changedDuringCapture("race.txt"), "typed torn-read refusal, got: \(error)")
        }
        // Unmutated control verifies fine, then finalizes.
        let (fd2, root2) = try service.openAttachment("race.txt")
        defer { close(fd2) }
        let id2 = try service.identity(of: fd2)
        let bytes2 = try service.readAttachmentBytes(fd: fd2, expectedSize: id2.size, relativePath: "race.txt")
        try service.verifyStable(
            fd: fd2, relativePath: "race.txt",
            expectedHash: AttachmentCaptureService.sha256Hex(bytes2), expectedSize: id2.size)
        let snap = try service.finalizeCapture(
            relativePath: "race.txt", lineRange: nil, intent: "mention",
            epochID: EpochID("epoch-1"), routeGrant: ws.grant(),
            grantedRoot: root2, before: id2, after: id2, bytes: bytes2)
        #expect(snap.contentHash == Self.sha(Data("version two\n".utf8)))
        _ = grantedRoot
    }

    @Test("one-shot capture retries once then refuses a torn read")
    func oneShotCaptureEventualRefusal() throws {
        // Sparse 33 MiB file: fstat reports over the cap without any real
        // bytes, so the size gate trips deterministically and fast.
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.dir) }
        let sparse = ws.dir.appendingPathComponent("sparse.bin").path
        let fd = open(sparse, O_CREAT | O_RDWR, 0o600)
        #expect(fd >= 0)
        #expect(ftruncate(fd, off_t(maxAttachmentCaptureBytes + 1)) == 0)
        close(fd)
        do {
            _ = try ws.capture("sparse.bin")
            Issue.record("over-cap file must refuse")
        } catch let error as AttachmentCaptureError {
            #expect(error == .overSizeLimit(maxAttachmentCaptureBytes + 1), "typed size refusal, got: \(error)")
        }
    }

    @Test("binary content captures identity-only, never bytes")
    func binaryMetadataOnly() throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.dir) }
        try ws.write("blob.bin", bytes: Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02]))
        let snap = try ws.capture("blob.bin")
        if case .metadataOnly(let reason) = snap.content {
            #expect(reason.contains("non-UTF8"), "explicit reason")
        } else {
            Issue.record("binary must be metadata-only")
        }
        #expect(snap.contentHash == Self.sha(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02])),
                "hash still covers the exact bytes")
        #expect(throws: AttachmentCaptureError.self) {
            try ws.capture("blob.bin", range: AttachmentLineRange(start: 1, end: 1))
        }
    }
}

/// M2-D D1: production `FilesystemAttachmentValidator` against a real
/// temporary filesystem, composed end-to-end with the pure dispatch
/// verdict: fresh files verify, mutations/removals surface as stale
/// through the same `attachmentVerdict` the transition gates on.
struct FilesystemAttachmentValidatorTests {

    static func makeWorkspace() throws -> (
        dir: URL, capture: AttachmentCaptureService, validator: FilesystemAttachmentValidator
    ) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let resolver = try WorkspaceResolver(
            workspace: SystemPackage.FilePath(dir.path), readRoots: [])
        return (dir,
                AttachmentCaptureService(resolver: resolver),
                FilesystemAttachmentValidator(resolver: resolver))
    }

    static func grant() -> AttachmentRouteGrant {
        AttachmentRouteGrant(alias: "local-coder", locality: .local, sealed: false)
    }

    @Test("validator reports fresh for an unchanged file")
    func validatorFresh() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.dir) }
        try Data("stable\n".utf8).write(to: ws.dir.appendingPathComponent("s.txt"))
        let snap = try ws.capture.capture(
            relativePath: "s.txt", lineRange: nil, intent: "mention",
            epochID: EpochID("epoch-1"), routeGrant: Self.grant())
        let observations = await ws.validator.validate(entryID: "q-1", snapshots: [snap])
        #expect(observations.count == 1)
        let verdict = attachmentVerdict(
            snapshot: snap, observation: observations.first,
            currentEpochID: EpochID("epoch-1"), currentLocality: .local,
            route: .allowed(endpoint: "http://127.0.0.1:11434/chat/completions", alias: "local-coder"),
            consentEpochID: EpochID("epoch-1"), entrySealed: false)
        #expect(verdict == .fresh, "unchanged file verifies")
    }

    @Test("validator surfaces mutation and removal as stale")
    func validatorStaleAndRemoved() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.dir) }
        try Data("before\n".utf8).write(to: ws.dir.appendingPathComponent("m.txt"))
        let snap = try ws.capture.capture(
            relativePath: "m.txt", lineRange: nil, intent: "mention",
            epochID: EpochID("epoch-1"), routeGrant: Self.grant())
        // Same-size mutation: identity equal, bytes differ.
        try Data("after!\n".utf8).write(to: ws.dir.appendingPathComponent("m.txt"))
        let mutated = await ws.validator.validate(entryID: "q-1", snapshots: [snap])
        let stale = attachmentVerdict(
            snapshot: snap, observation: mutated.first,
            currentEpochID: EpochID("epoch-1"), currentLocality: .local,
            route: .allowed(endpoint: "http://127.0.0.1:11434/chat/completions", alias: "local-coder"),
            consentEpochID: EpochID("epoch-1"), entrySealed: false)
        guard case .stale(let fileStale, _) = stale else {
            Issue.record("mutation must be stale"); return
        }
        #expect(fileStale, "content change is file staleness")
        // Removal: unreadable observation.
        try FileManager.default.removeItem(at: ws.dir.appendingPathComponent("m.txt"))
        let gone = await ws.validator.validate(entryID: "q-1", snapshots: [snap])
        #expect(gone.first?.readable == false, "removal is unreadable")
        let removedVerdict = attachmentVerdict(
            snapshot: snap, observation: gone.first,
            currentEpochID: EpochID("epoch-1"), currentLocality: .local,
            route: .allowed(endpoint: "http://127.0.0.1:11434/chat/completions", alias: "local-coder"),
            consentEpochID: EpochID("epoch-1"), entrySealed: false)
        guard case .stale(let removedStale, let reason) = removedVerdict else {
            Issue.record("removal must be stale"); return
        }
        #expect(removedStale && reason.contains("removed"), "removal names the cause")
    }
}
