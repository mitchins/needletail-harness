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
    validate_generic_coverage(out_path)
    print(f"SONAR COVERAGE OK: files={len(executable)} covered={total} uncovered={uncovered_total}")
    if not executable:
        sys.stderr.write("FAIL: zero production files with covered lines\n")
        sys.exit(1)


# XML 1.0 legal character production (#x9 | #xA | #xD | #x20-#xD7FF |
# #xE000-#xFFFD | #x10000-#x10FFFF) — anything else is unrepresentable
# even escaped, and would make the scanner's XML reader throw.
_XML10_CHAR = re.compile(
    "^[\\u0009\\u000A\\u000D\\u0020-\\uD7FF\\uE000-\\uFFFD\\U00010000-\\U0010FFFF]*$")


def validate_generic_coverage(out_path):
    """Deterministic post-write gate over the sonar-generic-coverage.xsd
    constraints: well-formedness, root name and version, structural
    shape (coverage > file > lineToCover, nothing else), line-number
    domain (positive integer), covered vocabulary, unique relative
    non-empty paths, and XML 1.0 character validity in every attribute.

    The scanner's rejection of a bad report is a bare "Error during
    parsing" with no diagnostics, so the generator certifies its own
    output and fails loudly with counts and examples instead.
    """
    problems = []
    try:
        tree = ET.parse(out_path)
    except Exception as exc:
        sys.stderr.write("FAIL [coverage-schema]: report is not well-formed XML: %s\n" % exc)
        sys.exit(1)
    root = tree.getroot()
    if root.tag != "coverage":
        problems.append(f"root element is <{root.tag}>, want <coverage>")
    if root.get("version") != "1":
        problems.append(f"coverage@version is {root.get('version')!r}, want '1'")
    for child in root:
        if child.tag != "file":
            problems.append(f"unexpected element <{child.tag}> directly under <coverage>")
    seen_paths = set()
    nfiles = 0
    nlines = 0
    for fe in root.findall("file"):
        nfiles += 1
        path = fe.get("path")
        if not path:
            problems.append(f"file[{nfiles}] has an empty or missing path")
            continue
        if not _XML10_CHAR.match(path):
            problems.append(f"file path contains an XML 1.0-illegal character: {path!r}")
        if path.startswith("/"):
            problems.append(f"file path is absolute (want module-relative): {path}")
        if ".." in path.split("/"):
            problems.append(f"file path escapes the module root: {path}")
        if path in seen_paths:
            problems.append(f"duplicate file path: {path}")
        seen_paths.add(path)
        for le in fe.findall("lineToCover"):
            nlines += 1
            raw = le.get("lineNumber")
            try:
                n = int(raw)
                if n < 1:
                    problems.append(f"{path}: lineNumber {n} is not a positive integer")
            except (TypeError, ValueError):
                problems.append(f"{path}: lineNumber {raw!r} is not an integer")
            if le.get("covered") not in ("true", "false"):
                problems.append(f"{path}: covered is {le.get('covered')!r}, want true/false")
            for child in le:
                problems.append(f"{path}: unexpected element <{child.tag}> under <lineToCover>")
            for attr_name, attr_value in le.attrib.items():
                if attr_name not in ("lineNumber", "covered", "branchesToCover", "coveredBranches"):
                    problems.append(f"{path}: unexpected attribute @{attr_name} on <lineToCover>")
                elif not _XML10_CHAR.match(attr_value or ""):
                    problems.append(f"{path}: @{attr_name} contains an XML 1.0-illegal character")
    if nfiles == 0:
        problems.append("report contains no <file> elements")
    if problems:
        sys.stderr.write(f"FAIL [coverage-schema]: {len(problems)} violation(s) in {out_path} "
                         f"({nfiles} files, {nlines} lines):\n")
        for p in problems[:20]:
            sys.stderr.write(f"  - {p}\n")
        if len(problems) > 20:
            sys.stderr.write(f"  ... and {len(problems) - 20} more\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
