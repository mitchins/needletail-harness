#!/usr/bin/env python3
"""Measure Sonar new-code coverage locally: covered added lines / added lines.

Compares the PR diff's added production lines against the Sonar generic
coverage report's covered lines. Mirrors SonarCloud's new-code definition
(added lines in the PR) closely enough to predict the gate.

Usage: newcode-cov.py <repo> <base-sha> <head-sha> <coverage-generic.xml>
"""

import subprocess
import sys
import xml.etree.ElementTree as ET


def sh(repo, *args):
    out = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    if out.returncode != 0:
        sys.stderr.write(f"FAIL: git {' '.join(args)}: {out.stderr[:300]}\n")
        sys.exit(1)
    return out.stdout


def main():
    if len(sys.argv) != 5:
        sys.stderr.write("usage: newcode-cov.py <repo> <base> <head> <generic.xml>\n")
        sys.exit(1)
    repo, base, head, xml_path = sys.argv[1:5]
    # Added lines per production file in the PR diff.
    diff = sh(repo, "diff", "-U0", f"{base}...{head}", "--", "Sources/")
    added = {}
    cur = None
    new_line = 0
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            cur = line[len("+++ b/"):]
            added.setdefault(cur, set())
        elif line.startswith("@@"):
            # @@ -old,count +new,count @@
            part = line.split("+")[1].split(" ")[0]
            new_line = int(part.split(",")[0])
        elif line.startswith("+") and not line.startswith("+++"):
            if cur:
                added[cur].add(new_line)
            new_line += 1
        elif line.startswith("-") and not line.startswith("---"):
            pass
        else:
            new_line += 1
    try:
        tree = ET.parse(xml_path)
    except Exception as exc:
        sys.stderr.write(f"FAIL: cannot parse {xml_path}: {exc}\n")
        sys.exit(1)
    covered = {}
    executable = set()
    for fe in tree.getroot().findall("file"):
        path = fe.get("path")
        for c in fe.findall("lineToCover"):
            ln = int(c.get("lineNumber"))
            executable.add((path, ln))
            if c.get("covered") == "true":
                covered.setdefault(path, set()).add(ln)

    total_added = 0
    total_covered = 0
    total_noncode = 0
    missing_files = []
    for path, lines in sorted(added.items()):
        if not lines:
            continue
        # Only executable added lines count (mirrors Sonar's model:
        # comments/blank lines are not in the report universe).
        exe = {ln for ln in lines if (path, ln) in executable}
        total_noncode += len(lines) - len(exe)
        cov = covered.get(path, set())
        hit = exe & cov
        total_added += len(exe)
        total_covered += len(hit)
        if len(hit) < len(exe):
            missing_files.append((path, len(exe) - len(hit), len(exe)))
    pct = (100.0 * total_covered / total_added) if total_added else 100.0
    print(f"NEWCODE COVERAGE: covered={total_covered} added={total_added} pct={pct:.1f}% (non-executable added lines excluded: {total_noncode})")
    for path, miss, n in sorted(missing_files, key=lambda x: -x[1])[:20]:
        print(f"  gap {miss}/{n}: {path}")
    if total_added == 0:
        sys.stderr.write("FAIL: zero added production lines; diff range wrong\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
