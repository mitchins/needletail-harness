#!/usr/bin/env python3
"""Zero-traffic unit tests for M3 budget-accounting (adjudication fix).

Run: python3 docker/test_accounting.py (no docker, no provider, no network).
Covers: usage-line parsing (unchanged frozen semantics), budget-line
parsing (durable pre-dispatch superset), discrepancy flagging, and the
cohort ledger rule max(requests, budgetUsed).
"""
import importlib.util
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
failures = []


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + (" " + detail if detail and not cond else ""))
    if not cond:
        failures.append(name)


def load_m3d_run():
    spec = importlib.util.spec_from_file_location("m3d_run", os.path.join(HERE, "m3d-run.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def load_m3d_confirm():
    # m3d-confirm.py is import-safe (constants + defs only; the run loop
    # sits behind __main__), so the test exercises the production spent().
    spec = importlib.util.spec_from_file_location("m3d_confirm", os.path.join(HERE, "m3d-confirm.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def main():
    m = load_m3d_run()
    pa = m.parse_accounting

    old = ("needletail: sandbox approval policy composed\n"
           "usage: request run-req-2 phase=requesting epoch=e1 usage_in=100 usage_out=20 raw_bytes=900\n"
           "usage: request run-req-3 phase=requesting epoch=e1 usage_in=? usage_out=30 raw_bytes=950\n")
    usage, used, limit = pa(old)
    check("old-format: 2 usage lines", len(usage) == 2)
    check("old-format: no budget line -> None", used is None and limit is None)
    check("old-format: unknown stays ?", usage[1]["in"] is None)

    new = old + "budget: used=2 limit=15 tag=budget\n"
    usage, used, limit = pa(new)
    check("new-format: counts agree", len(usage) == 2 and used == 2 and limit == 15)

    early = ("needletail: sandbox approval policy composed\n"
             "checkpoint: capture failed, malformed, or timed out; epoch unchanged\n"
             "budget: used=23 limit=45 tag=checkpoint\n")
    usage, used, limit = pa(early)
    check("early-exit: zero usage lines", len(usage) == 0)
    check("early-exit: durable count survives", used == 23 and limit == 45)
    check("early-exit: discrepancy flags the gap", (used - len(usage)) == 23)

    unb = "budget: unbudgeted tag=budget\n"
    _, used, _ = pa(unb)
    check("unbudgeted: None", used is None)

    # Cohort ledger rule: max(requests, budgetUsed) per result file,
    # asserted against the production spent() from m3d-confirm.py.
    with tempfile.TemporaryDirectory() as tmp:
        cell = os.path.join(tmp, "T08-R1-nt")
        os.makedirs(cell)
        json.dump({"requests": 0, "budgetUsed": 23}, open(cell + "/result.json", "w"))
        cell2 = os.path.join(tmp, "T02-R1-nt")
        os.makedirs(cell2)
        json.dump({"requests": 10, "budgetUsed": 10}, open(cell2 + "/result.json", "w"))
        cell3 = os.path.join(tmp, "T09-R1-nt")
        os.makedirs(cell3)
        json.dump({"requests": 4}, open(cell3 + "/result-leg1.json", "w"))
        conf = load_m3d_confirm()
        conf.CONFIRM_RUNS = tmp
        check("ledger rule totals 10+23+4", conf.spent() == 37, "got %d" % conf.spent())

    print("failures: %d" % len(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
