#!/usr/bin/env python3
"""Hand-computed checks of analyze_v4.py. Synthetic data only (no task text, no transcripts of real runs).

    python3 -I bench/value/test_analyze_v4.py
"""

import importlib.util
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("analyze_v4_under_test", os.path.join(HERE, "analyze_v4.py"))
av4 = importlib.util.module_from_spec(spec)
sys.modules["analyze_v4_under_test"] = av4
spec.loader.exec_module(av4)

GOLD = {"T1": ["src/a.py"], "T2": ["src/b.py", "src/c.py"]}
#                       T1 r1, r2     T2 r1, r2
TOKENS = {"none-lean": ((100, 140), (200, 200)), "olivium-ai": ((60, 80), (150, 130))}
SOLVED = {"none-lean": ((True, False), (False, False)), "olivium-ai": ((True, True), (True, False))}
FIRST = {"none-lean": 40, "olivium-ai": 45}


def write_jsonl(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row) + "\n")


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle)


def meter_rows(total, first_prompt, mode="live", requests=2):
    """Main rows whose tokens add up to total; the first has prompt tokens first_prompt and 0 output."""
    rows = [{"endpoint": "messages", "model": "claude-sonnet-5-5", "seq": 1, "mode": mode, "input_tokens": first_prompt,
             "output_tokens": 0, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}]
    rest = total - first_prompt
    for seq in range(2, requests + 1):
        share = rest // (requests - 1) if seq < requests else rest - (rest // (requests - 1)) * (requests - 2)
        rows.append({"endpoint": "messages", "model": "claude-sonnet-5-5", "seq": seq, "mode": mode, "input_tokens": share,
                     "output_tokens": 0, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0})
    # A background call on the small model is not a main request.
    rows.append({"endpoint": "messages", "model": "claude-haiku-5-5", "seq": 99, "mode": mode, "input_tokens": 0,
                 "output_tokens": 0, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0})
    return rows


def transcript(task, arm, card=False, failed=False):
    events = []
    if card:
        events.append({"type": "system", "subtype": "hook_response", "hook_event": "UserPromptSubmit",
                       "output": av4.CARD_PREFIX + "\n" + GOLD[task][0] + " f 1-9\n"})
    events.append({"type": "assistant", "message": {"id": "m1", "content": [
        {"type": "tool_use", "id": "u1", "name": "Bash", "input": {"command": "python -m pytest -q tests/test_x.py"}}]}})
    events.append({"type": "user", "message": {"content": [
        {"type": "tool_result", "tool_use_id": "u1", "content": ("Exit code 1\nboom" if failed else "1 passed")}]}})
    events.append({"type": "assistant", "message": {"id": "m2", "content": [
        {"type": "tool_use", "id": "u2", "name": "Edit", "input": {"file_path": "/work/repo/" + GOLD[task][0]}}]}})
    events.append({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "u2", "content": "ok"}]}})
    return events


def build_out(root, mode="live", drop=None, tokens=TOKENS, solved=SOLVED, learning_tokens=1100):
    trials = []
    order = []
    for arm in ("none-lean", "olivium-ai"):
        for t_index, task in enumerate(("T1", "T2")):
            for r_index in (0, 1):
                repeat = r_index + 1
                order.append([task, arm, repeat])
                if drop == (task, arm, repeat):
                    continue
                run_id = "%s.%s.r%d" % (task, arm, repeat)
                total = tokens[arm][t_index][r_index]
                trials.append({"run_id": run_id, "task_id": task, "arm": arm, "repeat": repeat, "status": "completed",
                               "solved": solved[arm][t_index][r_index], "cost_usd": 0.01, "requests": 3,
                               "tokens": {"input": total, "output": 0, "cache_creation": 0, "cache_read": 0}})
                run_dir = os.path.join(root, "trials", run_id)
                write_jsonl(os.path.join(run_dir, "meter_rows.jsonl"), meter_rows(total, FIRST[arm], mode))
                write_jsonl(os.path.join(run_dir, "transcript.jsonl"),
                            transcript(task, arm, card=(arm == "olivium-ai"), failed=(arm == "none-lean" and r_index == 0)))
    # An infra_error attempt that was repeated is not a scored run.
    trials.insert(0, {"run_id": "T1.none-lean.r1.x", "task_id": "T1", "arm": "none-lean", "repeat": 1, "status": "infra_error",
                      "solved": False, "cost_usd": 0.0, "requests": 0, "tokens": {}})
    write_jsonl(os.path.join(root, "trials.jsonl"), trials)
    write_jsonl(os.path.join(root, "meter", "requests.jsonl"), [{"endpoint": "messages", "mode": mode}])
    write_json(os.path.join(root, "schedule.none-lean+olivium-ai.json"), {"order": order})
    for task in ("T1", "T2"):
        write_json(os.path.join(root, "arms", task, "olivium-ai.setup.json"), {
            "status": "ok", "mode": "paid" if mode == "live" else "rehearsal", "cost_usd": 0.02,
            "learning": {"status": "ok" if mode == "live" else "mock", "model": "claude-haiku-5-5", "requests": 4,
                         "tokens": {"input": learning_tokens, "output": 0, "cache_read": 0, "cache_write": 0},
                         "kept": {"concepts": 1, "pitfalls": 0, "commands": 1, "rewrites": 1}, "dropped": 2}})
    manifest = os.path.join(root, "manifest-test.json")
    write_json(manifest, {"tasks": [{"task_id": t, "gold_files": GOLD[t], "v4dev": True} for t in ("T1", "T2")]})
    return manifest


class AnalyzeV4(unittest.TestCase):
    def run_analysis(self, **kwargs):
        root = tempfile.mkdtemp(prefix="av4-")
        manifest = build_out(root, **kwargs)
        return av4.analyze(root, manifest)

    def test_task_balanced_tokens_and_solve_points(self):
        report = self.run_analysis()
        primary = report["comparisons"]["harder"]["olivium-ai_vs_none-lean"]
        # none-lean: T1 (100+140)/2 = 120, T2 200 -> 160; olivium-ai: T1 70, T2 140 -> 105.
        self.assertEqual(primary["tokens"]["against"], 160.0)
        self.assertEqual(primary["tokens"]["arm"], 105.0)
        self.assertEqual(primary["token_ratio"], round(105 / 160, 4))
        # Per task ratios 70/120 and 140/200; median of two = their mean.
        self.assertEqual(primary["median_task_token_ratio"], round((70 / 120 + 140 / 200) / 2, 4))
        # Solved: none-lean (0.5 + 0) / 2 = 0.25; olivium-ai (1 + 0.5) / 2 = 0.75 -> +50 points.
        self.assertEqual(primary["solve_points"], 50.0)
        self.assertEqual(report["decision"]["decision"], "continue")
        self.assertTrue(report["target"]["tokens_route_met"])
        self.assertEqual(report["stamp"], "DEV")

    def test_configuration_and_behaviour_split(self):
        primary = self.run_analysis()["comparisons"]["harder"]["olivium-ai_vs_none-lean"]
        # First request 45 vs 40, 2 main requests per olivium-ai run (the haiku row is not main): config +10.
        self.assertEqual(primary["first_request_tokens"], {"arm": 45.0, "against": 40.0, "tasks": 2})
        self.assertEqual(primary["main_requests"]["arm"], 2.0)
        self.assertEqual(primary["delta_tokens"], {"total": -55.0, "configuration_prefix": 10.0, "behaviour": -65.0})

    def test_cards_hits_failures_and_first_gold_edit(self):
        report = self.run_analysis()
        self.assertEqual(report["arms"]["olivium-ai"]["cards_shown"], 4)
        self.assertEqual(report["arms"]["olivium-ai"]["card_gold_hits"], 4)
        self.assertEqual(report["arms"]["none-lean"]["cards_shown"], 0)
        # One failed Bash call per none-lean task in repeat 1.
        self.assertEqual(report["arms"]["none-lean"]["failed_calls"], 2)
        run = next(r for r in report["runs"] if r["run_id"] == "T1.none-lean.r2")
        # The gold Edit is in request 2: tokens before = both main rows = the whole run (140).
        self.assertEqual(run["first_gold_edit_request"], 2)
        self.assertEqual(run["tokens_before_first_gold_edit"], 140)
        self.assertEqual(report["infra_attempts"], 1)

    def test_learning_break_even(self):
        report = self.run_analysis()
        # 1,100 learning tokens per task base; 160 - 105 = 55 tokens saved per run -> 20 runs.
        self.assertEqual(report["amortized"]["tokens_saved_per_run"], 55.0)
        self.assertEqual(report["amortized"]["break_even_runs"], 20.0)
        self.assertEqual(report["learning"]["T1"]["olivium-ai"]["tokens_total"], 1100)
        self.assertEqual(report["amortized"]["mean_learning_cost_usd_per_task_base"], 0.02)

    def test_reused_bundle_reports_its_own_learning_cost(self):
        root = tempfile.mkdtemp(prefix="av4-")
        manifest = build_out(root)
        for task in ("T1", "T2"):
            path = os.path.join(root, "arms", task, "olivium-ai.setup.json")
            with open(path, encoding="utf-8") as handle:
                setup = json.load(handle)
            # Prepared from an inspected bundle: this OUT's meter paid nothing for learning.
            setup["cost_usd"] = 0.0
            setup["learning"].update({"reused": True, "cost_usd": 0.025})
            write_json(path, setup)
        report = av4.analyze(root, manifest)
        self.assertEqual(report["amortized"]["mean_learning_cost_usd_per_task_base"], 0.025)
        self.assertIn("($0.025) per task base", av4.markdown(report))

    def test_mock_is_stamped_and_gets_no_decision(self):
        report = self.run_analysis(mode="mock")
        self.assertEqual(report["stamp"], "MOCK")
        self.assertIsNone(report["decision"])
        self.assertIsNone(report["target"])

    def test_missing_run_is_incomplete(self):
        report = self.run_analysis(drop=("T2", "olivium-ai", 2))
        self.assertFalse(report["complete"])
        self.assertEqual(report["missing_runs"], [["T2", "olivium-ai", 2]])
        self.assertEqual(report["decision"]["decision"], "incomplete")

    def test_stop_when_neither_route_passes(self):
        tokens = {"none-lean": ((100, 100), (100, 100)), "olivium-ai": ((90, 90), (90, 90))}
        solved = {"none-lean": ((True, False), (True, False)), "olivium-ai": ((True, True), (True, False))}
        report = self.run_analysis(tokens=tokens, solved=solved)
        primary = report["comparisons"]["harder"]["olivium-ai_vs_none-lean"]
        # Ratio 0.9 > 0.80; solve 0.5 -> 0.75 is +25 points with ratio 0.9 <= 1.0: continue by the solve route.
        self.assertEqual(primary["token_ratio"], 0.9)
        self.assertEqual(primary["solve_points"], 25.0)
        self.assertEqual(report["decision"]["decision"], "continue")
        solved_same = {"none-lean": ((True, False), (True, False)), "olivium-ai": ((True, False), (True, False))}
        report = self.run_analysis(tokens=tokens, solved=solved_same)
        self.assertEqual(report["decision"]["decision"], "stop_or_redesign")
        self.assertFalse(report["target"]["tokens_route_met"])

    def test_refuses_a_v3_manifest(self):
        with self.assertRaises(SystemExit):
            av4.main(["--out", tempfile.mkdtemp(), "--report", os.devnull, "--manifest", "manifest-v3.json"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
