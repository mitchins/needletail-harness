#!/usr/bin/env python3
"""Per-cell confirmation measurement (reads frozen + confirmation ledgers)."""
import json
import glob
import re
import sqlite3
from collections import Counter


def unwrap(v):
    while isinstance(v, dict) and set(v.keys()) == {"_0"}:
        v = v["_0"]
    return v


def measure(rundir):
    dbs = glob.glob(rundir + "/state/store.sqlite")
    if not dbs:
        return {"ledger": "missing"}
    con = sqlite3.connect("file:%s?mode=ro" % dbs[0], uri=True)
    kinds = Counter()
    calls = Counter()
    rejects = Counter()
    notices = 0
    execfails = []
    holds = 0
    try:
        rows = con.execute("SELECT seq, payload FROM records ORDER BY seq").fetchall()
    except Exception as e:
        return {"ledger": "unreadable: %s" % e}
    for _, p in rows:
        try:
            d = json.loads(p)
        except Exception:
            continue
        if "eventAppended" in d:
            kinds[d["eventAppended"].get("kind")] += 1
        if "transcriptAppended" not in d:
            continue
        e = unwrap(d["transcriptAppended"])
        if not isinstance(e, dict):
            continue
        for k, v in e.items():
            v = unwrap(v)
            if k == "user" and "harness notice" in str(v):
                notices += 1
            if k == "toolCall":
                calls[v.get("tool")] += 1
            if k == "toolResponse":
                t = str(v.get("text", ""))
                if "preDispatch" in t:
                    w = re.sub(r"call_[0-9a-f]+", "ID", t).split("\n")[0][:80]
                    rejects[w] += 1
                if "conflict" in t or "mismatch" in t:
                    execfails.append(t.split("\n")[0][:90])
    con.close()
    boundary = kinds.get("completed-budget-boundary", 0) > 0
    return {
        "completed_boundary": boundary,
        "oversized_notices": notices,
        "tool_calls": dict(calls),
        "rejections": dict(rejects),
        "exec_conflicts": execfails[:4],
    }


if __name__ == "__main__":
    import sys
    cells = sys.argv[1:] or ["T02-R1", "T02-R2", "T03-R2", "T05-R1", "T05-R2",
                             "T06-R1", "T06-R2", "T07-R1", "T07-R2",
                             "T08-R1", "T08-R2", "T10-R1", "T10-R2",
                             "T11-R1", "T11-R2"]
    for cell in cells:
        f = json.load(open("/tmp/m3d/runs/%s-nt/result.json" % cell))
        cpath = "/tmp/m3d-confirm/runs/%s-nt/result.json" % cell
        try:
            c = json.load(open(cpath))
        except Exception as e:
            print(cell, "CONFIRM-MISSING", e)
            continue
        m = measure("/tmp/m3d-confirm/runs/%s-nt" % cell)
        print("=" * 20, cell)
        print("  frozen : %s exit=%s req=%s wall=%ss" % (f["verdict"], f.get("exit"), f.get("requests"), round(f.get("wall", 0))))
        print("  confirm: %s exit=%s req=%s wall=%ss in=%s out=%s" % (
            c["verdict"], c.get("exit"), c.get("requests"), round(c.get("wall", 0)), c.get("tokensIn"), c.get("tokensOut")))
        print("  measure:", json.dumps(m)[:900])
