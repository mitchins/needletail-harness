#!/usr/bin/env python3
"""Merge SwiftPM swift-testing xunit reports for INGEST reconciliation.

FINAL-02/03: the NET-04 promptness suite runs in the isolated `timing`
lane and the OS-heavy suites run in the isolated `e2e` lane (own
processes, serialized); the bulk coverage-evidence run skips all of
them. Every lane's tests remain INGEST evidence: this script joins the
union for reconciliation. It fails closed on any structural surprise:

- every input must be a <testsuites> root (SwiftPM swift-testing schema);
- the timing report must contain ONLY TransportCancellationTests cases
  (guard against merging the wrong file);
- the e2e report must contain ONLY the lane's E2E suites;
- all reports must be pairwise disjoint (bulk skips must hold);
- the merged testcase count must equal the sum of the inputs.

Usage: merge-xunit.py <merged-out.xml> --bulk <bulk.xml> [--timing <timing.xml>] [--e2e <e2e.xml>]
Absent lane inputs are simply not merged.
"""

import sys
import xml.etree.ElementTree as ET

# Suites owned by the serialized e2e lane (must match `dev test e2e`).
E2E_SUITES = {
    "B5CEndToEndTests",
    "TOOL10DiffTests",
    "ProductionCLIWiringTests",
    "ProductionExportCLIWiringTests",
    "CrossRunGateCLITests",
    "B1ContainmentTests",
    "CrashMatrixTests",
    "TOOL09OrderedBatchTests",
    "C1ProcRunnerTests",
    "C1QualificationTests",
    "C2ExecDurableTests",
    "SessionExportTests",
}


def load(path):
    try:
        tree = ET.parse(path)
    except Exception as exc:
        sys.stderr.write(f"FAIL: cannot parse xunit {path}: {exc}\n")
        sys.exit(1)
    root = tree.getroot()
    if root.tag != "testsuites":
        sys.stderr.write(f"FAIL: {path} root is <{root.tag}>, want <testsuites>\n")
        sys.exit(1)
    return root


def cases(root):
    found = []
    for tc in root.iter("testcase"):
        suite = tc.get("classname", "")
        name = tc.get("name", "")
        found.append((suite, name))
    return found


def main():
    # usage: merge-xunit.py <merged-out.xml> --bulk <bulk.xml>
    #          [--timing <timing.xml>] [--e2e <e2e.xml>]
    args = sys.argv[1:]
    if len(args) < 3 or args[1] != "--bulk":
        sys.stderr.write(
            "usage: merge-xunit.py <merged-out.xml> --bulk <bulk.xml> [--timing <timing.xml>] [--e2e <e2e.xml>]\n"
        )
        sys.exit(1)
    out_path = args[0]
    inputs = {}
    i = 1
    while i < len(args):
        if args[i] in ("--bulk", "--timing", "--e2e") and i + 1 < len(args):
            inputs[args[i][2:]] = args[i + 1]
            i += 2
        else:
            sys.stderr.write(f"FAIL: bad merge arguments near {' '.join(args[i:])}\n")
            sys.exit(1)
    if "bulk" not in inputs:
        sys.stderr.write("FAIL: bulk report is required\n")
        sys.exit(1)
    reports = {k: load(v) for k, v in inputs.items()}
    report_cases = {k: cases(r) for k, r in reports.items()}
    if not report_cases["bulk"]:
        sys.stderr.write("FAIL: bulk report holds zero testcases\n")
        sys.exit(1)
    for suite, name in report_cases.get("timing", []):
        if "TransportCancellationTests" not in suite:
            sys.stderr.write(
                f"FAIL: timing report holds non-timing case {suite}::{name}; refusing to merge\n"
            )
            sys.exit(1)
    for suite, name in report_cases.get("e2e", []):
        if not any(s in suite for s in E2E_SUITES):
            sys.stderr.write(
                f"FAIL: e2e report holds non-e2e case {suite}::{name}; refusing to merge\n"
            )
            sys.exit(1)
    seen: dict = {}
    for kind, clist in report_cases.items():
        for case in clist:
            if case in seen:
                sys.stderr.write(
                    f"FAIL: case {case[0]}::{case[1]} in both {seen[case]} and {kind} (bulk skip broken)\n"
                )
                sys.exit(1)
            seen[case] = kind

    merged = ET.Element("testsuites")
    total_tests = total_failures = total_errors = total_skipped = 0
    for root in reports.values():
        for suite_el in root.findall("testsuite"):
            merged.append(suite_el)
    for tc in merged.iter("testcase"):
        total_tests += 1
        if tc.find("failure") is not None:
            total_failures += 1
        if tc.find("error") is not None:
            total_errors += 1
        if tc.find("skipped") is not None:
            total_skipped += 1
    expected = sum(len(v) for v in report_cases.values())
    if total_tests != expected:
        sys.stderr.write(f"FAIL: merged {total_tests} != sum of inputs {expected}\n")
        sys.exit(1)
    merged.set("tests", str(total_tests))
    merged.set("failures", str(total_failures))
    merged.set("errors", str(total_errors))
    merged.set("skipped", str(total_skipped))
    ET.indent(merged)
    try:
        ET.ElementTree(merged).write(out_path, encoding="utf-8", xml_declaration=True)
    except Exception as exc:
        sys.stderr.write(f"FAIL: cannot write {out_path}: {exc}\n")
        sys.exit(1)
    parts = " ".join(f"{k}={len(v)}" for k, v in report_cases.items())
    print(f"XUNIT MERGE OK: {parts} merged={total_tests} failures={total_failures} errors={total_errors}")


if __name__ == "__main__":
    main()
