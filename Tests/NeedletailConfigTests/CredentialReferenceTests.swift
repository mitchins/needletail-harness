import Testing
import Foundation
import NeedletailCore

/// In-memory fake: records exactly which reference was resolved for which
/// operation, so tests prove resolution is scoped to one credential.
/// A lock guards the log (`@unchecked Sendable` with all state behind the
/// lock — the standard scripted-fake shape, no production semantics).
final class FakeCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    var values: [String: String] = [:]
    private var log: [(reference: String, operation: String)] = []

    var requests: [(reference: String, operation: String)] {
        lock.withLock { log }
    }

    func resolve(_ reference: CredentialReference, for operation: String) throws -> String {
        lock.withLock { log.append((reference.redactedDescription, operation)) }
        switch reference.kind {
        case .env(let name):
            guard let value = values["env:\(name)"] else { throw CredentialError.missingEnv(name: name) }
            return value
        case .file(let path):
            guard let value = values["file:\(path)"] else { throw CredentialError.unreadableFile(path: path, reason: "no such fixture") }
            return value
        case .keychain(let account):
            throw CredentialError.unsupportedOnLinux(what: "keychain:\(account)")
        }
    }
}

/// CFG-03 (pure half) — credential descriptors are exactly one reference;
/// only references are stored/exported; resolution is scoped to the named
/// operation. Forbidden: secret values in descriptions/diagnostics, resolving
/// more than requested, multi-kind descriptors.
struct CredentialReferenceTests {

    @Test("CFG-03 credential descriptor holds exactly one kind")
    func CFG_03_descriptorShapeStrict() throws {
        let two = ConfigTestHelpers.configJSON(
            models: [ConfigTestHelpers.modelJSON(credential: #"{"env":"A","file":"/x"}"#)])
        try ConfigTestHelpers.expectFailure(two, kind: .typeMismatch, pathFragment: "credential")
        let bogus = ConfigTestHelpers.configJSON(
            models: [ConfigTestHelpers.modelJSON(credential: #"{"env":"A","bogus":1}"#)])
        try ConfigTestHelpers.expectFailure(bogus, kind: .unknownField, pathFragment: "credential")
        let empty = ConfigTestHelpers.configJSON(
            models: [ConfigTestHelpers.modelJSON(credential: "{}")])
        try ConfigTestHelpers.expectFailure(empty, kind: .typeMismatch, pathFragment: "credential")
    }

    @Test("CFG-03 descriptions carry references, never secret values")
    func CFG_03_redaction() throws {
        let canary = "hunter2-bearer-canary"
        let ref = CredentialReference(kind: .env(name: "NT_M1A_KEY"))
        #expect(!ref.redactedDescription.contains(canary))
        #expect(ref.redactedDescription.contains("NT_M1A_KEY"))
        let store = FakeCredentialStore()
        store.values = ["env:NT_M1A_KEY": canary]
        let resolved = try store.resolve(ref, for: "chat")
        #expect(resolved == canary, "resolution itself returns the value to the caller")
        #expect(store.requests.count == 1 && store.requests[0].operation == "chat")
        let snapshot = try ConfigTestHelpers.validateData(ConfigTestHelpers.configJSON())
        #expect(!snapshot.redactedDescription.contains(canary))
    }

    @Test("CFG-03 resolution is scoped to the requested reference")
    func CFG_03_resolutionScoped() throws {
        let store = FakeCredentialStore()
        store.values = ["env:ONE": "1", "env:TWO": "2"]
        _ = try store.resolve(CredentialReference(kind: .env(name: "ONE")), for: "chat")
        #expect(store.requests.count == 1, "exactly one credential read, never a sweep")
        do {
            _ = try store.resolve(CredentialReference(kind: .env(name: "MISSING")), for: "chat")
            Issue.record("absent variable must fail")
        } catch let error as CredentialError {
            guard case .missingEnv(let name) = error else {
                Issue.record("wrong error: \(error)"); return
            }
            #expect(name == "MISSING")
            #expect(!error.description.contains("hunter2"))
        }
    }

    @Test("CFG-03 keychain descriptor validates while resolution lives in Runtime")
    func CFG_03_keychainDescriptorValidates() throws {
        // The descriptor itself validates here (interface preserved); the
        // stub's failing resolve is pinned in the integration suite, which
        // is the target that links NeedletailRuntime.
        let snapshot = try ConfigTestHelpers.validateData(ConfigTestHelpers.configJSON(
            models: [ConfigTestHelpers.modelJSON(credential: #"{"keychain":"svc-acct"}"#)]))
        #expect(snapshot.profiles["local-coder"]?.credential?.redactedDescription == "keychain:svc-acct")
    }
}
