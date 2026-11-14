#!/usr/bin/env python3
"""Checks for screen_v4.py on synthetic data. python3 -I bench/value/test_screen_v4.py"""

import importlib.util
import json
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("screen_v4", os.path.join(HERE, "screen_v4.py"))
sv4 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sv4)


def write_jsonl(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row) + "\n")


def build(root, trials, mode="live"):
    manifest = {"selection": {"protocol": "synthetic"},
                "tasks": [{"task_id": t, "v4dev": True} for t in ("A", "B", "C")]}
    manifest["checksum"] = sv4.manifest_checksum(manifest)
    path = os.path.join(root, "manifest.json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle)
    out = os.path.join(root, "p2")
    write_jsonl(os.path.join(out, "trials.jsonl"), trials)
    write_jsonl(os.path.join(out, "meter", "requests.jsonl"), [{"endpoint": "messages", "mode": mode}])
    return path, out


def row(task, requests, solved, status="completed"):
    return {"run_id": "%s.none-lean.r1" % task, "task_id": task, "arm": "none-lean", "repeat": 1,
            "status": status, "requests": requests, "solved": solved}


class ScreenV4(unittest.TestCase):
    def test_keeps_long_or_unsolved_tasks_and_writes_a_valid_manifest(self):
        root = tempfile.mkdtemp(prefix="sv4-")
        manifest, out = build(root, [row("A", 0, False, "infra_error"), row("A", 9, True), row("B", 4, True),
                                     row("C", 3, False)])
        dest = os.path.join(root, "screen")
        self.assertEqual(sv4.main(["--out", out, "--manifest", manifest, "--dest", dest]), 0)
        with open(os.path.join(dest, "manifest-v4dev-screened.json"), encoding="utf-8") as handle:
            screened = json.load(handle)
        self.assertEqual([t["task_id"] for t in screened["tasks"]], ["A", "C"])
        self.assertEqual(sv4.manifest_checksum(screened), screened["checksum"])
        self.assertFalse(screened["selection"]["screen"]["mock"])
        # Written once: the same destination is refused.
        self.assertEqual(sv4.main(["--out", out, "--manifest", manifest, "--dest", dest]), 1)

    def test_refuses_an_incomplete_screen(self):
        root = tempfile.mkdtemp(prefix="sv4-")
        manifest, out = build(root, [row("A", 9, True), row("B", 4, True, "budget_exhausted")])
        dest = os.path.join(root, "screen")
        self.assertEqual(sv4.main(["--out", out, "--manifest", manifest, "--dest", dest]), 1)
        self.assertFalse(os.path.exists(dest))

    def test_refuses_mock_runs_unless_allowed_and_marks_them(self):
        root = tempfile.mkdtemp(prefix="sv4-")
        manifest, out = build(root, [row("A", 9, True), row("B", 4, True), row("C", 8, True)], mode="mock")
        self.assertEqual(sv4.main(["--out", out, "--manifest", manifest, "--dest", os.path.join(root, "s1")]), 1)
        dest = os.path.join(root, "s2")
        self.assertEqual(sv4.main(["--out", out, "--manifest", manifest, "--dest", dest, "--allow-mock"]), 0)
        with open(os.path.join(dest, "screen.json"), encoding="utf-8") as handle:
            self.assertTrue(json.load(handle)["mock"])


if __name__ == "__main__":
    unittest.main()
