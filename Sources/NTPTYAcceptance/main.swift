import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import NeedletailTestSupport
import PTYShim

/// NTPTYAcceptance — the standalone native PTY acceptance runner
/// (M4-MAC-06). Executes the actual release Needletail binary through a
/// real pty via the controlled posix_spawn+ctty bootstrap and the PTY
/// shim, INDEPENDENTLY of Swift Testing and `swift test`. Every
/// blocking operation is deadline-bounded; every phase is recorded;
/// failures preserve the transcript and diagnostics. Application
/// failures and harness failures are distinguished explicitly, and a
/// timed-out operation is never reported as a successful exit.

func mark(_ text: String) {
    let df = DateFormatter()
    df.dateFormat = "HH:mm:ss.SSS"
    FileHandle.standardError.write(Data("[\(df.string(from: Date()))] \(text)\n".utf8))
}

let runDir = "/tmp/ntpty-acceptance-\(Int(Date().timeIntervalSince1970))"

func dumpFailure(_ name: String, _ transcript: String, _ note: String) {
    try? FileManager.default.createDirectory(atPath: runDir, withIntermediateDirectories: true)
    let path = runDir + "/\(name)-failure.log"
    try? "NOTE: \(note)\n\nTRANSCRIPT:\n\(transcript)".write(toFile: path, atomically: true, encoding: .utf8)
    FileHandle.standardError.write(Data("  diagnostics: \(path)\n".utf8))
}

// MARK: - Config

let toolsNone = #"{"read":false,"search":false,"edit":false,"write":false,"exec":false,"consult":false}"#
let toolsWrite = #"{"read":false,"search":false,"edit":true,"write":true,"exec":false,"consult":false}"#

func makeConfig(directory: String, baseURL: String, tools: String) -> String {
    let configPath = directory + "/config.json"
    let json = """
    {"version":1,"default_model":"p","allow_http_origins":["\(baseURL)"],"models":[{"alias":"p","protocol":"openai-chat-completions","base_url":"\(baseURL)","model":"test-model","context_window":4096,"max_output":128,"locality":"local","credential":{"env":"NEEDLETAIL_CHAT_TEST_KEY"},"connect_timeout_s":5,"read_idle_timeout_s":120,"request_timeout_s":300,"max_in_flight":1}],"tools":\(tools)}
    """
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    try? Data(json.utf8).write(to: URL(fileURLWithPath: configPath))
    return configPath
}

// MARK: - Child environment

/// The COMPLETE child environment built in the parent: the full
/// inherited environment with the child-only overrides applied and the
/// removed keys (bare names) dropped. Only valid KEY=VALUE entries
/// reach posix_spawn. NEEDLETAIL_REQUEST_BUDGET is explicitly removed
/// (an inherited budget from another suite must not cap the binary).
func mergedChildEnv(_ extra: [String: String]) -> [String] {
    var overrideMap: [String: String?] = [:]
    for (k, v) in extra { overrideMap[k] = .some(v) }
    overrideMap["NEEDLETAIL_REQUEST_BUDGET"] = nil
    var merged: [String] = []
    for (k, v) in ProcessInfo.processInfo.environment {
        if let override = overrideMap[k] {
            if let value = override { merged.append("\(k)=\(value)") }
            continue
        }
        merged.append("\(k)=\(v)")
    }
    for (k, override) in overrideMap where ProcessInfo.processInfo.environment[k] == nil {
        if let value = override { merged.append("\(k)=\(value)") }
    }
    return merged
}

// MARK: - Session (deadline-bounded driver over the shim)

final class Session {
    var pty = nt_pty_t()
    let launcher: String
    let bootstrapPath: String
    private(set) var transcript = ""
    private(set) var started = false
    private(set) var reaped = false
    private(set) var rawExitStatus: Int32?

    init(launcher: String, bootstrapPath: String) {
        self.launcher = launcher
        self.bootstrapPath = bootstrapPath
    }

    func start(binary: String, args: [String], overrides: [String: String]) -> Bool {
        mark("phase: launch (\(launcher))")
        // The child argv is prebuilt by the caller of the C entry point:
        // [bootstrap, executable, args..., NULL].
        var childC: [UnsafeMutablePointer<CChar>?] = [strdup(bootstrapPath), strdup(binary)]
        for a in args { childC.append(strdup(a)) }
        childC.append(nil)
        var envC = mergedChildEnv(overrides).map { strdup($0) }
        envC.append(nil)
        var spawnResult: Int32 = -1
        spawnResult = childC.withUnsafeMutableBufferPointer { childBuf in
            envC.withUnsafeMutableBufferPointer { envBuf in
                nt_pty_spawn_posix_ctty(&pty, childBuf.baseAddress!, envBuf.baseAddress!)
            }
        }
        for p in childC where p != nil { free(p) }
        for p in envC where p != nil { free(p) }
        guard spawnResult == 0 else {
            mark("FAIL: spawn rc=\(spawnResult) errno=\(errno)")
            return false
        }
        started = true
        mark("spawned pid=\(pty.childPid)")
        return true
    }

    func pump(timeoutMS: Int32) {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = nt_pty_read(&pty, &buf, buf.count, timeoutMS)
        if n > 0 { transcript += String(decoding: buf[0 ..< Int(n)], as: UTF8.self) }
    }

    func expect(_ marker: String, timeoutMS: Int32) -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000)
        while Date() < deadline {
            if transcript.contains(marker) { return true }
            pump(timeoutMS: 200)
        }
        return false
    }

    func send(_ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBufferPointer { b in
            nt_pty_write(&pty, b.baseAddress!, b.count) == 0
        }
    }

    /// Quiet-window helper: waits until the transcript stops growing.
    func waitForQuiet(timeoutMS: Int32) {
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000)
        while Date() < deadline {
            let mark = transcript.unicodeScalars.count
            usleep(400_000)
            if transcript.unicodeScalars.count == mark { return }
        }
    }

    /// M4-MAC-06A: output draining is INTERLEAVED with bounded reaping —
    /// the master is pumped while waitpid(WNOHANG) polls, so final output
    /// (dispatch/teardown markers) is captured before the exit verdict.
    func waitExitDraining(timeoutMS: Int32) -> Int32? {
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000)
        while Date() < deadline {
            pump(timeoutMS: 200)
            let status = nt_pty_wait(&pty, 0) // WNOHANG-style bounded poll
            if status >= 0 {
                rawExitStatus = status
                reaped = childReapedState(&pty) == NT_CHILD_REAPED_BY_WAIT
                pump(timeoutMS: 300) // the final output the child wrote before exiting
                return status
            }
            if childReapedState(&pty) == NT_CHILD_REAPED_ECHILD {
                reaped = true
                pump(timeoutMS: 300)
                return nil // reaped elsewhere: the exit status is unrecordable
            }
        }
        return nil
    }

    var rawModeActive: Bool {
        var t = termios()
        guard nt_pty_slave_termios(&pty, &t) == 0 else { return false }
        return (t.c_lflag & tcflag_t(ICANON)) == 0 && (t.c_lflag & tcflag_t(ECHO)) == 0
    }

    var restoredExactly: Bool {
        nt_pty_termios_restored_exactly(&pty) == 1
    }

    func teardown() {
        mark("phase: teardown")
        nt_pty_close(&pty)
        mark("teardown: \(String(cString: nt_last_reap_report_cstr()))")
    }
}

// MARK: - The PTY-01 contract

/// Returns nil on success, or a failure description tagged
/// "application:" / "terminal:" / "harness:" / "bootstrap:".
func runPty01(binary: String, bootstrap: String, rep: Int, trace: Bool) -> String? {
    let name = "pty01-rep\(rep)"
    // M4-MAC-06A item 4: the trace is REQUIRED on every repetition — the
    // exec-ok post-exec marker and the Ctrl+C processing markers are
    // trace-only, so a default invocation must be capable of passing.
    var overrides = ["NEEDLETAIL_CHAT_TEST_KEY": "acceptance-key",
                     "NB_TEARDOWN_TRACE": "1",
                     "NB_INPUT_TRACE": "1"]
    let dir = runDir + "/" + name
    let config = makeConfig(directory: dir, baseURL: "http://127.0.0.1:9", tools: toolsNone)

    let session = Session(launcher: "posix-ctty", bootstrapPath: bootstrap)
    defer { session.teardown() }

    guard session.start(binary: binary, args: ["chat", "--config", config], overrides: overrides) else {
        dumpFailure(name, session.transcript, "harness: spawn failed")
        return "harness: spawn failed"
    }

    // Bootstrap phases (trace-gated): terminal acquisition + ownership.
    if trace {
        guard session.expect("BOOTSTRAP:ctty-ok", timeoutMS: 15_000) else {
            dumpFailure(name, session.transcript, "bootstrap: ctty acquisition not observed")
            return "bootstrap: terminal acquisition not observed"
        }
        guard session.expect("BOOTSTRAP:fg-ok", timeoutMS: 15_000) else {
            dumpFailure(name, session.transcript, "bootstrap: foreground ownership not observed")
            return "bootstrap: foreground ownership not observed"
        }
    }

    // The application executed (its own post-launch marker) and the
    // prompt rendered (the marker is trace-backed: the trace is always on).
    guard session.expect("exec-ok chat entry", timeoutMS: 30_000) else {
        dumpFailure(name, session.transcript, "application: no post-launch marker (or prompt missing)")
        return "application: startup not confirmed"
    }
    guard session.expect("needletail> ", timeoutMS: 30_000) else {
        dumpFailure(name, session.transcript, "application: prompt never rendered")
        return "application: no prompt"
    }

    // Raw mode active at injection time (ICANON and ECHO clear).
    guard session.rawModeActive else {
        dumpFailure(name, session.transcript, "terminal: raw mode not active before injection")
        return "terminal: raw mode not active"
    }

    // Inject 0x03; the write must succeed.
    guard session.send([0x03]) else {
        dumpFailure(name, session.transcript, "harness: 0x03 write failed")
        return "harness: 0x03 write failed"
    }

    // Normal exit within the bound.
    guard let raw = session.waitExitDraining(timeoutMS: 15_000) else {
        dumpFailure(name, session.transcript, "application: no exit after Ctrl+C")
        return "application: no exit after Ctrl+C"
    }
    // Decode the raw wait status honestly (the exited/signal distinction).
    let exited = (raw & 0x7f) == 0
    let exitCode = exited ? ((raw >> 8) & 0xff) : -1
    let termSig = exited ? -1 : (raw & 0x7f)
    mark("raw status=\(raw) exited=\(exited) code=\(exitCode) termsig=\(termSig)")
    // The input handler processed Ctrl+C (trace-gated): the teardown
    // breadcrumbs show the EOF path ran; the exact restoration below is
    // only reachable through that path.
    guard session.transcript.contains("[tt] eof armed="),
          session.transcript.contains("restore") else {
        dumpFailure(name, session.transcript, "application: Ctrl+C processing markers absent")
        return "application: Ctrl+C processing not observed"
    }
    guard exited, exitCode == 0 else {
        dumpFailure(name, session.transcript, "application: abnormal termination raw=\(raw) code=\(exitCode) termsig=\(termSig)")
        return "application: abnormal termination raw=\(raw) code=\(exitCode) termsig=\(termSig)"
    }
    mark("exit code 0")

    // The exact restoration.
    guard session.restoredExactly else {
        dumpFailure(name, session.transcript, "terminal: exact restoration failed")
        return "terminal: exact restoration failed"
    }

    // Reaped; no surviving owned processes; the reaping report explicit.
    guard session.reaped else {
        dumpFailure(name, session.transcript, "harness: child not reaped")
        return "harness: child not reaped"
    }
    // The teardown runs BEFORE the reaping report is read (the report is
    // produced by the bounded teardown itself).
    session.teardown()
    let report = String(cString: nt_last_reap_report_cstr())
    guard report.hasPrefix("reaped") || report.hasPrefix("already-reaped") else {
        dumpFailure(name, session.transcript, "harness: \(report)")
        return "harness: \(report)"
    }
    mark("reaping: \(report)")
    return nil
}

// MARK: - Entry

var binaryPath = ""
var bootstrapPath = ""
var reps = 5
var traceRun = false
var caseName = "pty01"

var iter = CommandLine.arguments.makeIterator()
while let arg = iter.next() {
    switch arg {
    case "--reps": reps = Int(iter.next() ?? "5") ?? 5
    case "--trace": traceRun = true
    case "--case": caseName = iter.next() ?? "pty01"
    case "--binary": binaryPath = iter.next() ?? ""
    case "--bootstrap": bootstrapPath = iter.next() ?? ""
    default: break
    }
}
let selfDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
if binaryPath.isEmpty { binaryPath = selfDir + "/needletail" }
if bootstrapPath.isEmpty { bootstrapPath = selfDir + "/NTPTYBootstrap" }
guard FileManager.default.fileExists(atPath: binaryPath) else {
    FileHandle.standardError.write(Data("binary missing: \(binaryPath)\n".utf8)); exit(2)
}
guard FileManager.default.fileExists(atPath: bootstrapPath) else {
    FileHandle.standardError.write(Data("bootstrap missing: \(bootstrapPath)\n".utf8)); exit(2)
}
mark("runner: binary=\(binaryPath) case=\(caseName) reps=\(reps) trace=\(traceRun)")

struct CaseResult {
    let name: String
    let passed: Bool
    let detail: String
}

// M4-MAC-06A item 5: prove the runner itself with the input fixture —
// a byte goes in, an observable post-input marker comes out, the exit
// status is 0, the bounded wait works, and the reaping is recorded.
func runFixture(selfDir: String, bootstrapPath: String) -> CaseResult {
    let fixture = selfDir + "/NTPTYInputFixture"
    guard FileManager.default.fileExists(atPath: fixture) else {
        return CaseResult(name: "fixture", passed: false, detail: "harness: fixture missing at \(fixture)")
    }
    let session = Session(launcher: "posix-ctty", bootstrapPath: bootstrapPath)
    defer { session.teardown() }
    guard session.start(binary: fixture, args: [], overrides: [:]) else {
        return CaseResult(name: "fixture", passed: false, detail: "harness: spawn failed")
    }
    usleep(200_000)
    // The fixture reads canonically (no raw mode): the byte needs the
    // line terminator to be delivered by the line discipline.
    guard session.send([UInt8(ascii: "x"), UInt8(ascii: "\n")]) else {
        return CaseResult(name: "fixture", passed: false, detail: "harness: the input write failed")
    }
    guard session.expect("FIXTURE:post-input-marker", timeoutMS: 10_000) else {
        dumpFailure("fixture", session.transcript, "harness: the post-input marker was never captured")
        return CaseResult(name: "fixture", passed: false, detail: "harness: the marker was not captured (byte delivery or capture failed)")
    }
    guard let raw = session.waitExitDraining(timeoutMS: 10_000), raw == 0 else {
        dumpFailure("fixture", session.transcript, "harness: the fixture did not exit 0")
        return CaseResult(name: "fixture", passed: false, detail: "harness: the fixture did not exit 0")
    }
    session.teardown()
    let report = String(cString: nt_last_reap_report_cstr())
    guard report.hasPrefix("reaped") || report.hasPrefix("already-reaped") else {
        return CaseResult(name: "fixture", passed: false, detail: "harness: \(report)")
    }
    return CaseResult(name: "fixture", passed: true, detail: report)
}

// M4-MAC-06A item 3: the child-environment proof. The fixture prints
// one variable; the budget must be ABSENT and an ordinary inherited
// variable must survive.
func runEnvProof(selfDir: String, bootstrapPath: String) -> [CaseResult] {
    let fixture = selfDir + "/NTPTYInputFixture"
    var results: [CaseResult] = []
    let budgetKey = "NEEDLETAIL_REQUEST_BUDGET"
    let homeKey = "HOME"
    let envCases: [(key: String, mustBeAbsent: Bool)] = [(budgetKey, true), (homeKey, false)]
    for (key, mustBeAbsent) in envCases {
        let session = Session(launcher: "posix-ctty", bootstrapPath: bootstrapPath)
        defer { session.teardown() }
        guard session.start(binary: fixture, args: ["envdump", key],
                            overrides: ["NEEDLETAIL_CHAT_TEST_KEY": "acceptance-key"]) else {
            results.append(CaseResult(name: "env-\(key)", passed: false, detail: "harness: spawn failed"))
            continue
        }
        var out = ""
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = nt_pty_read(&session.pty, &buf, buf.count, 200)
            if n > 0 { out += String(decoding: buf[0 ..< Int(n)], as: UTF8.self) }
            if out.contains("ENV:\(key)=") { break }
        }
        if mustBeAbsent {
            let absent = out.contains("ENV:\(key)=ABSENT")
            results.append(CaseResult(name: "env-\(key)", passed: absent, detail: absent ? "removed key absent from the child" : "REMOVAL FAILED"))
        } else {
            let present = out.contains("ENV:\(key)=") && !out.contains("ENV:\(key)=ABSENT")
            results.append(CaseResult(name: "env-\(key)", passed: present, detail: present ? "the inherited variable survives" : "the inherited variable was lost"))
        }
    }
    return results
}

if caseName == "fixture" {
    let r = runFixture(selfDir: selfDir, bootstrapPath: bootstrapPath)
    mark("\(r.name): \(r.passed ? "PASS" : "FAIL") — \(r.detail)")
    exit(r.passed ? 0 : 1)
}
if caseName == "env" {
    var all = true
    for r in runEnvProof(selfDir: selfDir, bootstrapPath: bootstrapPath) {
        mark("\(r.name): \(r.passed ? "PASS" : "FAIL") — \(r.detail)")
        all = all && r.passed
    }
    exit(all ? 0 : 1)
}
if caseName != "pty01" {
    FileHandle.standardError.write(Data("cases: pty01, fixture, env\n".utf8))
    exit(2)
}

func name_(rep: Int) -> String { "pty01-rep\(rep)" }

var failures = 0
for rep in 1 ... reps {
    // The last repetition is the diagnostic run (the trace on).
    let trace = traceRun || rep == reps
    if let failure = runPty01(binary: binaryPath, bootstrap: bootstrapPath, rep: rep, trace: trace) {
        mark("FAIL \(name_(rep: rep)): \(failure)")
        failures += 1
        mark("STOP on the first failing repetition — preserving diagnostics in \(runDir)")
        break
    }
    mark("PASS pty01-rep\(rep)")
}

if failures == 0 {
    mark("ACCEPTANCE: all \(reps) repetitions passed")
    exit(0)
}
exit(1)
