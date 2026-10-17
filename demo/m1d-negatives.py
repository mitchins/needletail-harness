#!/usr/bin/env python3
"""M1-D negative demonstrations through the RELEASE binary.

One synthetic loopback endpoint (`demo/m1d-server.py --mode ...`) is reused
for every scenario. Each scenario drives `needletail run --format jsonl`,
captures requests, and asserts the observable boundary: exit code, JSONL
envelope, transcript effect, connection/request count, control-byte safety.

No real filesystem, cloud access, or package installs are involved.
"""
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
BINARY = REPO / ".build" / "release" / "needletail"
SERVER = REPO / "demo" / "m1d-server.py"
PROMPT = "negative demonstration prompt"

class Failure(Exception):
    pass

def require(condition, message):
    if not condition:
        raise Failure(message)

def json_lines(data):
    if isinstance(data, bytes):
        text = data.decode("utf-8", errors="replace")
    else:
        text = data
    out = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            # Raw diagnostics are not JSONL and never counted as envelopes.
            continue
    return out

def read_capture(path):
    p = Path(path)
    if not p.exists():
        return []
    return [json.loads(line) for line in p.read_text(errors="replace").splitlines() if line.strip()]

@contextmanager
def endpoint(mode):
    with tempfile.TemporaryDirectory(prefix="m1d-neg-") as tmp:
        capture = Path(tmp) / "capture.jsonl"
        proc = subprocess.Popen(
            [sys.executable, str(SERVER), "--capture", str(capture), "--mode", mode],
            cwd=str(REPO), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        try:
            line = proc.stdout.readline().strip()
            require(line.startswith("PORT:"), f"{mode}: server did not announce a port")
            port = int(line.split(":", 1)[1])
            try:
                yield port, capture
            finally:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)
        finally:
            if proc.stdout:
                proc.stdout.close()

def write_config(path, port, exec_policy=True):
    path = Path(path)
    path.write_text(json.dumps({
        "version": 1,
        "default_model": "loop",
        "allow_http_origins": [f"http://127.0.0.1:{port}"],
        "models": [{
            "alias": "loop",
            "protocol": "openai-chat-completions",
            "base_url": f"http://127.0.0.1:{port}",
            "model": "test-model",
            "context_window": 4096,
            "max_output": 128,
            "locality": "local",
            "credential": {"env": "NEEDLETAIL_LOOPBACK_TEST_KEY"},
            "connect_timeout_s": 5,
            "read_idle_timeout_s": 10,
            "request_timeout_s": 60,
            "max_in_flight": 1,
        }],
        "tools": {
            "read": True, "search": True, "edit": True, "write": True,
            "exec": exec_policy, "consult": True,
        },
    }, separators=(",", ":")))
    return path

def write_tools(path, count):
    entries = [{
        "tool": "read",
        "arguments": json.dumps({"path": "src/main.py"}, separators=(",", ":")),
        "result": "scripted read result",
    } for _ in range(count)]
    Path(path).write_text(json.dumps(entries, separators=(",", ":")))
    return path

def cli_env():
    env = os.environ.copy()
    env["NEEDLETAIL_LOOPBACK_TEST_KEY"] = "loopback-test-secret"
    return env

def cli_command(config, trace=None, tools=None, trusted=False, sealed=False, max_turns=None):
    cmd = [
        str(BINARY), "run", "--config", str(config), "--prompt", PROMPT,
        "--format", "jsonl", "--alias", "loop",
    ]
    if trace is not None:
        cmd += ["--trace", str(trace)]
    if tools is not None:
        cmd += ["--tools", str(tools)]
    if trusted:
        cmd += ["--trusted"]
    if sealed:
        cmd += ["--sealed"]
    if max_turns is not None:
        cmd += ["--max-turns", str(max_turns)]
    return cmd

def run_cli(config, trace=None, tools=None, trusted=False, sealed=False, max_turns=None, timeout=30):
    cmd = cli_command(config, trace, tools, trusted, sealed, max_turns)
    return subprocess.run(
        cmd, cwd=str(REPO), env=cli_env(), stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, timeout=timeout, check=False)

# MARK: Scenarios

def authorization_denied(work):
    with endpoint("deny-edit") as (port, capture):
        cfg = write_config(work / "deny.json", port, exec_policy=True)
        result = run_cli(cfg)
        require(result.returncode == 0, f"denied fixture completed, got {result.returncode}")
        envelopes = json_lines(result.stdout)
        require(any(e.get("kind") == "denied" for e in envelopes), "no denied envelope")
        require(envelopes and envelopes[-1].get("kind") == "run_finished", "run_finished not last")
        requests = read_capture(capture)
        require(len(requests) == 2, f"deny loop made {len(requests)} requests")
        require(
            "denied: tools denied by effective capabilities" in requests[1]["body"],
            "denial did not ride the transcript as a tool response")

def approval_required(work):
    with endpoint("approval-exec") as (port, capture):
        cfg = write_config(work / "ask.json", port, exec_policy="ask")
        result = run_cli(cfg, trusted=True, timeout=10)
        require(result.returncode == 3, f"approval-required exit, got {result.returncode}")
        envelopes = json_lines(result.stdout)
        require(any(e.get("kind") == "run_finished" for e in envelopes), "no terminal envelope")
        require(b"approval_required" in result.stdout, "missing approval_required envelope")
        require(len(read_capture(capture)) == 1, "approval stop must not re-dial")
        require(b"approval required" in result.stderr, "missing approval diagnostic")

def sealed_tool_free(work):
    with endpoint("sealed") as (port, capture):
        cfg = write_config(work / "sealed.json", port, exec_policy=True)
        result = run_cli(cfg, sealed=True)
        require(result.returncode == 4, f"sealed protocol stop, got {result.returncode}")
        require(b"sealed response proposed tools" in result.stdout + result.stderr,
                "sealed stop did not identify the protocol violation")

def malformed_arguments(work):
    with endpoint("malformed-args") as (port, capture):
        cfg = write_config(work / "badargs.json", port, exec_policy=True)
        tools = write_tools(work / "badargs-tools.json", 1)
        result = run_cli(cfg, tools=tools, trusted=True)
        require(result.returncode == 4, f"malformed args stop, got {result.returncode}")
        require(len(read_capture(capture)) == 1, "malformed batch must not execute/re-dial")

def incomplete_completion(work):
    with endpoint("incomplete") as (port, capture):
        cfg = write_config(work / "incomplete.json", port, exec_policy=True)
        result = run_cli(cfg, trusted=True)
        require(result.returncode == 4, f"incomplete stream stop, got {result.returncode}")
        envelopes = json_lines(result.stdout)
        require(any("provider_error" in str(e.get("payload", "")) for e in envelopes),
                "incomplete stream not surfaced as provider_error")

def turn_exhaustion(work):
    with endpoint("exhaust") as (port, capture):
        cfg = write_config(work / "exhaust.json", port, exec_policy=True)
        tools = write_tools(work / "exhaust-tools.json", 5)
        result = run_cli(cfg, tools=tools, trusted=True, max_turns=3)
        require(result.returncode == 5, f"budget exhaustion exit, got {result.returncode}")
        require(len(read_capture(capture)) == 3, "explicit --max-turns was not honoured")
        require(b"budget_exhausted" in result.stdout, "budget failure envelope missing")

def midstream_abort_no_resend(work):
    with endpoint("abort") as (port, capture):
        cfg = write_config(work / "abort.json", port, exec_policy=True)
        result = run_cli(cfg, trusted=True, timeout=15)
        require(result.returncode == 4, f"mid-stream FIN stop, got {result.returncode}")
        require(len(read_capture(capture)) == 1, "mid-stream failure must never resend blindly")

def cancel_mid_stream(work):
    with endpoint("slow-delta") as (port, capture):
        cfg = write_config(work / "cancel.json", port, exec_policy=True)
        trace = work / "cancel.trace.jsonl"
        cmd = cli_command(cfg, trace=trace, trusted=True)
        proc = subprocess.Popen(
            cmd, cwd=str(REPO), env=cli_env(),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        saw_delta = False
        for raw in proc.stdout:
            line = raw.decode("utf-8", errors="replace")
            envelope = json_lines(line)
            if any(e.get("kind") == "delta" for e in envelope):
                saw_delta = True
                break
        require(saw_delta, "no delta observed before cancellation")
        proc.send_signal(signal.SIGINT)
        try:
            _, stderr = proc.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()
            raise Failure("cancellation did not terminate promptly")
        require(proc.returncode in (-int(signal.SIGINT), 130),
                f"cancellation exit, got {proc.returncode}")
        envelopes = json_lines(Path(trace).read_bytes())
        interrupted = [e for e in envelopes if e.get("kind") == "run_finished" and (
            (isinstance(e.get("payload"), dict) and
             e["payload"].get("outcome") == "interrupted") or
            e.get("payload") == "interrupted:"
        )]
        require(bool(interrupted), f"graceful cancellation must emit terminal run_finished/interrupted, got {envelopes}")

def closed_stdout_backpressure(work):
    with endpoint("slow-delta") as (port, capture):
        cfg = write_config(work / "pipe.json", port, exec_policy=True)
        trace = work / "pipe.trace.jsonl"
        cmd = cli_command(cfg, trace=trace, trusted=True)
        proc = subprocess.Popen(
            cmd, cwd=str(REPO), env=cli_env(),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        saw_delta = False
        for raw in proc.stdout:
            line = raw.decode("utf-8", errors="replace")
            envelope = json_lines(line)
            if any(e.get("kind") == "delta" for e in envelope):
                saw_delta = True
                break
        require(saw_delta, "no delta observed before closing the consumer")
        proc.stdout.close()
        try:
            _, stderr = proc.communicate(timeout=20)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()
            raise Failure("closed consumer did not terminate terminating the run")
        require(proc.returncode == 130,
                f"closed stdout maps to exit 130, got {proc.returncode}")
        envelopes = json_lines(Path(trace).read_bytes())
        require(any(e.get("kind") == "delta" for e in envelopes),
                "closed-consumer run dropped deltas silently")
        seqs = [e.get("seq") for e in envelopes if e.get("seq") is not None]
        require(seqs == sorted(seqs), "closed-consumer trace lost monotonic order")
        require(envelopes and envelopes[-1].get("kind") == "run_finished",
                "closed stdout did not preserve the terminal event on the writable sink")

def secret_control_audit(work):
    with endpoint("secret-control") as (port, capture):
        cfg = write_config(work / "control.json", port, exec_policy=True)
        result = run_cli(cfg, trusted=True)
        require(result.returncode == 0, f"control-byte stream completed, got {result.returncode}")
        require(b"\x1b" not in result.stdout, "raw ESC byte reached JSONL stdout")
        require(b"\x1b" not in result.stderr, "raw ESC byte reached diagnostics")
        require(b"loopback-test-secret" not in result.stdout, "credential leaked to JSONL stdout")
        require(b"loopback-test-secret" not in result.stderr, "credential leaked to diagnostics")
        envelopes = json_lines(result.stdout)
        require(envelopes and envelopes[-1].get("kind") == "run_finished",
                "control-byte stream did not finish in JSONL order")

SCENARIOS = [
    ("authorization-denied", authorization_denied),
    ("approval-required", approval_required),
    ("sealed-tool-free", sealed_tool_free),
    ("malformed-arguments", malformed_arguments),
    ("incomplete-completion", incomplete_completion),
    ("turn-exhaustion", turn_exhaustion),
    ("midstream-abort-no-resend", midstream_abort_no_resend),
    ("cancel-mid-stream", cancel_mid_stream),
    ("closed-stdout-backpressure", closed_stdout_backpressure),
    ("secret-control-audit", secret_control_audit),
]

def main():
    require(BINARY.exists(), f"release binary missing: {BINARY}; run swift build -c release")
    failed = []
    with tempfile.TemporaryDirectory(prefix="m1d-negative-work-") as tmp:
        work = Path(tmp)
        for name, scenario in SCENARIOS:
            start = time.monotonic()
            try:
                scenario(work)
                print(f"PASS {name} ({time.monotonic() - start:.2f}s)", flush=True)
            except Failure as error:
                failed.append(name)
                print(f"FAIL {name}: {error}", flush=True)
            except Exception as error:  # Demonstration harness must fail loudly.
                failed.append(name)
                print(f"FAIL {name}: unexpected {error!r}", flush=True)
    if failed:
        print(f"NEGATIVE DEMOS FAILED: {', '.join(failed)}", flush=True)
        return 1
    print("NEGATIVE DEMOS PASSED", flush=True)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
