#!/usr/bin/env python3
"""Test the pin policy itself, including the CodeRabbit YAML-spelling bypass."""

import importlib.util
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

source = Path(__file__).with_name("check-action-pins.py")
spec = importlib.util.spec_from_file_location("action_pins", source)
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class ActionPinPolicyTests(unittest.TestCase):
    def evaluate(self, addition="", header=""):
        with TemporaryDirectory() as directory:
            workflows = Path(directory)
            (workflows / "ci.yml").write_text(
                f"jobs:\n  build:\n    runs-on: ubuntu-24.04\n    steps:\n"
                f"      - uses: actions/checkout@{policy.APPROVED['actions/checkout']}\n"
                f"      - uses: SonarSource/sonarqube-scan-action@{policy.APPROVED['SonarSource/sonarqube-scan-action']}\n"
                f"{addition}{header}", encoding="utf-8",
            )
            return policy.check(workflows)

    def test_audited_actions_pass(self):
        self.assertEqual(self.evaluate(), [])

    def test_spaces_before_colon_do_not_bypass_pin(self):
        failures = self.evaluate("      - uses : actions/checkout@v4\n")
        self.assertTrue(any("not pinned" in item for item in failures), failures)

    def test_quoted_flow_and_anchor_forms_are_checked(self):
        samples = (
            '      - "uses": "actions/checkout@v4"\n',
            '      - {uses: "actions/checkout@v4"}\n',
            '      - uses: &bad actions/checkout@v4\n      - uses: *bad\n',
        )
        for sample in samples:
            with self.subTest(sample=sample):
                failures = self.evaluate(sample)
                self.assertTrue(any("not pinned" in item for item in failures), failures)

    def test_reusable_job_action_is_checked(self):
        failures = self.evaluate(header="  shared:\n    uses : actions/checkout@v4\n")
        self.assertTrue(any("not pinned" in item for item in failures), failures)

    def test_duplicate_uses_key_rejected(self):
        failures = self.evaluate(
            f"      - uses: actions/checkout@{policy.APPROVED['actions/checkout']}\n"
            "        uses: actions/checkout@v4\n"
        )
        self.assertTrue(any("duplicate YAML mapping key" in item for item in failures), failures)

    def test_unknown_action_rejected(self):
        failures = self.evaluate("      - uses: someone/unknown@" + "0" * 40 + "\n")
        self.assertTrue(any("unreviewed action" in item for item in failures), failures)

    def test_invalid_yaml_refused(self):
        failures = self.evaluate("      - uses: [\n")
        self.assertTrue(any("invalid workflow YAML" in item for item in failures), failures)


if __name__ == "__main__":
    unittest.main()
