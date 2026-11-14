#!/usr/bin/env python3
"""Hand-computed checks of analyze_v5.py (a byte copy of the pre-registered script). Synthetic OUT
directories only: no task text, no transcript of a real run.

    python3 -I bench/value/test_analyze_v5.py
    python3 -B -m unittest bench/value/test_analyze_v5.py
"""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PATH = os.path.join(HERE, "analyze_v5.py")
spec = importlib.util.spec_from_file_location("analyze_v5_under_test", PATH)
av5 = importlib.util.module_from_spec(spec)
sys.modules["analyze_v5_under_test"] = av5
spec.loader.exec_module(av5)

# plan.md, P2: the script is the pre-registered one, byte for byte.
PREREGISTERED_SHA256 = "82f78fb343a4f8229d751e3e4c5f43ef6363b43861730f4870adc14adeebf844"

TASKS = ("T1", "T2")
#                    T1 r1, r2    T2 r1, r2
CONTROL_TOKENS = ((100, 140), (200, 200))
CONTROL_SOLVED = ((True, False), (False, False))
FIRST = {"none-lean": 40, "olivium-x": 45}
REQUESTS = 2


def write_jsonl(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row) + "\n")


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle)


def meter_rows(total, first_prompt, mode="live"):
    """REQUESTS main rows adding up to total; the first carries first_prompt prompt tokens and no output."""
    rows = [{"endpoint": "messages", "model": "claude-sonnet-5-5", "seq": 1, "mode": mode, "input_tokens": first_prompt,
             "output_tokens": 0, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}]
    rows.append({"endpoint": "messages", "model": "claude-sonnet-5-5", "seq": 2, "mode": mode,
                 "input_tokens": total - first_prompt, "output_tokens": 0, "cache_creation_input_tokens": 0,
                 "cache_read_input_tokens": 0})
    # A small-model call is not a main request.
    rows.append({"endpoint": "messages", "model": "claude-haiku-5-5", "seq": 9, "mode": mode, "input_tokens": 0,
                 "output_tokens": 0, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0})
    return rows


def transcript(with_cut=False, rewrite=False):
    events = []
    if rewrite:
        hook = {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                       "updatedInput": {"command": "wrapped", "timeout": 600000}}}
        events.append({"type": "system", "subtype": "hook_response", "hook_event": "PreToolUse",
                       "output": json.dumps(hook) + "\n"})
    events.append({"type": "assistant", "message": {"id": "m1", "content": [
        {"type": "tool_use", "id": "u1", "name": "Bash", "input": {"command": "python -m pytest -q tests/test_x.py"}}]}})
    out = "1 passed" + ("\n[olivium: cut 10 lines (500 bytes); full output: /tmp/x]" if with_cut else "")
    events.append({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "u1", "content": out}]}})
    return events


def build_out(root, x_scale=0.7, x_solved=CONTROL_SOLVED, x_arm="olivium-x", drop=None, budget=None, mock=False):
    """A two-task, two-repeat OUT. olivium-x tokens are none-lean's times x_scale."""
    order, trials = [], []
    for t_index, task in enumerate(TASKS):
        for r_index in (0, 1):
            repeat = r_index + 1
            for arm in ("none-lean", x_arm):
                order.append([task, arm, repeat])
                if drop == (task, arm, repeat):
                    continue
                control = CONTROL_TOKENS[t_index][r_index]
                tokens = control if arm == "none-lean" else int(round(control * x_scale))
                solved = (CONTROL_SOLVED if arm == "none-lean" else x_solved)[t_index][r_index]
                run_id = "%s.%s.r%d" % (task, arm, repeat)
                status = "budget_exhausted" if budget == (task, arm, repeat) else "ok"
                trials.append({"run_id": run_id, "task_id": task, "arm": arm, "repeat": repeat, "status": status,
                               "solved": solved, "cost_usd": 0.01, "requests": REQUESTS,
                               "tokens": {"input": tokens, "output": 0, "cache_creation": 0, "cache_read": 0}})
                run_dir = os.path.join(root, "trials", run_id)
                write_jsonl(os.path.join(run_dir, "meter_rows.jsonl"),
                            meter_rows(tokens, FIRST.get(arm, FIRST["olivium-x"]), "mock" if mock else "live"))
                write_jsonl(os.path.join(run_dir, "transcript.jsonl"),
                            transcript(with_cut=arm != "none-lean", rewrite=arm != "none-lean"))
    # An infra_error attempt before the scored one is not scored.
    trials.insert(0, {"run_id": "T1.none-lean.r1", "task_id": "T1", "arm": "none-lean", "repeat": 1,
                      "status": "infra_error", "solved": False, "cost_usd": 0.0, "requests": 0,
                      "tokens": {"input": 0, "output": 0, "cache_creation": 0, "cache_read": 0}})
    write_jsonl(os.path.join(root, "trials.jsonl"), trials)
    write_json(os.path.join(root, "schedule.none-lean+%s.json" % x_arm), {"seed": 20261112, "order": order})
    meter = [{"run_id": row["run_id"], "mode": "mock" if mock else "live", "cost_nanousd": 0} for row in trials]
    write_jsonl(os.path.join(root, "meter", "requests.jsonl"), meter)
    return root


class AnalyzeV5(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="av5-test-", dir=os.environ.get("TMPDIR"))
        self.addCleanup(shutil.rmtree, self.dir, True)

    def out(self, name, **kwargs):
        return build_out(os.path.join(self.dir, name), **kwargs)

    def test_script_is_the_preregistered_copy(self):
        with open(PATH, "rb") as handle:
            self.assertEqual(hashlib.sha256(handle.read()).hexdigest(), PREREGISTERED_SHA256)

    def test_pass(self):
        rep = av5.analyze(self.out("pass"), "olivium-x")
        primary = rep["primary"]
        # none-lean: T1 mean 120, T2 mean 200, task mean 160; olivium-x 84 and 140, task mean 112.
        self.assertEqual(primary["tokens"], {"arm": 112.0, "against": 160.0})
        self.assertEqual(primary["token_ratio"], 0.7)
        self.assertEqual(primary["per_task_token_ratio"], {"T1": 0.7, "T2": 0.7})
        self.assertEqual(primary["solve_points"], 0.0)
        # Configuration: (45 - 40) first-request tokens x 2 main requests = 10; behaviour the rest.
        self.assertEqual(primary["delta_tokens"], {"total": -48.0, "configuration_prefix": 10.0, "behaviour": -58.0})
        self.assertTrue(rep["complete"])
        self.assertEqual(rep["stamp"], "DEV")
        self.assertEqual(rep["infra_attempts"], 1)
        self.assertEqual(rep["decision"]["decision"], "pass")
        self.assertIn("larger part of the saving: behaviour", rep["decision"]["why"])
        x = rep["arms"]["olivium-x"]
        self.assertEqual((x["runs"], x["output_cuts_seen"], x["shaper_rewrites"], x["timeout_rewrites"]), (4, 4, 4, 4))
        self.assertEqual(rep["arms"]["none-lean"]["output_cuts_seen"], 0)

    def test_fail_on_tokens(self):
        rep = av5.analyze(self.out("tokens", x_scale=0.9), "olivium-x")
        self.assertEqual(rep["primary"]["token_ratio"], 0.9)
        self.assertEqual(rep["primary"]["solve_points"], 0.0)
        self.assertEqual(rep["decision"]["decision"], "fail")

    def test_token_bar_is_inclusive(self):
        rep = av5.analyze(self.out("bar", x_scale=0.75), "olivium-x")
        self.assertEqual(rep["primary"]["token_ratio"], 0.75)
        self.assertEqual(rep["decision"]["decision"], "pass")

    def test_fail_on_solve_points(self):
        # olivium-x solves nothing: 0 against 0.25, -25 points, under the -10 bar despite 0.7x tokens.
        rep = av5.analyze(self.out("solve", x_solved=((False, False), (False, False))), "olivium-x")
        self.assertEqual(rep["primary"]["token_ratio"], 0.7)
        self.assertEqual(rep["primary"]["solve_points"], -25.0)
        self.assertEqual(rep["decision"]["decision"], "fail")

    def test_incomplete_when_a_scheduled_run_is_missing(self):
        rep = av5.analyze(self.out("missing", drop=("T2", "olivium-x", 2)), "olivium-x")
        self.assertFalse(rep["complete"])
        self.assertEqual(rep["missing_runs"], [["T2", "olivium-x", 2]])
        self.assertEqual(rep["decision"]["decision"], "incomplete")

    def test_incomplete_when_a_budget_stopped_a_run(self):
        rep = av5.analyze(self.out("budget", budget=("T1", "olivium-x", 1)), "olivium-x")
        self.assertFalse(rep["complete"])
        self.assertEqual(rep["missing_runs"], [])
        self.assertEqual(rep["decision"]["decision"], "incomplete")

    def test_mock_meter_rows_get_no_decision(self):
        out = self.out("mock", mock=True)
        report = os.path.join(self.dir, "mock.json")
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            code = av5.main(["--out", out, "--report", report, "--md", os.path.join(self.dir, "mock.md")])
        self.assertEqual(code, 0)
        self.assertTrue(stdout.getvalue().startswith("MOCK: 8 runs;"), stdout.getvalue())
        with open(report, encoding="utf-8") as handle:
            rep = json.load(handle)
        self.assertEqual(rep["stamp"], "MOCK")
        self.assertEqual(rep["decision"], {"decision": None, "why": "MOCK"})
        with open(os.path.join(self.dir, "mock.md"), encoding="utf-8") as handle:
            self.assertIn("(MOCK)", handle.readline())

    def test_other_x_arm_is_a_dry_check(self):
        rep = av5.analyze(self.out("other", x_arm="olivium-ai"), "olivium-ai")
        self.assertEqual(rep["primary"]["token_ratio"], 0.7)
        self.assertIsNone(rep["decision"]["decision"])
        self.assertIn("only olivium-x gets a decision", rep["decision"]["why"])

    def test_missing_trials_is_exit_3(self):
        empty = os.path.join(self.dir, "empty")
        os.makedirs(empty)
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code = av5.main(["--out", empty, "--report", os.path.join(self.dir, "none.json")])
        self.assertEqual(code, 3)
        self.assertIn("no trials.jsonl", stderr.getvalue())
        self.assertFalse(os.path.exists(os.path.join(self.dir, "none.json")))


if __name__ == "__main__":
    unittest.main()
