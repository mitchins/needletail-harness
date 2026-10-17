#!/usr/bin/env python3
"""BDD-06 disposable wrong-implementation probes for M1-D.

Each probe removes one production guard, runs a NAMED oracle, retains the
failure output, and restores the source byte-identically. This is review
evidence only; the script is not a test, a product command, or a committed
fault switch.
"""
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOGS = ROOT / "plans"

def run(command):
    started = time.monotonic()
    completed = subprocess.run(
        command, cwd=str(ROOT), stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, text=True, errors="replace")
    return completed.returncode, time.monotonic() - started, completed.stdout

def patch_once(path, old, new):
    content = path.read_text()
    count = content.count(old)
    if count != 1:
        raise RuntimeError(f"probe patch for {path} expected exactly one match, found {count}")
    path.write_text(content.replace(old, new, 1))

def write_log(name, command, rc, seconds, output):
    LOGS.mkdir(exist_ok=True)
    log = LOGS / f"m1d-probe-{name}.log"
    log.write_text(
        f"probe: {name}\ncommand: {' '.join(command)}\nexit: {rc}\nseconds: {seconds:.2f}\n"
        f"output (retained, not summarized):\n{output}\n")
    print(f"PROBE {name}: exit={rc} log={log.relative_to(ROOT)}", flush=True)
    return log

def probe(name, patches, oracle, expected_marker, rebuild_release=False, release_oracle=False):
    snapshots = {path: path.read_bytes() for path, _, _ in patches}
    command = []
    rc = 0
    seconds = 0.0
    output = ""
    expected_rc = 1
    try:
        for path, old, new in patches:
            patch_once(path, old, new)
        if rebuild_release:
            command = ["swift", "build", "-c", "release", "--product", "needletail"]
            rc, seconds, output = run(command)
            if rc != 0:
                write_log(f"{name}-build", command, rc, seconds, output)
                raise RuntimeError(f"{name}: patched release build failed")
            command = [sys.executable, str(ROOT / "demo" / "m1d-negatives.py")]
        else:
            command = ["swift", "test", "--filter", oracle]
        rc, seconds, output = run(command)
        write_log(name, command, rc, seconds, output)
        if rc == 0:
            raise RuntimeError(f"{name}: probe oracle unexpectedly passed; guard removal was not observable")
        if expected_marker not in output:
            raise RuntimeError(f"{name}: patch failed without the expected oracle marker: {expected_marker}")
    finally:
        for path, original in snapshots.items():
            path.write_bytes(original)
        if rebuild_release:
            command = ["swift", "build", "-c", "release", "--product", "needletail"]
            build_rc, build_seconds, build_output = run(command)
            write_log(f"{name}-restore-build", command, build_rc, build_seconds, build_output)
            if build_rc != 0:
                raise RuntimeError(f"{name}: restored release build failed")

def main():
    backend = ROOT / "Sources" / "NeedletailProviders" / "ScriptedToolBackend.swift"
    transition = ROOT / "Sources" / "NeedletailCore" / "SessionTransition.swift"
    actor = ROOT / "Sources" / "NeedletailCore" / "SessionActor.swift"
    run_command = ROOT / "Sources" / "NeedletailCLI" / "RunCommand.swift"

    probe(
        "p10-digest-argument-bypass",
        [(backend,
          "        return jsonCanonical(a) == jsonCanonical(b)\n",
          "        return true // BDD06_PROBE: guard removed\n")],
        "BackendTests",
        "changed value mismatches honestly")

    probe(
        "p11-transcript-bypass",
        [(transition,
          "            // The dispatched operator text opens the transcript (D1).\n            .transcriptAppended(.user(text)),\n",
          "            // BDD06_PROBE: transcript bypass.\n            .eventAppended(seq: seq, kind: \"run-admitted-probe\", digest: \"probe\"),\n")],
        "TranscriptEmissionTests",
        "full text-plus-tool turn emits the ordered transcript")

    probe(
        "p12-delta-before-completion-removed",
        [(actor,
          "            deltaTransport.deltaSink = { text in\n                switch deliveryQueue.enqueue(DeltaDeliveryQueue.Item(requestID: requestID, text: text)) {\n                case .overflow(let itemCount, let byteCount):\n                    deliveryQueue.finish()\n                    Task { await self.handleSinkError(UISinkError.overflow(itemCount: itemCount, byteCount: byteCount)) }\n                case .accepted:\n                    break\n                }\n            }\n",
          "            deltaTransport.deltaSink = { _ in } // BDD06_PROBE: delta sink removed\n")],
        "BoundaryVerificationTests",
        "delta is observable before completion")

    probe(
        "p13-raw-ring-bound-removed",
        [(actor,
          "    private var rawRingMaxCount: Int { 8 }\n",
          "    private var rawRingMaxCount: Int { 9 }\n")],
        "BoundaryVerificationTests",
        "raw provider ring stays bounded")

    probe(
        "p14-cli-authorization-implicit-grant",
        [(run_command,
          "        let mode: TrustMode = trusted ? .trustedExec : .workspace\n        let workspaceGrant: ToolCapabilities = trusted ? .allAllowed : .allDenied\n",
          "        let mode: TrustMode = .trustedExec // BDD06_PROBE: implicit grant\n        let workspaceGrant: ToolCapabilities = .allAllowed\n")],
        "authorization-denied",
        "FAIL authorization-denied",
        rebuild_release=True,
        release_oracle=True)

    print("BDD-06 PROBES PASSED: every patched guard failed its named oracle; baseline restored", flush=True)

if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"BDD-06 PROBES FAILED: {error}", flush=True)
        raise SystemExit(1)
