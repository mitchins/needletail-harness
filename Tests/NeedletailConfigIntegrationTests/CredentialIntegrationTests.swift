import Testing
import Foundation
import Subprocess
import NeedletailCore
import NeedletailRuntime
import NeedletailProviders

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// CFG-03 (integration half) + NET-06 (offline half): real mode-0600 files,
/// controlled process environment, child-process environment scrubbing, the
/// Keychain stub over the real protocol, offline doctor, deferred probe, and
/// the Core↔Providers contract cross-checks. Still zero network.
struct CredentialIntegrationTests {

    @Test("CFG-03 mode-0600 credential file resolves, group-readable fails")
    func CFG_03_credentialFilePermissions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("needletail-m1a-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let okURL = dir.appendingPathComponent("ok.key")
        try "file-canary-aaa".write(to: okURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: okURL.path)
        let store = EnvFileCredentialStore()
        #expect(try store.resolve(CredentialReference(kind: .file(path: okURL.path)), for: "chat") == "file-canary-aaa")
        let badURL = dir.appendingPathComponent("bad.key")
        try "file-canary-bbb".write(to: badURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: badURL.path)
        do {
            _ = try store.resolve(CredentialReference(kind: .file(path: badURL.path)), for: "chat")
            Issue.record("0644 credential file must be refused")
        } catch let error as CredentialError {
            guard case .insecurePermissions = error else {
                Issue.record("wrong error: \(error)"); return
            }
            #expect(!error.description.contains("file-canary-bbb"), "denial must not echo bytes")
        }
    }

    @Test("CFG-03 keychain interface exists but is unsupported on Linux")
    func CFG_03_keychainStubUnsupported() throws {
        let store = KeychainCredentialStore()
        do {
            _ = try store.resolve(CredentialReference(kind: .keychain(account: "x")), for: "chat")
            Issue.record("keychain must throw on Linux")
        } catch let error as CredentialError {
            guard case .unsupportedOnLinux = error else {
                Issue.record("wrong error: \(error)"); return
            }
        }
    }

    @Test("CFG-03 non-regular files are refused without hanging or following")
    func CFG_03_nonRegularFilesRefused() throws {
        // S1: a writer-less FIFO must fail closed (O_NONBLOCK + S_ISREG),
        // never hang the open and never be read as config/credential input.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("needletail-m1a-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fifo = dir.appendingPathComponent("blocked.fifo").path
        #expect(mkfifo(fifo, 0o600) == 0, "fixture: mkfifo must succeed")
        do {
            _ = try readBoundedFile(fifo)
            Issue.record("FIFO must be refused")
        } catch let error as ConfigError {
            #expect(error.kind == .unsupportedFormat, "FIFO refusal, got \(error.kind)")
        }
        // A symlink to a valid file is likewise refused (never followed).
        let target = dir.appendingPathComponent("real.json").path
        try Data(ConfigTestHelpersData.localConfig()).write(to: URL(fileURLWithPath: target))
        let link = dir.appendingPathComponent("link.json").path
        #expect(symlink(target, link) == 0, "fixture: symlink must succeed")
        do {
            _ = try readBoundedFile(link)
            Issue.record("symlink must be refused")
        } catch let error as ConfigError {
            #expect(error.kind == .unsupportedFormat || error.kind == .configNotFound,
                    "symlink refusal, got \(error.kind)")
        }
        // Control: the regular target itself reads fine.
        #expect(try readBoundedFile(target).count == ConfigTestHelpersData.localConfig().count)
    }

    @Test("CFG-03 controlled environment resolves only the named variable")
    func CFG_03_controlledEnvResolution() throws {
        setenv("NT_M1A_INT_A", "env-canary-aaa", 1)
        defer { unsetenv("NT_M1A_INT_A") }
        let store = EnvFileCredentialStore()
        #expect(try store.resolve(CredentialReference(kind: .env(name: "NT_M1A_INT_A")), for: "probe-test") == "env-canary-aaa")
        do {
            _ = try store.resolve(CredentialReference(kind: .env(name: "NT_M1A_INT_ABSENT")), for: "probe-test")
            Issue.record("absent variable must fail")
        } catch let error as CredentialError {
            guard case .missingEnv(let name) = error else {
                Issue.record("wrong error: \(error)"); return
            }
            #expect(name == "NT_M1A_INT_ABSENT")
        }
    }

    @Test("CFG-03 secrets never reach child environments or diagnostics")
    func CFG_03_childEnvScrubbed() async throws {
        setenv("NT_M1A_INT_CHILD", "child-canary-zzz", 1)
        defer { unsetenv("NT_M1A_INT_CHILD") }
        let store = EnvFileCredentialStore()
        let value = try store.resolve(CredentialReference(kind: .env(name: "NT_M1A_INT_CHILD")), for: "chat")
        #expect(value == "child-canary-zzz")
        // Children get an explicit environment without the secret.
        let (code, out, _) = try await SpawnHelpers.run(
            ["doctor"], environment: .custom(["PATH": "/usr/bin:/bin"]))
        #expect(code == 0)
        #expect(!out.contains("child-canary-zzz"))
        // And diagnostics never render request_options values.
        let snapshot = try validateConfig(ConfigTestHelpersData.configWithCanary())
        #expect(!snapshot.redactedDescription.contains("options-canary-qqq"))
    }

    @Test("CFG-03 providers cross-check: wire protocol vocabulary matches core")
    func CFG_03_wireVocabularyMatches() throws {
        let coreNames = Set(WireProtocol.allCases.map(\.rawValue))
        let providerNames = Set(NativeProtocol.allCases.map(\.rawValue))
        #expect(coreNames == providerNames, "Core/Providers protocol strings must agree: \(coreNames) vs \(providerNames)")
        #expect(Set([Locality.local.rawValue, Locality.cloud.rawValue]) == Set([LocalityClass.local.rawValue, LocalityClass.cloud.rawValue]),
                "Core/Providers locality strings must agree (S11)")
        let snapshot = try validateConfig(ConfigTestHelpersData.localConfig())
        let profile = try #require(snapshot.profiles["local-coder"])
        #expect(try validateLocalChatProfile(profile) == profile)
        let cloudy = try ModelProfile(
            alias: profile.alias, wireProtocol: profile.wireProtocol, baseURL: profile.baseURL,
            modelID: profile.modelID, contextWindow: profile.contextWindow, maxOutput: profile.maxOutput,
            locality: .cloud, credential: profile.credential,
            connectTimeout: profile.connectTimeout, readIdleTimeout: profile.readIdleTimeout,
            requestTimeout: profile.requestTimeout, maxInFlight: profile.maxInFlight,
            requestOptions: profile.requestOptions, requestOptionsRaw: profile.requestOptionsRaw,
            unqualifiedOptions: profile.unqualifiedOptions)
        do {
            _ = try validateLocalChatProfile(cloudy)
            Issue.record("cloud profile must not validate as a local chat profile")
        } catch let error as ConfigError {
            #expect(error.kind == .unsupportedCombination)
        }
    }

    @Test("NET-06 doctor stays offline with redacted diagnostics")
    func NET_06_doctorOffline() async throws {
        let (code, out, err) = try await SpawnHelpers.run(["doctor"])
        #expect(code == 0, "doctor must succeed offline: \(out) \(err)")
        #expect(out.contains("needletail 0.3.0"))
        SpawnHelpers.assertNoCanary(out + err, canary: "child-canary-zzz", where: "doctor output")
    }

    @Test("NET-06 probe validates the route purely, then defers without traffic")
    func NET_06_probeDeferred() async throws {
        // Probe uses the default config location; point XDG at a temp dir.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("needletail-m1a-\(UUID().uuidString)", isDirectory: true)
        let cfgDir = dir.appendingPathComponent("needletail", isDirectory: true)
        try FileManager.default.createDirectory(at: cfgDir, withIntermediateDirectories: true)
        try ConfigTestHelpersData.localConfig().write(to: cfgDir.appendingPathComponent("config.json"))
        let env = Environment.custom(["PATH": "/usr/bin:/bin", "XDG_CONFIG_HOME": dir.path])
        let (code, out, _) = try await SpawnHelpers.run(["doctor", "--probe", "local-coder"], environment: env)
        #expect(code == 4, "probe defers with exit 4, got \(code): \(out)")
        #expect(out.contains("probeDeferredToM1C"), "deferral must be explicit: \(out)")
        #expect(out.contains("http://127.0.0.1:11434/chat/completions"), "validated endpoint shown: \(out)")
        let (code2, out2, _) = try await SpawnHelpers.run(["doctor", "--probe", "ghost"], environment: env)
        #expect(code2 == 2, "unknown probe alias is a config error: \(out2)")
    }
}

/// Byte fixtures shared by integration tests (kept here so the pure target
/// stays free of fixture data duplication).
enum ConfigTestHelpersData {
    static func localConfig() -> Data {
        Data("""
        {"version":1,"default_model":"local-coder","allow_http_origins":["http://127.0.0.1:11434"],"models":[{"alias":"local-coder","protocol":"openai-chat-completions","base_url":"http://127.0.0.1:11434","model":"qwen2.5-coder-32b","context_window":262144,"max_output":4096,"locality":"local","credential":{"env":"NT_M1A_KEY"},"connect_timeout_s":10,"read_idle_timeout_s":300,"request_timeout_s":1800,"max_in_flight":1,"request_options":{"temperature":0.2}}],"tools":{"read":true,"search":true,"edit":true,"write":true,"exec":"ask","consult":false}}
        """.utf8)
    }

    static func configWithCanary() -> Data {
        Data("""
        {"version":1,"default_model":"local-coder","allow_http_origins":["http://127.0.0.1:11434"],"models":[{"alias":"local-coder","protocol":"openai-chat-completions","base_url":"http://127.0.0.1:11434","model":"qwen2.5-coder-32b","context_window":262144,"max_output":4096,"locality":"local","credential":{"env":"NT_M1A_KEY"},"connect_timeout_s":10,"read_idle_timeout_s":300,"request_timeout_s":1800,"max_in_flight":1,"request_options":{"temperature":0.2,"note":"options-canary-qqq"}}],"tools":{"read":true,"search":true,"edit":true,"write":true,"exec":"ask","consult":false}}
        """.utf8)
    }
}
