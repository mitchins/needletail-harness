#!/usr/bin/env python3
"""Convert `llvm-cov show` dumps to SonarQube generic coverage XML.

FINAL-03: SonarCloud must measure real Swift coverage. This consumes the
line verdicts llvm-cov itself prints (NUM|COUNT| source lines), so the
emitted covered lines are exactly llvm's own accounting -- nothing is
invented, and per-file totals reconcile with `llvm-cov report` by
construction.

Scope: only first-party production files (the sonar.sources roots).
Tests, test support, checkouts and vendored code are dropped.

Usage: show2sonar.py <repo-root> <out.xml> <show1.txt> [<show2.txt> ...]
Each show dump must use absolute source paths (llvm-cov prints them).
"""

import os
import re
import sys
import xml.etree.ElementTree as ET

PROD_ROOTS = (
    "Sources/NeedletailCLI",
    "Sources/NeedletailCore",
    "Sources/NeedletailProviders",
    "Sources/NeedletailRuntime",
    "Sources/NeedletailPresentation",
    "Sources/NeedletailLineEditor",
)

LINE_RE = re.compile(r"^\s*(\d+)\|\s*([^|]*)\|")


def parse_count(raw):
    """llvm-cov show execution counts: plain ints, comma-grouped ints,
    or abbreviated thousands/millions (1.25k, 3.4M). Abbreviated forms
    are always nonzero (llvm prints a bare 0 for zero), so they mark
    covered lines; only the zero/nonzero distinction matters here."""
    s = raw.strip().replace(",", "")
    if not s or s.startswith("-"):
        return None
    if s[-1] in "kM":
        try:
            return int(float(s[:-1]) * (1000 if s[-1] == "k" else 1000000))
        except ValueError:
            return None
    try:
        return int(s)
    except ValueError:
        return None


def in_scope(repo_root, filename):
    if not filename.startswith(repo_root):
        return False
    rel = os.path.relpath(filename, repo_root).replace(os.sep, "/")
    if rel.startswith(".."):
        return False
    return rel.startswith(PROD_ROOTS)


def main():
    if len(sys.argv) < 4:
        sys.stderr.write("usage: show2sonar.py <repo-root> <out.xml> <show1.txt> ...\n")
        sys.exit(1)
    repo_root = os.path.abspath(sys.argv[1])
    out_path = sys.argv[2]
    covered = {}
    executable = {}
    cur = None
    for dump_path in sys.argv[3:]:
        try:
            fh = open(dump_path, errors="replace")
        except Exception as exc:
            sys.stderr.write(f"FAIL: cannot read {dump_path}: {exc}\n")
            sys.exit(1)
        with fh:
            for raw in fh:
                line = raw.rstrip("\n")
                if line.startswith("/") and line.endswith(":") and " " not in line.strip():
                    cur = line[:-1]
                    continue
                if cur is None:
                    continue
                m = LINE_RE.match(line)
                if not m:
                    continue
                if not in_scope(repo_root, cur):
                    continue
                lineno = int(m.group(1))
                c = parse_count(m.group(2))
                if c is None:
                    continue
                executable.setdefault(cur, set()).add(lineno)
                if c > 0:
                    covered.setdefault(cur, set()).add(lineno)
    root = ET.Element("coverage", version="1")
    total = 0
    uncovered_total = 0
    for path in sorted(executable):
        rel = os.path.relpath(path, repo_root).replace(os.sep, "/")
        fe = ET.SubElement(root, "file", path=rel)
        cov = covered.get(path, set())
        # Covered lines first, then explicit covered="false" for the
        # executable-but-uncovered remainder: omitting them would let
        # Sonar divide by the covered set alone (manufactured 100%).
        for ln in sorted(cov):
            ET.SubElement(fe, "lineToCover", lineNumber=str(ln), covered="true")
        for ln in sorted(set(executable[path]) - cov):
            ET.SubElement(fe, "lineToCover", lineNumber=str(ln), covered="false")
            uncovered_total += 1
        total += len(cov)
    ET.indent(root)
    try:
        ET.ElementTree(root).write(out_path, encoding="utf-8", xml_declaration=True)
    except Exception as exc:
        sys.stderr.write(f"FAIL: cannot write {out_path}: {exc}\n")
        sys.exit(1)
    print(f"SONAR COVERAGE OK: files={len(executable)} covered={total} uncovered={uncovered_total}")
    if not executable:
        sys.stderr.write("FAIL: zero production files with covered lines\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
