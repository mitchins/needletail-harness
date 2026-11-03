#!/usr/bin/env python3
"""Gemma endpoint qualification through both harnesses (bounded synthetic).

No benchmark fixtures, no oracles, no scored traffic. Records exact
request/response evidence + provider usage + latency to /tmp/m3d-gemma/qual/.
Stops (nonzero exit) on the first incompatibility.
"""
import json
import os
import subprocess
import sys
import time

GEMMA_ID = "reinforce20001/gemma4-26b-a4b-it-qat-w4a16-ct"
GEMMA_URL = "http://m3d-gemma-forwarder:8000"
OUT = "/tmp/m3d-gemma/qual"
HERE = os.path.dirname(os.path.abspath(__file__))
# Qualification is synthetic: start from fresh state every run (real
# comparisons seed fresh containers instead). Without this, the durable
# budget file from a previous run correctly refuses new sends.
import shutil as _shutil
for _d in ("nt1-state", "nt2-state", "nt3-state", "nt1-ws", "nt2-ws", "nt3-ws",
           "pi1-state", "pi2-state", "pi3-state", "pi1-ws", "pi2-ws", "pi3-ws"):
    _shutil.rmtree(os.path.join(OUT, _d), ignore_errors=True)
os.makedirs(OUT, exist_ok=True)
UID = "%d:%d" % (os.getuid(), os.getgid())


def base(name):
    return ["docker", "run", "--name", name, "--hostname", name,
            "--network", "m3d-internal", "--read-only",
            "--tmpfs", "/tmp", "--tmpfs", "/run", "--user", UID,
            "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true",
            "--cpus", "4", "--memory", "8g", "--pids-limit", "256"]


def run(cmd, timeout=300):
    t0 = time.time()
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return r, time.time() - t0


def sh(cmd):
    return subprocess.run(cmd, capture_output=True).returncode == 0


results = {}


def check(name, cond, detail=""):
    results[name] = {"pass": bool(cond), "detail": detail[:500]}
    print(("PASS " if cond else "FAIL ") + name + (" " + detail[:200] if detail and not cond else ""), flush=True)
    if not cond:
        json.dump(results, open(OUT + "/results.json", "w"), indent=1)
        sys.exit(1)


# ---- NT1: trivial text (identity config + streaming + usage) ----
ws = OUT + "/nt1-ws"
st = OUT + "/nt1-state"
os.makedirs(ws, exist_ok=True)
os.makedirs(st, exist_ok=True)
subprocess.run(["docker", "rm", "-f", "gemma-nt1"], capture_output=True)
cmd = base("gemma-nt1") + [
    "-v", "%s:/workspace:rw" % ws, "-v", "%s:/state:rw" % st,
    "-e", "NEEDLETAIL_STATE_DIR=/state", "-e", "XDG_CONFIG_HOME=/cfg",
    "-e", "NEEDLETAIL_REQUEST_BUDGET=4", "-v", "/tmp/m3d-gemma/cfg:/cfg:ro",
    "m3d-needletail:remediation", "run", "--workspace", "/workspace",
    "--max-turns", "3", "--prompt", "Reply with exactly: GEMMA-NT-OK"]
r, wall = run(cmd)
open(OUT + "/nt1-stdout.log", "w").write(r.stdout)
open(OUT + "/nt1-stderr.log", "w").write(r.stderr)
check("NT1-exit-0", r.returncode == 0, "exit=%d stderr=%s" % (r.returncode, r.stderr[-300:]))
check("NT1-text", "GEMMA-NT-OK" in r.stdout, repr(r.stdout[:200]))
check("NT1-usage", "usage: request" in r.stderr and "budget: used=" in r.stderr, r.stderr[-300:])
lat = [wall]

# ---- NT2: genuine tool call (read seeded file) ----
ws2 = OUT + "/nt2-ws"
st2 = OUT + "/nt2-state"
os.makedirs(ws2, exist_ok=True)
os.makedirs(st2, exist_ok=True)
open(ws2 + "/seed.txt", "w").write("s3cr3t-payload-77\n")
subprocess.run(["docker", "rm", "-f", "gemma-nt2"], capture_output=True)
cmd = base("gemma-nt2") + [
    "-v", "%s:/workspace:rw" % ws2, "-v", "%s:/state:rw" % st2,
    "-e", "NEEDLETAIL_STATE_DIR=/state", "-e", "XDG_CONFIG_HOME=/cfg",
    "-e", "NEEDLETAIL_REQUEST_BUDGET=4", "-v", "/tmp/m3d-gemma/cfg:/cfg:ro",
    "m3d-needletail:remediation", "run", "--workspace", "/workspace",
    "--max-turns", "4", "--prompt",
    "Use the read tool to read seed.txt and report its exact contents verbatim. Do nothing else."]
r, wall = run(cmd)
open(OUT + "/nt2-stdout.log", "w").write(r.stdout)
open(OUT + "/nt2-stderr.log", "w").write(r.stderr)
check("NT2-exit-0", r.returncode == 0, "exit=%d" % r.returncode)
check("NT2-tool-result", "s3cr3t-payload-77" in r.stdout, repr(r.stdout[:200]))
lat.append(wall)

# ---- NT3: pairing + continuation (read then write derived value) ----
# Write needs the sandbox grant (workspace-mode mutating tool); the grant
# is launcher-issued and scoped to this disposable container/run.
import importlib.util as _ilu
_spec = _ilu.spec_from_file_location("m3d_run_q", os.path.join(HERE, "m3d-run.py"))
_m = _ilu.module_from_spec(_spec)
_spec.loader.exec_module(_m)
ws3 = OUT + "/nt3-ws"
st3 = OUT + "/nt3-state"
grantdir = OUT + "/nt3-grant"
os.makedirs(ws3, exist_ok=True)
os.makedirs(st3, exist_ok=True)
os.makedirs(grantdir, exist_ok=True)
open(ws3 + "/a.txt", "w").write("21\n")
gf = os.path.join(grantdir, "grant.json")
_m.write_grant(gf, "gemma-nt3", "gemma-nt3")
subprocess.run(["docker", "rm", "-f", "gemma-nt3"], capture_output=True)
cmd = base("gemma-nt3") + [
    "-v", "%s:/workspace:rw" % ws3, "-v", "%s:/state:rw" % st3,
    "-v", "%s:/grant/grant.json:ro" % gf,
    "-e", "NEEDLETAIL_STATE_DIR=/state", "-e", "XDG_CONFIG_HOME=/cfg",
    "-e", "NEEDLETAIL_REQUEST_BUDGET=6", "-v", "/tmp/m3d-gemma/cfg:/cfg:ro",
    "m3d-needletail:remediation", "run", "--workspace", "/workspace",
    "--max-turns", "6", "--sandbox-grant", "/grant/grant.json",
    "--prompt", "Read a.txt with the read tool, double the number, and write the result (digits only) to b.txt with the write tool. Then stop."]
r, wall = run(cmd)
open(OUT + "/nt3-stdout.log", "w").write(r.stdout)
open(OUT + "/nt3-stderr.log", "w").write(r.stderr)
# Relational check: b must equal twice the FINAL a (the model may rewrite
# a.txt first, as Pi did — pairing/continuation is what we qualify).
try:
    aval = int(open(ws3 + "/a.txt").read().strip())
except Exception as e:
    aval = "MISSING:%s" % e
b = ""
try:
    b = open(ws3 + "/b.txt").read().strip()
except Exception as e:
    b = "MISSING:%s" % e
check("NT3-exit-0", r.returncode == 0, "exit=%d" % r.returncode)
check("NT3-continuation", b == str(2 * aval) if isinstance(aval, int) else False,
      "a.txt=%r b.txt=%r" % (aval, b))
lat.append(wall)

# ---- PI1/PI2/PI3: same three through Pi ----
for i, (prompt, want, rep) in enumerate([
    ("Reply with exactly: GEMMA-PI-OK", "GEMMA-PI-OK", 4),
    ("Use the read tool to read seed.txt and report its exact contents verbatim. Do nothing else.", "s3cr3t-payload-77", 4),
    ("Read a.txt with the read tool, double the number, and write the result (digits only) to b.txt with the write tool. Then stop.", "PI3-DONE", 6),
], start=1):
    ws = OUT + "/pi%d-ws" % i
    os.makedirs(ws, exist_ok=True)
    st = OUT + "/pi%d-state" % i
    os.makedirs(st + "/pi-config", exist_ok=True)
    os.makedirs(st + "/pi-session", exist_ok=True)
    for fn in ("pi-models.json", "pi-settings.json"):
        src = "/tmp/m3d-gemma/%s" % fn
        dst = os.path.join(st, "pi-config", fn.replace("pi-", ""))
        if not os.path.exists(dst):
            import shutil
            shutil.copy(src, dst)
    if i >= 2:
        open(ws + "/seed.txt", "w").write("s3cr3t-payload-77\n")
    if i == 3:
        open(ws + "/a.txt", "w").write("21\n")
    cname = "gemma-pi%d" % i
    subprocess.run(["docker", "rm", "-f", cname], capture_output=True)
    cmd = base(cname) + [
        "-v", "%s:/workspace:rw" % ws, "-v", "%s:/state:rw" % st,
        "-e", "PI_CODING_AGENT_DIR=/state/pi-config",
        "m3d-pi:1", "-p", "--provider", "gemma-local",
        "--model", GEMMA_ID, "--api-key", "local",
        "--no-context-files", "--no-approve", "--no-extensions", "--no-mcp",
        "--mode", "json", "--session-dir", "/state/pi-session",
        "--session-id", "gemma-pi%d" % i, prompt]
    r, wall = run(cmd)
    open(OUT + "/pi%d-stdout.log" % i, "w").write(r.stdout)
    open(OUT + "/pi%d-stderr.log" % i, "w").write(r.stderr)
    lat.append(wall)
    if i < 3:
        check("PI%d-text" % i, want in r.stdout, "exit=%d out=%s" % (r.returncode, r.stdout[:300]))
    else:
        try:
            aval = int(open(ws + "/a.txt").read().strip())
        except Exception as e:
            aval = "MISSING:%s" % e
        b = ""
        try:
            b = open(ws + "/b.txt").read().strip()
        except Exception as e:
            b = "MISSING:%s" % e
        check("PI3-continuation", b == str(2 * aval) if isinstance(aval, int) else False,
              "a.txt=%r b.txt=%r exit=%d" % (aval, b, r.returncode))

# ---- latency triple-probe (first Gemma health canary) ----
check("latency-samples", len(lat) == 6, str(lat))
mx = max(lat)
check("latency-stable", mx < 180, "max wall %.1fs over 6 harness runs: %s" % (mx, ["%.1f" % x for x in lat]))
results["latencies"] = lat
json.dump(results, open(OUT + "/results.json", "w"), indent=1)
print("QUALIFICATION COMPLETE", lat)
