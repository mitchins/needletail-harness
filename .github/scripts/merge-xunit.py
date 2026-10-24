#!/usr/bin/env python3
"""Merge two SwiftPM swift-testing xunit reports for INGEST reconciliation.

FINAL-02 A: the NET-04 promptness suite runs in the isolated `timing` lane
(own process, no parallel siblings) while the bulk coverage-evidence run
skips it. Both reports are genuine executed evidence; INGEST reconciles
their union. This script merges them deterministically and fails closed on
any structural surprise:

- both inputs must be <testsuites> roots (SwiftPM swift-testing schema);
- the timing report must contain ONLY TransportCancellationTests cases
  (guard against merging the wrong file);
- the two reports must be disjoint (the bulk run skips the timing suite);
- the merged testcase count must equal the sum of the inputs.

Usage: merge-xunit.py <bulk.xml> <timing.xml> <merged-out.xml>
"""

import sys
import xml.etree.ElementTree as ET


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
    if len(sys.argv) != 4:
        sys.stderr.write("usage: merge-xunit.py <bulk.xml> <timing.xml> <merged-out.xml>\n")
        sys.exit(1)
    bulk_path, timing_path, out_path = sys.argv[1:4]
    bulk = load(bulk_path)
    timing = load(timing_path)

    bulk_cases = cases(bulk)
    timing_cases = cases(timing)
    if not timing_cases:
        sys.stderr.write(f"FAIL: timing report {timing_path} holds zero testcases\n")
        sys.exit(1)
    for suite, name in timing_cases:
        if "TransportCancellationTests" not in suite:
            sys.stderr.write(
                f"FAIL: timing report holds non-timing case {suite}::{name}; refusing to merge\n"
            )
            sys.exit(1)
    overlap = set(bulk_cases) & set(timing_cases)
    if overlap:
        sys.stderr.write(f"FAIL: {len(overlap)} cases in both reports (bulk skip broken): {sorted(overlap)[:5]}\n")
        sys.exit(1)

    merged = ET.Element("testsuites")
    total_tests = total_failures = total_errors = total_skipped = 0
    for root in (bulk, timing):
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
    if total_tests != len(bulk_cases) + len(timing_cases):
        sys.stderr.write(
            f"FAIL: merged {total_tests} != bulk {len(bulk_cases)} + timing {len(timing_cases)}\n"
        )
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
    print(f"XUNIT MERGE OK: bulk={len(bulk_cases)} timing={len(timing_cases)} merged={total_tests} failures={total_failures} errors={total_errors}")


if __name__ == "__main__":
    main()
