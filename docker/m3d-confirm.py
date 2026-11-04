#!/usr/bin/env python3
"""M3 scoped confirmation runner (unscored).

Runs the 15 frozen cohort cells against the remediated Needletail image,
one per cell, never touching /tmp/m3d/runs. Enforces the 150-request
diagnostic allowance BEFORE each cell's provider traffic: spent (durable
result.json accounting) + next cell ceiling must fit, else STOP.
Per-run enforcement reuses the existing NEEDLETAIL_REQUEST_BUDGET +
LiveRequestBudget pre-send gate inside each container.
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TASKS = os.path.join(HERE, "..", "plans", "m3-tasks.json")
CONFIRM_RUNS = "/tmp/m3d-confirm/runs"
ALLOWANCE = 150

# Frozen cohort order (plans/m3-confirmation-cohort.md).
COHORT = [
    ("T02", 1), ("T02", 2), ("T03", 2),
    ("T05", 1), ("T05", 2),
    ("T06", 1), ("T06", 2),
    ("T07", 1), ("T07", 2),
    ("T08", 1), ("T08", 2),
    ("T10", 1), ("T10", 2),
    ("T11", 1), ("T11", 2),
]


def ceilings():
    frozen = json.load(open(TASKS))
    return {t["id"]: t["needletail"]["requestCeiling"] for t in frozen["tasks"]}


def spent():
    """Durable ledger spend: per result file, the max of the usage-line
    count and the durable pre-dispatch budget count (the budget file is
    the crash-safe superset — it counts sends whose responses never
    paired, e.g. runs that exit before the usage epilogue)."""
    total = 0
    for root, _, files in os.walk(CONFIRM_RUNS):
        for f in ("result.json", "result-leg2.json", "result-leg1.json"):
            p = os.path.join(root, f)
            if os.path.exists(p):
                try:
                    d = json.load(open(p))
                    usage_n = int(d.get("requests", 0) or 0)
                    budget_n = d.get("budgetUsed")
                    total += max(usage_n, budget_n if isinstance(budget_n, int) else usage_n)
                except Exception:
                    pass
    return total


def main():
    only = sys.argv[1:]  # optional subset like T02-R1
    os.makedirs(CONFIRM_RUNS, exist_ok=True)
    ceil = ceilings()
    for task, rep in COHORT:
        cell = "%s-R%d" % (task, rep)
        if only and cell not in only:
            continue
        use = spent()
        room = ALLOWANCE - use
        need = ceil[task]
        print("cell %s-nt: spent=%d room=%d ceiling=%d" % (cell, use, room, need), flush=True)
        if need > room:
            print("STOP: cell %s-nt does not fit the remaining allowance (%d < %d)" % (cell, room, need))
            return 2
        env = dict(os.environ)
        env["M3D_RUNS"] = CONFIRM_RUNS
        env["M3D_NT_IMAGE"] = "m3d-needletail:remediation"
        rc = subprocess.run(
            [sys.executable, os.path.join(HERE, "m3d-run.py"), task, str(rep), "nt"],
            env=env).returncode
        rundir = os.path.join(CONFIRM_RUNS, "%s-nt" % cell)
        if os.path.isdir(rundir):
            open(os.path.join(rundir, "UNSCORED-confirmation-not-in-matrix"), "w").write(
                "unscored confirmation (plans/m3-confirmation-cohort.md); never merged into M3-D\n")
        # Post-cell accounting from the durable result (counts retries,
        # malformed, failed and aborted attempts as recorded).
        now = spent()
        print("cell %s-nt done rc=%d spent=%d" % (cell, rc, now), flush=True)
    print("confirmation spent=%d/%d" % (spent(), ALLOWANCE))
    return 0


if __name__ == "__main__":
    sys.exit(main())
