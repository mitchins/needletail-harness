#!/usr/bin/env python3
"""CI-only allow-list for reviewed, full-SHA, Node 24 GitHub Actions."""

from pathlib import Path
import re
import sys

# Verified against upstream Git tags and action.yml's `runs.using: node24`.
# To upgrade, inspect the exact new action.yml revision and update this list
# and all workflow `uses:` references in the same reviewed change.
APPROVED = {
    "actions/checkout": "3d3c42e5aac5ba805825da76410c181273ba90b1",  # v7.0.1
    "SonarSource/sonarqube-scan-action": "d209202bc7d53ff1cc128f7f907dac145c9d6ae9",  # v8.3.0
}
USE = re.compile(r"^\s*(?:-\s*)?uses:\s*(\S+)")
SHA = re.compile(r"[0-9a-f]{40}\Z")


def check(workflows: Path) -> list[str]:
    errors = []
    seen = set()
    files = sorted([*workflows.glob("*.yml"), *workflows.glob("*.yaml")])
    if not files:
        return ["No workflow YAML files found"]
    for path in files:
        for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            match = USE.match(line)
            if not match:
                continue
            action = match.group(1)
            if "@" not in action:
                errors.append(f"{path}:{n}: action requires a full SHA: {action}")
                continue
            name, revision = action.rsplit("@", 1)
            if not SHA.fullmatch(revision):
                errors.append(f"{path}:{n}: action is not pinned to a 40-hex SHA: {action}")
            elif name not in APPROVED:
                errors.append(f"{path}:{n}: unreviewed action: {name}")
            elif APPROVED[name] != revision:
                errors.append(f"{path}:{n}: SHA for {name} is not the verified Node 24 pin")
            else:
                seen.add(name)
    if not set(APPROVED).issubset(seen):
        errors.append("Missing an expected pinned Node 24 action in workflows")
    return errors


if __name__ == "__main__":
    root = Path(__file__).resolve().parents[2]
    problems = check(root / ".github" / "workflows")
    for problem in problems:
        print("FAIL:", problem, file=sys.stderr)
    if problems:
        sys.exit(1)
    print("ACTION PINS OK: only reviewed full-SHA Node 24 actions")
