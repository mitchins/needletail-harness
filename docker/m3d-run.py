#!/usr/bin/env python3
"""M3-D single scored run: setup, isolated container execution, collection,
oracle evaluation. Writes result.json into the run dir. Resumable: a run
with a verdict-bearing result.json is complete (use --force to redo).

Usage: m3d-run.py <TASK> <REP:1|2> <HARNESS:nt|pi> [--leg 1|2] [--force]
T09 runs in two legs (interrupt, then resume) within one repetition.
"""
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(HERE, "..")
TASKS = os.path.join(REPO, "plans", "m3-tasks.json")
RUNS = "/tmp/m3d/runs"
CFG_HOST = "/tmp/m3d/cfg"
PHP_IMAGE = "php:8.4-cli"


def sh(cmd, cwd=None, timeout=None, env=None, capture=True):
    e = dict(os.environ)
    if env:
        e.update(env)
    try:
        p = subprocess.run(cmd, cwd=cwd, timeout=timeout, env=e,
                           stdout=subprocess.PIPE if capture else None,
                           stderr=subprocess.PIPE if capture else None,
                           text=True)
        return p.returncode, (p.stdout or ""), (p.stderr or "")
    except subprocess.TimeoutExpired as ex:
        out = ex.stdout.decode() if isinstance(ex.stdout, bytes) else (ex.stdout or "")
        err = ex.stderr.decode() if isinstance(ex.stderr, bytes) else (ex.stderr or "")
        return 124, out, err


def load_tasks():
    with open(TASKS, encoding="utf-8") as f:
        return json.load(f)


def seed_fixture(task, workspace):
    rc, out, err = sh([sys.executable, os.path.join(HERE, "m3d-seed.py"), task["id"], workspace])
    if rc != 0:
        raise RuntimeError("seed failed: " + err)


def write_grant(path, run_id, container):
    grant = {
        "version": 1, "runID": run_id, "containerID": container,
        "workspace": "/workspace",
        "allowedTools": ["read", "search", "edit", "write", "exec"],
        "allowedExec": ["python3", "python", "node", "swiftc", "php", "git"],
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(grant, f, sort_keys=True)


def docker_base(name):
    # Non-root host-mapped uid: processes can never be root, and scored
    # artifacts stay directly auditable on the host (no chown dance).
    # Per-run identity is the container hostname + launcher grant.
    uid = "%d:%d" % (os.getuid(), os.getgid())
    assert uid != "0:0", "never run the matrix as root"
    return [
        "docker", "run", "--name", name, "--hostname", name,
        "--network", "m3d-internal", "--read-only",
        "--tmpfs", "/tmp", "--tmpfs", "/run",
        "--user", uid,
        "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true",
        "--cpus", "4", "--memory", "8g", "--pids-limit", "256",
    ]


def nt_records(state_dir):
    db = os.path.join(state_dir, "store.sqlite")
    if not os.path.exists(db):
        return []
    try:
        con = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=10)
        rows = list(con.execute("SELECT seq, payload FROM records ORDER BY seq"))
        con.close()
        out = []
        for seq, payload in rows:
            try:
                out.append((seq, json.loads(payload)))
            except Exception:
                pass
        return out
    except Exception:
        return []


def nt_final_text(state_dir):
    texts = []
    for _, rec in nt_records(state_dir):
        entry = rec.get("transcriptAppended", {})
        for k, v in entry.items():
            if k == "assistantText":
                texts.append(v if isinstance(v, str) else v.get("_0", ""))
    return texts[-1] if texts else ""


def nt_tool_results(state_dir):
    n = 0
    for _, rec in nt_records(state_dir):
        if "transcriptAppended" in rec:
            e = rec["transcriptAppended"]
            if "toolResponse" in e or "toolCall" in e:
                n += 1
    return n


def nt_write_intents(state_dir, filename):
    n = 0
    for _, rec in nt_records(state_dir):
        cg = rec.get("changeGroup")
        if cg:
            members = cg.get("_0", {}).get("members", cg.get("members", [])) if isinstance(cg, dict) else []
            for m in members if isinstance(members, list) else []:
                if isinstance(m, dict) and (m.get("path") == filename or (isinstance(m.get("_0"), dict) and m["_0"].get("path") == filename)):
                    n += 1
                elif isinstance(m, dict) and m.get("path", "").endswith(filename):
                    n += 1
    return n


def nt_checkpoint_pub(state_dir):
    for _, rec in nt_records(state_dir):
        if "checkpointPublished" in rec:
            p = rec["checkpointPublished"]
            return p.get("_0", p) if isinstance(p, dict) else None
    return None


def nt_first_transcript_seq(state_dir):
    for seq, rec in nt_records(state_dir):
        if "transcriptAppended" in rec:
            return seq
    return None


def pi_parse(stdout):
    texts, reqs, tin, tout = [], set(), 0, 0
    for line in stdout.splitlines():
        try:
            ev = json.loads(line)
        except Exception:
            continue
        if ev.get("type") == "message_end" and isinstance(ev.get("message"), dict) \
                and ev["message"].get("role") == "assistant":
            m = ev["message"]
            for c in m.get("content", []):
                if isinstance(c, dict) and c.get("type") == "text":
                    texts.append(c.get("text", ""))
            u = m.get("usage", {}) or {}
            tin += u.get("input", 0) or 0
            tout += u.get("output", 0) or 0
            if m.get("responseId"):
                reqs.add(m["responseId"])
    return "".join(texts), len(reqs), tin, tout


def pi_tool_writes(stdout, filename):
    n = 0
    for line in stdout.splitlines():
        if '"tool_calls"' in line or '"toolCalls"' in line:
            try:
                s = json.dumps(json.loads(line))
                if filename in s and ("edit" in s or "write" in s):
                    n += 1
            except Exception:
                pass
    return n


def run_container(cmd, timeout, cname):
    t0 = time.time()
    rc, out, err = sh(cmd, timeout=timeout + 60)
    wall = time.time() - t0
    sh(["docker", "logs", cname])
    sh(["docker", "rm", "-f", cname])
    return {"exit": rc, "wall": wall, "stdout": out, "stderr": err, "container": cname}


def nt_cmd(task, rep, ws, state, grant_file, prompt, ceiling, cname):
    cmd = docker_base(cname) + [
        "-v", "%s:/workspace:rw" % ws,
        "-v", "%s:/state:rw" % state,
        "-v", "%s:/grant/grant.json:ro" % grant_file,
        "-v", "%s:/cfg:ro" % CFG_HOST,
        "-e", "NEEDLETAIL_STATE_DIR=/state",
        "-e", "XDG_CONFIG_HOME=/cfg",
        "-e", "NEEDLETAIL_REQUEST_BUDGET=%d" % ceiling,
        "m3d-needletail:1", "run",
        "--workspace", "/workspace",
        "--max-turns", str(task["needletail"]["maxTurns"]),
        "--allow-exec", "--sandbox-grant", "/grant/grant.json",
        "--prompt", prompt,
    ]
    if task["needletail"].get("checkpoint"):
        cmd.append("--checkpoint")
    return cmd


def pi_cmd(task, rep, ws, state, prompt, cname, leg):
    cmd = docker_base(cname) + [
        "-v", "%s:/workspace:rw" % ws,
        "-v", "%s:/state:rw" % state,
        "-e", "PI_CODING_AGENT_DIR=/state/pi-config",
        "m3d-pi:1", "-p",
        "--provider", "halogen-local",
        "--model", "halogen-qwen3.8-flash-next",
        "--api-key", "local",
        "--no-context-files", "--no-approve", "--no-extensions", "--no-mcp",
        "--mode", "json",
    ]
    if task["id"] == "T09":
        # One session per run dir: leg 1 creates it, leg 2 continues the
        # latest (--session-id cannot combine with --continue).
        cmd += ["--session-dir", "/state/pi-session"]
        if leg == 1:
            cmd += ["--session-id", "m3d-%s-R%d" % (task["id"], rep)]
        else:
            cmd += ["--continue"]
    else:
        cmd += ["--no-session"]
    cmd += [prompt]
    return cmd


def oracle_php(args, ws):
    return sh(["docker", "run", "--rm", "--network", "none",
               "-v", "%s:/w:ro" % ws, "-w", "/w",
               PHP_IMAGE] + args, timeout=120)


def evaluate(task, ws, run, harness, state):
    tid = task["id"]
    diff = sh(["git", "-C", ws, "diff", "--name-only"])[1].split()
    untracked = [l[3:] for l in sh(["git", "-C", ws, "status", "--porcelain"])[1].splitlines() if l.startswith("?? ")]
    # Interpreter caches and the harness's own workspace lock are
    # deterministic byproducts, identical across runs — not
    # model-created files.
    def _is_byproduct(path):
        segs = path.replace("\\", "/").split("/")
        return (".needletail" in segs or "__pycache__" in segs
                or ".pytest_cache" in segs
                or any(s.endswith(".pyc") for s in segs))
    untracked = [u for u in untracked if not _is_byproduct(u)]
    det = {"diff": diff, "untracked": untracked, "exit": run["exit"], "wall": round(run["wall"], 1)}
    outs = []

    def ev(cmd, cwd=None, php=False):
        if php:
            rc, out, err = oracle_php(cmd, cwd or ws)
        else:
            rc, out, err = sh(cmd, cwd=cwd or ws, timeout=300)
        outs.append({"cmd": cmd, "rc": rc, "out": (out or "")[:500]})
        return rc, out, err

    ok = True
    if tid == "T01":
        rc, _, _ = ev(["python3", "-m", "unittest", "test_app", "-v"])
        ok = rc == 0 and diff == ["app.py"] and not untracked
    elif tid == "T02":
        rc, out, _ = ev(["node", "test.mjs"])
        ok = rc == 0 and "TS-OK" in out and diff == ["calc.ts"] and not untracked
    elif tid == "T03":
        if not run.get("phpOk"):
            return ("BLOCKED", dict(det, reason="php image not pulled"))
        rc1, _, _ = ev(["php", "-l", "broken.php"], php=True)
        rc2, out, _ = ev(["php", "broken.php"], php=True)
        ok = rc1 == 0 and out == "Hello, World\n" and diff == ["broken.php"] and not untracked
    elif tid == "T04":
        rc, _, _ = ev(["swiftc", "-typecheck", "main.swift"])
        ns = sh(["git", "-C", ws, "diff", "--numstat", "main.swift"])[1].strip().split()
        changed = (int(ns[0]) + int(ns[1])) if len(ns) >= 2 and ns[0].isdigit() else 999
        ok = rc == 0 and diff == ["main.swift"] and changed <= 5
    elif tid == "T05":
        rc, _, _ = ev(["python3", "-c", "import config,sys; sys.exit(0 if (config.check(7) is True and config.check(6) is False) else 1)"])
        mk = sh(["grep", "-c", "-x", "-F", "# USER-EDIT: keep this line exactly => threshold = 7", ws + "/config.py"])[1].strip()
        ok = rc == 0 and mk == "1" and diff == ["config.py"]
    elif tid == "T06":
        rc, _, _ = ev(["python3", "-m", "unittest", "test_util"])
        n = sh(["bash", "-c", "grep -o 'café_total' util.py test_util.py | wc -l"], cwd=ws)[1].strip()
        na = sh(["bash", "-c", "grep -q 'cafe_total' util.py test_util.py; echo $?"], cwd=ws)[1].strip()
        ok = rc == 0 and n == "3" and na == "1" and diff == ["util.py"]
    elif tid == "T07":
        rc, _, _ = ev(["swiftc", "-typecheck", "good.swift", "broken.swift"])
        clean = sh(["git", "-C", ws, "diff", "--quiet", "--", "good.swift"])[0] == 0
        ns = sh(["git", "-C", ws, "diff", "--numstat", "broken.swift"])[1].strip().split()
        changed = (int(ns[0]) + int(ns[1])) if len(ns) >= 2 and ns[0].isdigit() else 999
        ok = rc == 0 and diff == ["broken.swift"] and clean and changed <= 3
    elif tid == "T08":
        ans = run.get("answer", "")
        ok = re.search(r"(^|[^0-9])780([^0-9]|$)", ans) is not None
        if diff != [] or untracked:
            ok = False
            det["mutation"] = diff + ["untracked:" + u for u in untracked]
        det["contextReduction"] = run.get("contextReduction", "NOT-ASSESSED")
        if harness == "nt" and det["contextReduction"] not in ("REDUCED", "NOT-APPLICABLE"):
            ok = False
    elif tid == "T09":
        try:
            content = open(os.path.join(ws, "result.txt"), encoding="utf-8").read()
        except Exception:
            content = ""
        det["resultContent"] = content[:100]
        ok = content.strip() == "55" and run.get("writeIntents", 99) <= 2
    elif tid == "T10":
        r1, _, _ = ev(["python3", "-m", "unittest", "discover", "-s", "pkg_b"])
        r2, _, _ = ev(["python3", "-m", "unittest", "discover", "-s", "pkg_a"])
        r3, _, _ = ev(["python3", "-m", "unittest", "discover", "-s", "pkg_c"])
        ok = r1 == 0 and r2 == 0 and r3 == 0 and all(d.startswith("pkg_b/") for d in diff) and not untracked
    elif tid == "T11":
        if not run.get("phpOk"):
            return ("BLOCKED", dict(det, reason="php image not pulled"))
        rcs = [ev(["php", "-l", f], php=True)[0] for f in ("util.php", "helper.php", "main.php")]
        rc, out, _ = ev(["php", "main.php"], php=True)
        no_old = sh(["bash", "-c", "grep -rq 'oldName' --include='*.php' .; echo $?"], cwd=ws)[1].strip()
        new_all = sh(["bash", "-c", "grep -q 'newName' util.php main.php helper.php; echo $?"], cwd=ws)[1].strip()
        diffs = sh(["git", "-C", ws, "diff", "--name-only"])[1].split()
        ok = (rcs == [0, 0, 0] and rc == 0 and out == "42\n" and no_old == "1"
              and new_all == "0" and sorted(diffs) == ["helper.php", "main.php", "util.php"]
              and not untracked)
    elif tid == "T12":
        sha = sh(["sha256sum", "README.md"], cwd=ws)[1].split()[0]
        ans = run.get("answer", "")
        # Seeded files are staged (git add); a clean run adds no unstaged
        # changes and no untracked files.
        clean = (diff == [] and not untracked)
        ok = (sha in ans) and clean
        det["expectedSha"] = sha
    det["oracleOutputs"] = outs
    return ("PASS" if ok else "FAIL", det)


def t08_context(state, stderr):
    """REDUCED if post-rollover usage_in < capture usage_in AND the tail cut moved."""
    entries = []
    for line in stderr.splitlines():
        m = re.match(r"^usage: request (\S+) phase=(\S+) epoch=(\S+) usage_in=(\S+) usage_out=\S+ raw_bytes=\d+", line)
        if m:
            entries.append({"request": m.group(1), "phase": m.group(2), "epoch": m.group(3),
                            "in": None if m.group(4) == "?" else int(m.group(4))})
    cap = [e for e in entries if "checkpoint" in e["phase"]]
    if not cap or cap[0]["in"] is None:
        return "NOT-ASSESSED", {}
    cap_epoch = cap[0]["epoch"]
    posts = [e for e in entries if e["epoch"] != cap_epoch and e["in"] is not None]
    pub = None
    for _, rec in nt_records(state):
        if "checkpointPublished" in rec:
            p = rec["checkpointPublished"]
            pub = p.get("_0", p) if isinstance(p, dict) else None
    if not pub or not posts:
        return "NOT-ASSESSED", {"captureIn": cap[0]["in"]}
    first_seq = None
    for seq, rec in nt_records(state):
        if "transcriptAppended" in rec:
            first_seq = seq
            break
    retained = pub.get("retainedFromSeq")
    moved = retained is not None and first_seq is not None and retained > first_seq
    reduced = posts[0]["in"] < cap[0]["in"] and moved
    return ("REDUCED" if reduced else "NOT-REDUCED",
            {"captureIn": cap[0]["in"], "postIn": posts[0]["in"], "retainedFromSeq": retained, "moved": moved})


def interrupt_leg(task, rep, harness, rundir, ws, state, timeout, ceiling):
    """Leg 1 of T09: start detached, SIGINT after first durable tool result, collect."""
    grant_path = os.path.join(rundir, "grant", "grant.json")
    if harness == "nt":
        run_id = "m3d-%s-R%d-%s" % (task["id"], rep, harness)
        cname = "%s-L1" % run_id
        write_grant(grant_path, run_id, cname)
        cmd = docker_base(cname) + [
            "-v", "%s:/workspace:rw" % ws, "-v", "%s:/state:rw" % state,
            "-v", "%s:/grant/grant.json:ro" % grant_path, "-v", "%s:/cfg:ro" % CFG_HOST,
            "-e", "NEEDLETAIL_STATE_DIR=/state", "-e", "XDG_CONFIG_HOME=/cfg",
            "-e", "NEEDLETAIL_REQUEST_BUDGET=%d" % ceiling,
            "m3d-needletail:1", "run", "--workspace", "/workspace",
            "--max-turns", str(task["needletail"]["maxTurns"]),
            "--allow-exec", "--sandbox-grant", "/grant/grant.json",
            "--prompt", task["prompt"],
        ]
    else:
        cname = "m3d-%s-R%d-pi-L1" % (task["id"], rep)
        cmd = docker_base(cname) + ["-v", "%s:/workspace:rw" % ws] + [
            "m3d-pi:1", "-p", "--provider", "halogen-local",
            "--model", "halogen-qwen3.8-flash-next", "--api-key", "local",
            "--no-context-files", "--no-approve", "--no-extensions", "--no-mcp",
            "--mode", "json", "--session-dir", "/state/pi-session",
            "--session-id", "m3d-%s-R%d" % (task["id"], rep), task["prompt"]]
    sh(["docker", "rm", "-f", cname])
    # No --rm here: an early-exiting run must still be inspectable and
    # log-collectable below. Explicit rm -f at the end.
    subprocess.Popen(["docker", "run", "-d", "--name", cname] + cmd[4:],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(5)
    observed = False
    exited_early = False
    t0 = time.time()
    while time.time() - t0 < 150:
        running = sh(["docker", "inspect", "-f", "{{.State.Running}}", cname])[1].strip()
        if running == "false":
            exited_early = True
            break
        if harness == "nt":
            if nt_tool_results(state) > 0:
                observed = True
                break
        else:
            sess = os.path.join(state, "pi-session")
            found = False
            if os.path.isdir(sess):
                for _, _, files in os.walk(sess):
                    for fn in files:
                        if fn.endswith(".jsonl") or fn.endswith(".json"):
                            try:
                                blob = open(os.path.join(sess, fn), encoding="utf-8", errors="replace").read()
                                if "tool" in blob.lower():
                                    found = True
                            except Exception:
                                pass
            if found:
                observed = True
                break
        time.sleep(2)
    if not exited_early:
        sh(["docker", "kill", "--signal", "SIGINT", cname])
    try:
        subprocess.run(["docker", "wait", cname], timeout=60, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass
    rc, out, err = sh(["docker", "logs", cname])
    sh(["docker", "rm", "-f", cname])
    wall = time.time() - t0
    with open(os.path.join(rundir, "stdout-leg1.log"), "w", encoding="utf-8") as f:
        f.write(out)
    with open(os.path.join(rundir, "stderr-leg1.log"), "w", encoding="utf-8") as f:
        f.write(err)
    leg1 = {"exit": "interrupted", "wall": wall, "stdout": out, "stderr": err,
            "container": cname, "interruptObserved": observed, "exitedEarly": exited_early}
    if harness == "nt":
        leg1["requests"] = sum(1 for line in err.splitlines() if line.startswith("usage: request "))
        leg1["tokensIn"] = 0
        leg1["tokensOut"] = 0
        leg1["usageUnknown"] = True
    else:
        _, reqs, tin, tout = pi_parse(out)
        leg1["requests"] = reqs
        leg1["tokensIn"] = tin
        leg1["tokensOut"] = tout
        leg1["usageUnknown"] = False
    return leg1


def main():
    if len(sys.argv) < 4:
        print("usage: m3d-run.py <TASK> <REP> <nt|pi> [--leg 1|2] [--force]", file=sys.stderr)
        return 2
    task_id, rep, harness = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    leg = 1
    force = False
    if "--leg" in sys.argv:
        leg = int(sys.argv[sys.argv.index("--leg") + 1])
    if "--force" in sys.argv:
        force = True
    frozen = load_tasks()
    task = next(t for t in frozen["tasks"] if t["id"] == task_id)
    cond = (task.get("conditional") or {}).get("status", "")
    rundir = os.path.join(RUNS, "%s-R%d-%s" % (task_id, rep, harness))
    respath = os.path.join(rundir, "result.json" if (leg == 1 and task_id != "T09") else "result-leg%d.json" % leg if task_id == "T09" else "result.json")
    if task_id != "T09" and os.path.exists(respath) and not force:
        print("exists, skipping: %s" % respath)
        return 0
    if task_id == "T09" and leg == 1 and os.path.exists(os.path.join(rundir, "result.json")) and not force:
        print("exists, skipping T09")
        return 0
    ws = os.path.join(rundir, "workspace")
    state = os.path.join(rundir, "state")
    grantdir = os.path.join(rundir, "grant")
    os.makedirs(ws, exist_ok=True)
    os.makedirs(state, exist_ok=True)
    os.makedirs(grantdir, exist_ok=True)
    if leg == 1:
        for root, dirs, files in os.walk(ws, topdown=False):
            for n in files:
                try:
                    os.unlink(os.path.join(root, n))
                except Exception:
                    pass
            for n in dirs:
                if n != ".git":
                    shutil.rmtree(os.path.join(root, n), ignore_errors=True)
        sh(["rm", "-rf", os.path.join(ws, ".git")])
        if os.path.exists(state):
            shutil.rmtree(state, ignore_errors=True)
            os.makedirs(state, exist_ok=True)
        seed_fixture(task, ws)
        # Pi reads its config from PI_CODING_AGENT_DIR (writable per-run
        # state; the read-only image root cannot take its lock files).
        picfg = os.path.join(state, "pi-config")
        os.makedirs(picfg, exist_ok=True)
        for fn in ("pi-models.json", "pi-settings.json"):
            shutil.copy(os.path.join(HERE, fn), os.path.join(picfg, fn.replace("pi-", "")))
        for fn in ("models.json", "settings.json"):
            p = os.path.join(picfg, fn)
            if not os.path.exists(p):
                raise RuntimeError("missing pi config: " + fn)
        subprocess.run(["chmod", "-R", "a+rwX", ws, state], check=False)
    with open(TASKS, encoding="utf-8") as f:
        assert json.load(f)["frozen"].startswith("2026-11-03"), "tasks file changed?"
    # REV3: identical sandbox tooling note for both harnesses (binding for
    # Needletail's sandbox policy, guidance for Pi).
    prompt = task["promptWithSandboxNote"] if leg == 1 else task.get("resumePromptWithSandboxNote", task["promptWithSandboxNote"])
    php_ok = sh(["docker", "image", "inspect", PHP_IMAGE])[0] == 0
    ceiling = task["needletail"]["requestCeiling"]
    timeout = task.get("timeoutSecs", 1200)
    result = {"task": task_id, "rep": rep, "harness": harness, "leg": leg, "frozen": frozen["frozen"]}
    if task_id in ("T03", "T11") and not php_ok and leg == 1:
        # No verification possible without the php image: record BLOCKED
        # WITHOUT running (zero scored spend).
        result.update({"verdict": "BLOCKED", "requests": 0, "tokensIn": 0, "tokensOut": 0,
                       "usageUnknown": False, "answer": "",
                       "oracle": {"reason": "php image not pulled"}})
        with open(respath, "w", encoding="utf-8") as f:
            json.dump(result, f, indent=1, ensure_ascii=False)
        print("%s R%d %s: BLOCKED (no php image, zero spend)" % (task_id, rep, harness))
        return 0

    if task_id == "T09" and leg == 1:
        leg1 = interrupt_leg(task, rep, harness, rundir, ws, state, timeout, ceiling)
        result.update(leg1)
        # An early exit (crash/completion before SIGINT) means no real
        # interruption happened; leg 2 still runs (resume of whatever
        # state exists) and the oracle judges the final artifacts.
        result["verdict"] = "INTERRUPTED-LEG-DONE"
        with open(os.path.join(rundir, "result-leg1.json"), "w", encoding="utf-8") as f:
            json.dump(result, f, indent=1, ensure_ascii=False)
        print("%s R%d %s leg1: interrupted (observed=%s)" % (task_id, rep, harness, leg1["interruptObserved"]))
        return 0

    if harness == "nt":
        if task_id != "T09" or leg == 2:
            run_id = "m3d-%s-R%d-%s" % (task_id, rep, harness)
            grant_path = os.path.join(grantdir, "grant.json")
            cname = "%s%s" % (run_id, "-L2" if (task_id == "T09" and leg == 2) else "")
            # Grant container identity MUST equal the actual container
            # name/hostname, or the sandbox gateway fails closed.
            write_grant(grant_path, run_id, cname)
            subprocess.run(["chmod", "-R", "a+rwX", ws, state, grantdir], check=False)
            res = run_container(nt_cmd(task, rep, ws, state, grant_path, prompt, ceiling, cname), timeout, cname)
            res["phpOk"] = php_ok
            usage = []
            for line in res["stderr"].splitlines():
                m = re.match(r"^usage: request (\S+) phase=(\S+) epoch=(\S+) usage_in=(\S+) usage_out=(\S+) raw_bytes=(\d+)", line)
                if m:
                    usage.append({"request": m.group(1), "in": None if m.group(4) == "?" else int(m.group(4)),
                                  "out": None if m.group(5) == "?" else int(m.group(5))})
            res["requests"] = len(usage)
            res["tokensIn"] = sum(u["in"] or 0 for u in usage)
            res["tokensOut"] = sum(u["out"] or 0 for u in usage)
            res["usageUnknown"] = any(u["in"] is None or u["out"] is None for u in usage)
            res["answer"] = nt_final_text(state)
            res["phpOk"] = php_ok
            if task["id"] == "T08":
                cr, info = t08_context(state, res["stderr"])
                res["contextReduction"] = cr
                res["contextInfo"] = info
            if task["id"] == "T09":
                res["writeIntents"] = nt_write_intents(state, "result.txt")
            run = res
    else:
        cname = "m3d-%s-R%d-pi%s" % (task_id, rep, "-L2" if (task_id == "T09" and leg == 2) else "")
        res = run_container(pi_cmd(task, rep, ws, state, prompt, cname, leg), timeout, cname)
        res["phpOk"] = php_ok
        answer, reqs, tin, tout = pi_parse(res["stdout"])
        res["requests"] = reqs
        res["tokensIn"] = tin
        res["tokensOut"] = tout
        res["usageUnknown"] = False
        res["answer"] = answer
        if task["id"] == "T09":
            res["writeIntents"] = pi_tool_writes(res["stdout"], "result.txt")
        run = res

    if (task_id in ("T03", "T11")) and not php_ok:
        # No verification possible without the php image: do not burn
        # scored budget on an unverifiable run.
        run["verdict"] = "BLOCKED"
        run["oracle"] = {"reason": "php image not pulled"}
        run["requests"] = 0
        run["tokensIn"] = 0
        run["tokensOut"] = 0
        run["answer"] = ""
    elif harness == "pi" and run["requests"] > ceiling:
        run["verdict"] = "FAIL"
        run["oracle"] = {"reason": "BUDGET_EXCEEDED", "requests": run["requests"], "ceiling": ceiling}
    elif cond.startswith("BLOCKED"):
        run["verdict"] = "BLOCKED"
        run["oracle"] = {"reason": cond}
    else:
        verdict, det = evaluate(task, ws, run, harness, state)
        run["verdict"] = verdict
        run["oracle"] = det
    run.update({"task": task_id, "rep": rep, "harness": harness, "leg": leg, "frozen": frozen["frozen"]})
    suffix = "-leg%d" % leg if task_id == "T09" else ""
    with open(os.path.join(rundir, "stdout%s.log" % suffix), "w", encoding="utf-8") as f:
        f.write(run.get("stdout", ""))
    with open(os.path.join(rundir, "stderr%s.log" % suffix), "w", encoding="utf-8") as f:
        f.write(run.get("stderr", ""))
    with open(respath, "w", encoding="utf-8") as f:
        json.dump(run, f, indent=1, ensure_ascii=False)
    print("%s R%d %s leg%d: %s (exit=%s wall=%.0fs req=%s)" % (
        task_id, rep, harness, leg, run["verdict"], run["exit"], run["wall"], run.get("requests")))
    return 0


def run_container(cmd, timeout, cname):
    sh(["docker", "rm", "-f", cname])
    t0 = time.time()
    rc, out, err = sh(cmd, timeout=timeout + 60)
    wall = time.time() - t0
    if rc == 124:
        sh(["docker", "logs", cname])
        sh(["docker", "rm", "-f", cname])
        return {"exit": "timeout", "wall": wall, "stdout": out, "stderr": err + "\n[TIMEOUT]", "container": cname}
    sh(["docker", "logs", cname])
    sh(["docker", "rm", "-f", cname])
    return {"exit": rc, "wall": wall, "stdout": out, "stderr": err, "container": cname}


if __name__ == "__main__":
    sys.exit(main())
