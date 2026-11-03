#!/usr/bin/env python3
"""M3-D fixture seeder: materialize one task's frozen fixture into a fresh
workspace. Single source of truth is plans/m3-tasks.json (frozen). T08's
40-file fixture is generated deterministically (no randomness)."""
import json
import os
import subprocess
import sys

TASKS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "plans", "m3-tasks.json")


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: m3d-seed.py <TASK-ID> <workspace-dir>", file=sys.stderr)
        return 2
    task_id, workspace = sys.argv[1], sys.argv[2]
    with open(TASKS, encoding="utf-8") as f:
        frozen = json.load(f)
    task = next(t for t in frozen["tasks"] if t["id"] == task_id)
    os.makedirs(workspace, exist_ok=True)
    fixture = task["fixture"]
    if "files" in fixture:
        for rel, content in fixture["files"].items():
            path = os.path.join(workspace, rel)
            os.makedirs(os.path.dirname(path) or workspace, exist_ok=True)
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write(content)
    elif task_id == "T08":
        for i in range(40):
            with open(os.path.join(workspace, "f%02d.py" % i), "w", encoding="utf-8") as f:
                f.write("def total():\n    return %d\n" % i)
    else:
        print("no materialization rule for %s" % task_id, file=sys.stderr)
        return 2
    subprocess.run(["git", "init", "-q", workspace], check=True)
    subprocess.run(["git", "-C", workspace, "add", "-A"], check=True)
    names = sorted(os.listdir(workspace))
    print("seeded %s: %d entries" % (task_id, len([n for n in names if n != ".git"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
