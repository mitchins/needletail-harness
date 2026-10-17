#!/usr/bin/env python3
"""Validate GitHub Actions references against audited Node 24 SHA pins."""

from pathlib import Path
import re
import sys

import yaml  # CI-only Ubuntu python3-yaml; not a Needletail runtime dependency.

# Verified against upstream Git tag objects and action.yml (runs.using=node24).
# Upgrade actions and this allow-list together, after reviewing the new revision.
APPROVED = {
    "actions/checkout": "3d3c42e5aac5ba805825da76410c181273ba90b1",  # v7.0.1
    "SonarSource/sonarqube-scan-action": "d209202bc7d53ff1cc128f7f907dac145c9d6ae9",  # v8.3.0 #ggignore public Git commit, not a token
}
SHA = re.compile(r"[0-9a-f]{40}\Z")


class StrictYAMLLoader(yaml.SafeLoader):
    """Fail closed on duplicate keys that a permissive loader would overwrite."""

    def construct_mapping(self, node, deep=False):
        self.flatten_mapping(node)
        mapping = {}
        for key_node, value_node in node.value:
            key = self.construct_object(key_node, deep=deep)
            try:
                hash(key)
            except TypeError as error:
                raise yaml.constructor.ConstructorError(
                    "while constructing mapping", node.start_mark,
                    "unhashable YAML mapping key", key_node.start_mark,
                ) from error
            if key in mapping:
                raise yaml.constructor.ConstructorError(
                    "while constructing mapping", node.start_mark,
                    f"duplicate YAML mapping key: {key}", key_node.start_mark,
                )
            mapping[key] = self.construct_object(value_node, deep=deep)
        return mapping


def check(workflows: Path) -> list[str]:
    errors: list[str] = []
    seen: set[str] = set()
    files = sorted([*workflows.glob("*.yml"), *workflows.glob("*.yaml")])
    if not files:
        return ["No workflow YAML files found"]

    def validate_action(action: object, location: str) -> None:
        if not isinstance(action, str) or "@" not in action:
            errors.append(f"{location}: expected action@40-hex-SHA, got {action!r}")
            return
        name, revision = action.rsplit("@", 1)
        if not SHA.fullmatch(revision):
            errors.append(f"{location}: action is not pinned to a full 40-hex SHA: {action}")
        elif name not in APPROVED:
            errors.append(f"{location}: unreviewed action: {name}")
        elif APPROVED[name] != revision:
            errors.append(f"{location}: SHA for {name} is not an audited Node 24 pin")
        else:
            seen.add(name)

    for path in files:
        try:
            workflow = yaml.load(path.read_text(encoding="utf-8"), Loader=StrictYAMLLoader)
        except (OSError, UnicodeError, yaml.YAMLError) as error:
            errors.append(f"{path}: invalid workflow YAML: {error}")
            continue
        if not isinstance(workflow, dict) or not isinstance(workflow.get("jobs"), dict):
            errors.append(f"{path}: expected a workflow mapping with jobs")
            continue
        for job_name, job in workflow["jobs"].items():
            location = f"{path}: jobs.{job_name}"
            if not isinstance(job, dict):
                errors.append(f"{location}: expected job mapping")
                continue
            if "uses" in job:  # Reusable workflow invocation.
                validate_action(job["uses"], f"{location}.uses")
            steps = job.get("steps", [])
            if not isinstance(steps, list):
                errors.append(f"{location}.steps: expected list")
                continue
            for i, step in enumerate(steps):
                step_location = f"{location}.steps[{i}]"
                if not isinstance(step, dict):
                    errors.append(f"{step_location}: expected step mapping")
                elif "uses" in step:
                    validate_action(step["uses"], f"{step_location}.uses")
    missing = set(APPROVED) - seen
    if missing:
        errors.append("Missing expected audited Node 24 actions: " + ", ".join(sorted(missing)))
    return errors


if __name__ == "__main__":
    root = Path(__file__).resolve().parents[2]
    problems = check(root / ".github" / "workflows")
    for problem in problems:
        print("FAIL:", problem, file=sys.stderr)
    if problems:
        sys.exit(1)
    print("ACTION PINS OK: YAML-mapped actions use only audited Node 24 SHA pins")
