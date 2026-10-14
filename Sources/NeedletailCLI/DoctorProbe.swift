import ArgumentParser
import Foundation
import NeedletailCore
import NeedletailRuntime
import NeedletailProviders

/// `needletail doctor --probe MODEL` (M1-C, NET-06 traffic half): validates
/// the alias and route purely, then sends ONE synthetic bounded request
/// (fixed literals, never workspace/history bytes) through the production
/// adapter and reports the fingerprint. Exit 0 qualified success, 2 config
/// errors (unchanged), 4 honest provider failures. No private data, no
/// discovery, no fallback — the route was authorized before dialing.
enum DoctorProbe {
    static func run(alias: String) throws {
        guard let path = defaultConfigPath() else {
            eprint("error $: configNotFound — no configuration file found for --probe. Fix: pass a config via --config or place one at ~/.config/needletail/config.json.")
            throw ExitCode(2)
        }
        let snapshot: ConfigSnapshot
        do {
            snapshot = try validateConfig(readBoundedFile(path))
        } catch let error as ConfigError {
            eprint("\(error)")
            throw ExitCode(2)
        } catch {
            eprint("error $: malformedJSON — \(error). Fix: validate the file as strict JSON first.")
            throw ExitCode(2)
        }
        guard snapshot.profiles[alias] != nil else {
            eprint("error $.models: missingReference — unknown model alias '\(terminalSafe(alias))'. Fix: probe one of: \(snapshot.profiles.keys.sorted().map(terminalSafe).joined(separator: ", ")).")
            throw ExitCode(2)
        }
        let probe: ProbeResult
        do {
            probe = try awaitProbe(snapshot: snapshot, alias: alias)
        } catch let error as ConfigError {
            eprint("\(error)")
            throw ExitCode(2)
        } catch {
            eprint("probe \(terminalSafe(alias)): provider failure: \(terminalSafe(String(describing: error)))")
            throw ExitCode(4)
        }
        print("probe \(terminalSafe(alias)): OK → \(probe.endpoint) model \(terminalSafe(probe.configuredModel))" +
            (probe.returnedModel.map { " served \(terminalSafe($0))" } ?? "") +
            " usage \(probe.usageInput.map(String.init) ?? "?")/\(probe.usageOutput.map(String.init) ?? "?")" +
            " in \(probe.elapsedMillis)ms")
    }

    /// Locked result box for the sync-over-async CLI bridge (Sendable by
    /// lock discipline; the semaphore bounds the wait).
    private final class ProbeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var output: Result<ProbeResult, Error>?

        func set(_ result: Result<ProbeResult, Error>) {
            lock.withLock { output = result }
        }

        func get() -> Result<ProbeResult, Error>? {
            lock.withLock { output }
        }
    }

    private static func awaitProbe(snapshot: ConfigSnapshot, alias: String) throws -> ProbeResult {
        // Bridge sync CLI into the async probe: a bounded semaphore wait
        // (the probe caps itself at 60 s internally, so this always lands).
        let semaphore = DispatchSemaphore(value: 0)
        let box = ProbeBox()
        Task {
            do {
                let result = try await probeRoute(
                    snapshot: snapshot, alias: alias,
                    credentialStore: EnvFileCredentialStore())
                box.set(.success(result))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        switch box.get() {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        case .none:
            throw TransportFailure(phase: .ambiguous, message: "probe produced nothing")
        }
    }
}
