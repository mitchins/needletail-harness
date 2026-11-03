#!/usr/bin/env python3
"""M3-D analysis: paired task table, budgets, timings. Reads only
result.json / result-leg2.json (leg-1 files feed the totals separately).
No conclusions here — interpretation belongs in the receipt."""
import json
import os
import sys

RUNS = sys.argv[1] if len(sys.argv) > 1 else "/tmp/m3d/runs"


def load():
    rows = []
    for root, _, files in os.walk(RUNS):
        for f in ("result.json", "result-leg2.json"):
            p = os.path.join(root, f)
            if os.path.exists(p):
                try:
                    d = json.load(open(p))
                    rows.append(d)
                except Exception:
                    pass
    return rows


def main():
    rows = load()
    print("runs_with_verdicts: %d" % len(rows))
    print()
    print("%-6s %-4s %-6s %-6s %-5s %-6s %-8s %-8s %-8s %s" % (
        "task", "rep", "harness", "verdict", "req", "in", "out", "wall_s", "exit", "note"))
    by_task = {}
    for d in sorted(rows, key=lambda r: (r.get("task", ""), str(r.get("rep", "")), r.get("harness", ""))):
        note = ""
        if d.get("verdict") == "BLOCKED":
            note = (d.get("oracle") or {}).get("reason", "")
        if d.get("verdictSource", "").startswith("rescored"):
            note = "rescored-no-new-traffic"
        print("%-6s %-4s %-6s %-6s %-5s %-6s %-8s %-8.0f %-8s %s" % (
            d.get("task"), d.get("rep"), d.get("harness"), d.get("verdict"),
            d.get("requests"), d.get("tokensIn"), d.get("tokensOut"),
            float(d.get("wall", 0) or 0), str(d.get("exit")), note))
        by_task.setdefault((d.get("task"), d.get("rep")), {})[d.get("harness")] = d.get("verdict")
    print()
    print("paired (both harnesses present):")
    for (t, r), m in sorted(by_task.items()):
        if "nt" in m and "pi" in m:
            print("  %s R%s: nt=%s pi=%s" % (t, r, m["nt"], m["pi"]))
    total = sum(int(d.get("requests", 0) or 0) for d in rows)
    print()
    print("total_provider_requests(scored):", total)
    print("global_ceiling: 850")


if __name__ == "__main__":
    main()
