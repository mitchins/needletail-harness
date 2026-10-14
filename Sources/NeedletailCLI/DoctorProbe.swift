import ArgumentParser
import Foundation
import NeedletailCore
import NeedletailRuntime

/// `needletail doctor --probe MODEL` (M1-A, NET-06 offline half): validates
/// the alias and route purely against the explicit user configuration, then
/// reports `probeDeferredToM1C` WITHOUT sending any traffic. The synthetic
/// bounded-input probe itself is M1-C transport work; this path must never
/// link the HTTP client (guarded by the ARCH import-gate test).
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
            eprint("error $.models: missingReference — unknown model alias '\(alias)'. Fix: probe one of: \(snapshot.profiles.keys.sorted().joined(separator: ", ")).")
            throw ExitCode(2)
        }
        switch selectRoute(snapshot: snapshot, requestedAlias: alias, sealed: false) {
        case .allowed(let endpoint, _):
            // H2: the alias is operator-supplied; the endpoint is validated ASCII.
            print("probe \(terminalSafe(alias)): route allowed → \(endpoint) (tool-free, sealed-capable)")
        case .denied(let denial):
            print("probe \(terminalSafe(alias)): route denied (\(denial.kind)): \(denial.message)")
        }
        // Deliberate exit-4 reuse (no SPEC deferral code): deferred, not failed.
        print("probeDeferredToM1C: synthetic bounded-input probe arrives in M1-C; no traffic sent.")
        throw ExitCode(4)
    }
}
