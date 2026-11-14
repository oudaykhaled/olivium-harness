#!/usr/bin/env python3
"""Hand-computed checks of analyze.py. Synthetic data only.

  python3 -I bench/value/test_analyze.py

Every expected number below was worked out by hand from the rows in this file.
The bootstrap intervals are checked against the exact sampling distribution of
the median, derived with the binomial formula in the comments.
"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ANALYZE = os.path.join(HERE, "analyze.py")
spec = importlib.util.spec_from_file_location("analyze_under_test", ANALYZE)
analyze = importlib.util.module_from_spec(spec)
sys.modules["analyze_under_test"] = analyze
spec.loader.exec_module(analyze)

TASKS = ("T1", "T2", "T3", "T4", "T5")
#                T1          T2          T3          T4          T5
COST = {
    "none":    ((2.0, 4.0), (1.0, 1.0), (5.0, 7.0), (2.0, 2.0), (4.0, 6.0)),
    "generic": ((3.0, 3.0), (2.0, 2.0), (3.0, 3.0), (3.0, 5.0), (5.0, 5.0)),
    "olivium": ((1.0, 3.0), (1.0, 2.0), (2.0, 2.0), (2.0, 4.0), (6.0, 4.0)),
}
SOLVED = {
    "none":    ((True, False), (False, False), (True, False), (True, True), (False, False)),
    "generic": ((True, False), (False, True), (False, False), (True, True), (True, False)),
    "olivium": ((True, True), (True, False), (True, False), (True, True), (True, False)),
}


def row(task, arm, repeat, cost, solved, status="completed", suffix=""):
    return {
        "run_id": "%s.%s.r%d%s" % (task, arm, repeat, suffix),
        "task_id": task,
        "arm": arm,
        "repeat": repeat,
        "status": status,
        "solved": solved,
        "f2p_passed": 1 if solved else 0,
        "f2p_total": 1,
        "p2p_regressions": 0 if status != "infra_error" else None,
        "lint_ok": True,
        "tokens": {"input": 100, "output": 10, "cache_creation": 20, "cache_read": 300},
        "cost_usd": cost,
        "requests": 1,
        "turns": 2,
        "tool_calls": {"Read": 1},
        "files_read": 1,
        "wasted_reads": 0,
        "turns_before_first_gold_edit": 1,
        "tool_calls_before_first_gold_edit": 1,
        "patch_lines": 2,
        "wall_seconds": 1.0,
        "model": "claude-sonnet-5-5",
        "claude_code_version": "2.1.311",
        "harness_bytes": 0,
    }


def dataset(tmp, meter_mode=None, drop_meter=False):
    rows = []
    for arm in ("none", "generic", "olivium"):
        for task_index, task in enumerate(TASKS):
            for repeat in (1, 2):
                rows.append(row(task, arm, repeat, COST[arm][task_index][repeat - 1], SOLVED[arm][task_index][repeat - 1]))
    # T1 olivium repeat 1: an infra_error at $100 that was retried. Never scored.
    rows.append(row("T1", "olivium", 1, 100.0, False, status="infra_error", suffix=".a0"))
    os.makedirs(os.path.join(tmp, "meter"), exist_ok=True)
    with open(os.path.join(tmp, "trials.jsonl"), "w", encoding="utf-8") as handle:
        for item in rows:
            handle.write(json.dumps(item) + "\n")
    with open(os.path.join(tmp, "schedule.json"), "w", encoding="utf-8") as handle:
        json.dump({"tasks": list(TASKS), "repeats": 2, "order": []}, handle)
    if not drop_meter and meter_mode:
        with open(os.path.join(tmp, "meter", "requests.jsonl"), "w", encoding="utf-8") as handle:
            for item in rows:
                handle.write(json.dumps({"mode": meter_mode, "run_id": item["run_id"], "cost_nanousd": 1}) + "\n")
    return rows


def read_text(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def read_lines_as_json(path):
    return [json.loads(line) for line in read_text(path).splitlines() if line.strip()]


def run_cli(in_dir, out_dir):
    return subprocess.run([sys.executable, "-I", ANALYZE, "--in", in_dir, "--out", out_dir], capture_output=True, text=True)


class Statistics(unittest.TestCase):
    def test_percentile(self):
        self.assertEqual(analyze.percentile([1.0, 2.0, 3.0, 4.0], 0.5), 2.5)
        self.assertEqual(analyze.percentile([10.0, 20.0], 0.25), 12.5)
        self.assertEqual(analyze.percentile([7.0], 0.5), 7.0)
        self.assertAlmostEqual(analyze.percentile([0.0, 1.0, 2.0, 3.0, 4.0], 0.975), 3.9)

    def test_bootstrap_eleven_tasks_matches_exact_distribution(self):
        # With 11 equally likely values, the median of a resample is the k-th
        # smallest value or below exactly when at least 6 of the 11 draws land
        # in the k smallest: P = sum over j>=6 of C(11,j) (k/11)^j (1-k/11)^(11-j).
        # k=1: 0.0000, k=2: 0.0072, k=3: 0.0511. The 2.5% quantile is therefore
        # the 3rd smallest value, and symmetry gives the 9th smallest for 97.5%.
        low, high = analyze.bootstrap_interval([float(item) for item in range(11)])
        self.assertEqual((low, high), (2.0, 8.0))

    def test_bootstrap_five_tasks_matches_exact_distribution(self):
        # The median of 5 draws is the smallest value when at least 3 draws are
        # that value: P = 0.0579, above 2.5%, so the 2.5% quantile is the minimum
        # and by symmetry the 97.5% quantile is the maximum.
        low, high = analyze.bootstrap_interval([-1.0, 0.5, -4.0, 1.0, 0.0])
        self.assertEqual((low, high), (-4.0, 1.0))

    def test_same_seed_same_interval(self):
        values = [0.2, 1.5, -0.7, 3.0, 2.2, 0.1]
        self.assertEqual(analyze.bootstrap_interval(values), analyze.bootstrap_interval(values))

    def test_constant_differences_give_a_point_interval(self):
        self.assertEqual(analyze.bootstrap_interval([2.0, 2.0, 2.0]), (2.0, 2.0))


class Pipeline(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.in_dir = os.path.join(self.tmp.name, "in")
        self.out_dir = os.path.join(self.tmp.name, "out")
        os.makedirs(self.in_dir)

    def run_and_load(self, **kwargs):
        dataset(self.in_dir, **kwargs)
        done = run_cli(self.in_dir, self.out_dir)
        self.assertEqual(done.returncode, 0, done.stderr)
        with open(os.path.join(self.out_dir, "results.json"), encoding="utf-8") as handle:
            return json.load(handle)

    def test_per_task_means_and_median_differences(self):
        results = self.run_and_load(meter_mode="live")
        # Cost means per task (none): 3, 1, 6, 2, 5; olivium: 2, 1.5, 2, 3, 5.
        none_means = [results["per_task"][t]["none"]["means"]["cost_usd"] for t in TASKS]
        olivium_means = [results["per_task"][t]["olivium"]["means"]["cost_usd"] for t in TASKS]
        self.assertEqual(none_means, [3.0, 1.0, 6.0, 2.0, 5.0])
        self.assertEqual(olivium_means, [2.0, 1.5, 2.0, 3.0, 5.0])
        # Differences -1, +0.5, -4, +1, 0: sorted -4, -1, 0, 0.5, 1, median 0.
        cost_vs_none = results["comparisons"]["olivium_minus_none"]["cost_usd"]
        self.assertEqual([cost_vs_none["per_task"][t] for t in TASKS], [-1.0, 0.5, -4.0, 1.0, 0.0])
        self.assertEqual(cost_vs_none["median"], 0.0)
        self.assertEqual(cost_vs_none["ci95"], [-4.0, 1.0])
        # Against generic (means 3, 2, 3, 4, 5): -1, -0.5, -1, -1, 0: median -1.
        # P(median <= -1) = P(at least 3 of 5 draws among the three -1s) = 0.683,
        # so the 2.5% quantile is -1; P(median <= -0.5) = 0.942 < 0.975, so 97.5% is 0.
        cost_vs_generic = results["comparisons"]["olivium_minus_generic"]["cost_usd"]
        self.assertEqual(cost_vs_generic["median"], -1.0)
        self.assertEqual(cost_vs_generic["ci95"], [-1.0, 0.0])

    def test_solved_rate_difference(self):
        results = self.run_and_load(meter_mode="live")
        # Share solved, olivium minus none, per task: 1-0.5, 0.5-0, 0.5-0.5, 1-1, 0.5-0.
        # Differences 0.5, 0.5, 0, 0, 0.5: median 0.5.
        solved = results["comparisons"]["olivium_minus_none"]["solved"]
        self.assertEqual([solved["per_task"][t] for t in TASKS], [0.5, 0.5, 0.0, 0.0, 0.5])
        self.assertEqual(solved["median"], 0.5)

    def test_cost_per_solved_task(self):
        results = self.run_and_load(meter_mode="live")
        # none: cost 6+2+12+4+10 = 34, 4 solved. generic: 6+4+6+8+10 = 34, 5 solved.
        # olivium: 4+3+4+6+10 = 27, 7 solved.
        self.assertEqual(results["arms"]["none"]["cost_per_solved_usd"], 8.5)
        self.assertEqual(results["arms"]["generic"]["cost_per_solved_usd"], 6.8)
        self.assertAlmostEqual(results["arms"]["olivium"]["cost_per_solved_usd"], 27.0 / 7.0, places=8)
        # The $100 infra_error row is excluded from scored cost and counted apart.
        self.assertEqual(results["arms"]["olivium"]["total_cost_usd"], 27.0)
        self.assertEqual(results["arms"]["olivium"]["infra_error_cost_usd"], 100.0)
        self.assertEqual(results["arms"]["olivium"]["by_status"]["infra_error"], 1)

    def test_outcome_counts_and_cost_of_limit_runs(self):
        dataset(self.in_dir, meter_mode="live")
        path = os.path.join(self.in_dir, "trials.jsonl")
        rows = read_lines_as_json(path)
        # A budget_exhausted run: cost counts, unsolved, and it is reported.
        target = next(r for r in rows if r["task_id"] == "T5" and r["arm"] == "none" and r["repeat"] == 1)
        target.update({"status": "budget_exhausted", "solved": False})
        with open(path, "w", encoding="utf-8") as handle:
            for item in rows:
                handle.write(json.dumps(item) + "\n")
        done = run_cli(self.in_dir, self.out_dir)
        self.assertEqual(done.returncode, 0, done.stderr)
        results = json.loads(read_text(os.path.join(self.out_dir, "results.json")))
        self.assertEqual(results["input"]["budget_exhausted"], 1)
        self.assertEqual(results["arms"]["none"]["total_cost_usd"], 34.0)
        self.assertEqual(results["arms"]["none"]["solved"], 4)
        report = read_text(os.path.join(self.out_dir, "report.md"))
        self.assertIn("1 runs were cut off by a spending limit", report)

    def test_null_metric_excludes_that_task_only(self):
        dataset(self.in_dir, meter_mode="live")
        path = os.path.join(self.in_dir, "trials.jsonl")
        rows = read_lines_as_json(path)
        for item in rows:
            # T1 "none" never edited a fixed file.
            if item["task_id"] == "T1" and item["arm"] == "none":
                item["turns_before_first_gold_edit"] = None
            # T2 olivium edited on one repeat only; its mean uses that repeat.
            if item["task_id"] == "T2" and item["arm"] == "olivium" and item["repeat"] == 2:
                item["turns_before_first_gold_edit"] = None
            if item["task_id"] == "T2" and item["arm"] == "olivium" and item["repeat"] == 1:
                item["turns_before_first_gold_edit"] = 5
        with open(path, "w", encoding="utf-8") as handle:
            for item in rows:
                handle.write(json.dumps(item) + "\n")
        done = run_cli(self.in_dir, self.out_dir)
        self.assertEqual(done.returncode, 0, done.stderr)
        results = json.loads(read_text(os.path.join(self.out_dir, "results.json")))
        entry = results["comparisons"]["olivium_minus_none"]["turns_before_first_gold_edit"]
        self.assertEqual(entry["tasks_used"], 4)
        self.assertEqual(entry["tasks_excluded"], ["T1"])
        # T2: olivium mean 5 (one repeat counted) minus none mean 1 = 4.
        self.assertEqual(entry["per_task"]["T2"], 4.0)

    def stamped_files(self):
        names = ["report.md", "results.json"] + [
            name for name in os.listdir(self.out_dir) if name.endswith(".svg")
        ]
        return [os.path.join(self.out_dir, name) for name in names]

    def test_mock_meter_stamps_every_output(self):
        results = self.run_and_load(meter_mode="mock")
        self.assertTrue(results["REHEARSAL"])
        self.assertGreaterEqual(len(self.stamped_files()), 7)
        for path in self.stamped_files():
            self.assertIn("REHEARSAL", read_text(path), path)

    def test_no_meter_log_stamps_rehearsal(self):
        results = self.run_and_load(drop_meter=True)
        self.assertTrue(results["REHEARSAL"])

    def test_live_meter_is_not_stamped_and_keeps_pilot_note(self):
        results = self.run_and_load(meter_mode="live")
        self.assertFalse(results["REHEARSAL"])
        for path in self.stamped_files():
            text = read_text(path)
            self.assertNotIn("REHEARSAL", text.replace('"REHEARSAL": false', ""), path)
            self.assertIn("Pilot: 5 tasks", text, path)

    def test_duplicate_scored_rows_are_refused(self):
        rows = dataset(self.in_dir, meter_mode="live")
        with open(os.path.join(self.in_dir, "trials.jsonl"), "a", encoding="utf-8") as handle:
            handle.write(json.dumps(rows[0]) + "\n")
        done = run_cli(self.in_dir, self.out_dir)
        self.assertEqual(done.returncode, 3)



# ------------------------------------------------------------------ protocol 3
TASKS6 = ("T1", "T2", "T3", "T4", "T5", "T6")


def row3(task, arm, repeat, tokens, solved, turns=2, requests=2, denials=0, tool_calls=None, cost=0.01):
    item = row(task, arm, repeat, cost, solved)
    # Total tokens = input + output + cache_creation + cache_read = `tokens`.
    item.update({
        "tokens": {"input": 10, "output": 20, "cache_creation": 30, "cache_read": tokens - 60},
        "turns": turns, "requests": requests, "permission_denials": denials,
        "hook_blocks": 0, "tool_calls": tool_calls or {"Read": 1},
        "protocol": 3, "pilot": False,
    })
    return item


def manifest_v3(tasks=TASKS6, languages=None, selection=None):
    """A synthetic frozen manifest; the checksum is lib/common.py's rule, computed by hand here."""
    import hashlib
    manifest = {
        "selection": dict({"status": "frozen", "t4_share": {"reached_t4": 10, "rejected_by_t4": 6, "share": 0.6},
                           "census": {"pool_tasks": len(tasks), "full_suite_green_at_base": 2}}, **(selection or {})),
        "tasks": [{"task_id": task, "language": (languages or {}).get(task, "python"), "toolchain_nondefault": index % 2 == 1,
                   "full_suite_green_at_base": index < 2, "gold_files": ["src/a.py", "CHANGES.rst"] if index == 0 else ["src/a.py"]}
                  for index, task in enumerate(tasks)],
    }
    canonical = json.dumps({"selection": manifest["selection"], "tasks": manifest["tasks"]},
                           sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    manifest["checksum"] = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    return manifest


def dataset_v3(tmp, rows, tasks=TASKS6, meter_mode="live", trim=None, record="scored", manifest=None):
    os.makedirs(os.path.join(tmp, "meter"), exist_ok=True)
    manifest = manifest or manifest_v3(tasks)
    with open(os.path.join(tmp, "manifest.json"), "w", encoding="utf-8") as handle:
        json.dump(manifest, handle)
    if record is not None:
        with open(os.path.join(tmp, "protocol.json"), "w", encoding="utf-8") as handle:
            json.dump({"format": "olivium-bench-out-v3", "protocol": 3, "mode": record, "pilot": record == "pilot",
                       "manifest_checksum": manifest["checksum"]}, handle)
    with open(os.path.join(tmp, "trials.jsonl"), "w", encoding="utf-8") as handle:
        for item in rows:
            handle.write(json.dumps(item) + "\n")
    with open(os.path.join(tmp, "schedule.json"), "w", encoding="utf-8") as handle:
        json.dump({"tasks": list(tasks), "repeats": 3, "order": []}, handle)
    with open(os.path.join(tmp, "meter", "requests.jsonl"), "w", encoding="utf-8") as handle:
        for item in rows:
            handle.write(json.dumps({"mode": meter_mode, "run_id": item["run_id"], "cost_nanousd": 1}) + "\n")
    if trim is not None:
        with open(os.path.join(tmp, "trim.json"), "w", encoding="utf-8") as handle:
            json.dump(trim, handle)
    return manifest


def grid(none_tokens=1000, olivium_tokens=500, none_solved=None, olivium_solved=None, tasks=TASKS6, **olivium):
    """3 repeats per task. *_solved maps a task to the number of solved repeats (default 3)."""
    rows = []
    for task in tasks:
        for repeat in (1, 2, 3):
            rows.append(row3(task, "none", repeat, none_tokens, repeat <= (none_solved or {}).get(task, 3)))
            rows.append(row3(task, "olivium", repeat, olivium_tokens, repeat <= (olivium_solved or {}).get(task, 3), **olivium))
    return rows


def run_v3(in_dir, out_dir, *extra, **options):
    """The analysis with the manifest dataset_v3 wrote and its checksum (or the given ones)."""
    manifest = options.get("manifest", os.path.join(in_dir, "manifest.json"))
    checksum = options.get("checksum")
    if checksum is None and manifest and os.path.exists(manifest):
        checksum = read_json_file(manifest)["checksum"]
    args = ["--protocol", "3"]
    if manifest:
        args += ["--manifest", manifest]
    if checksum:
        args += ["--manifest-checksum", checksum]
    done = subprocess.run([sys.executable, "-I", ANALYZE, "--in", in_dir, "--out", out_dir] + args + list(extra),
                          capture_output=True, text=True)
    results = read_json_file(os.path.join(out_dir, "results.json")) if done.returncode == 0 else None
    return done, results


def read_json_file(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


class SignFlip(unittest.TestCase):
    def test_exact_p_values_worked_by_hand(self):
        # [1, 2, 3]: the 8 signed sums are 6, 4, 2, 0, 0, -2, -4, -6; |S| >= 6 in 2 of 8.
        self.assertEqual(analyze.sign_flip_p([1.0, 2.0, 3.0]), 0.25)
        # n equal values of one sign: only all-plus and all-minus reach |S| = n.
        self.assertEqual(analyze.sign_flip_p([1.0] * 5), 2 / 32.0)
        self.assertEqual(analyze.sign_flip_p([1.0] * 6), 2 / 64.0)
        # [3, -1, 1, 1], S = 4: sums of +-3 +-1 +-1 +-1 with |sum| >= 4 are 6 (1 way),
        # 4 (3 ways) and their negatives: 8 of 16.
        self.assertEqual(analyze.sign_flip_p([3.0, -1.0, 1.0, 1.0]), 0.5)
        # Zeros carry no sign: [0, 1, 1] is [1, 1], 2 of 4.
        self.assertEqual(analyze.sign_flip_p([0.0, 1.0, 1.0]), 0.5)
        self.assertEqual(analyze.sign_flip_p([]), 1.0)
        self.assertEqual(analyze.sign_flip_p([0.0, 0.0]), 1.0)
        # Ties within float noise count: thirds sum to exactly 1 only on paper.
        self.assertEqual(analyze.sign_flip_p([1 / 3.0] * 3), 2 / 8.0)

    def test_meet_in_the_middle_equals_brute_force(self):
        import itertools
        import random as stdlib_random
        rng = stdlib_random.Random(7)
        for count in (1, 2, 7, 11, 12):
            values = [rng.uniform(-2, 2) for _ in range(count)]
            observed = abs(sum(values))
            extreme = sum(
                1 for signs in itertools.product((1, -1), repeat=count)
                if abs(sum(sign * value for sign, value in zip(signs, values))) >= observed - 1e-9 * max(1.0, observed)
            )
            self.assertEqual(analyze.sign_flip_p(values), extreme / float(2 ** count), count)

    def test_more_tasks_than_the_exact_limit_is_refused(self):
        with self.assertRaises(analyze.DataError):
            analyze.sign_flip_p([1.0] * (analyze.SIGN_FLIP_MAX_TASKS + 1))

    def test_bootstrap_mean_interval(self):
        self.assertEqual(analyze.bootstrap_mean_interval([0.25, 0.25, 0.25]), (0.25, 0.25))
        values = [0.0, 1.0, -1.0, 0.5, 0.25]
        self.assertEqual(analyze.bootstrap_mean_interval(values), analyze.bootstrap_mean_interval(values))
        low, high = analyze.bootstrap_mean_interval(values)
        self.assertTrue(-1.0 <= low < 0.15 < high <= 1.0)


class Protocol3(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.in_dir = os.path.join(self.tmp.name, "in")
        self.out_dir = os.path.join(self.tmp.name, "out")
        os.makedirs(self.in_dir)

    def run_grid(self, *extra, **kwargs):
        trim = kwargs.pop("trim", None)
        tasks = kwargs.get("tasks", TASKS6)
        dataset_v3(self.in_dir, grid(**kwargs), tasks=tasks, trim=trim)
        done, results = run_v3(self.in_dir, self.out_dir, *extra)
        self.assertEqual(done.returncode, 0, done.stderr)
        return results

    def test_half_the_tokens_on_six_tasks_is_dramatic(self):
        results = self.run_grid()
        tokens = results["primary"]["tokens"]
        self.assertEqual(tokens["estimate"], 0.5)
        self.assertEqual(tokens["ci95"], [0.5, 0.5])
        self.assertEqual(tokens["sign_flip_p"], 0.03125)
        self.assertTrue(tokens["below_null"])
        self.assertEqual(results["primary"]["solve_rate"]["estimate"], 0.0)
        self.assertEqual(results["verdict"]["verdict"], "dramatic")
        self.assertIn("**Verdict: dramatic**", read_text(os.path.join(self.out_dir, "report.md")))

    def test_five_tasks_cannot_pass_however_large_the_saving(self):
        # The interval excludes 1, but the sign-flip test cannot go below 2/32 = 0.0625.
        results = self.run_grid(tasks=TASKS6[:5])
        tokens = results["primary"]["tokens"]
        self.assertTrue(tokens["interval_excludes_null"])
        self.assertEqual(tokens["sign_flip_p"], 0.0625)
        self.assertFalse(tokens["below_null"])
        self.assertEqual(results["verdict"]["verdict"], "no_demonstrated")

    def test_a_tenth_fewer_tokens_is_measurable(self):
        results = self.run_grid(olivium_tokens=900)
        self.assertEqual(results["primary"]["tokens"]["estimate"], 0.9)
        self.assertEqual(results["verdict"]["verdict"], "measurable")

    def test_lost_solves_outside_tolerance_give_the_accuracy_warning(self):
        # T1 and T2 lose one of three repeats: differences -1/3, -1/3, 0, 0, 0, 0; mean -11.1
        # points, below -10; sign-flip over the two non-zero values: 2 of 4 = 0.5.
        results = self.run_grid(olivium_solved={"T1": 2, "T2": 2})
        solve = results["primary"]["solve_rate"]
        self.assertAlmostEqual(solve["estimate"], -1 / 9.0)
        self.assertEqual(solve["sign_flip_p"], 0.5)
        self.assertFalse(solve["below_null"])
        self.assertEqual(results["verdict"]["verdict"], "gain_with_accuracy_warning")
        self.assertFalse(results["verdict"]["checks"]["solve_within_tolerance"])

    def test_tolerance_points_decide_between_dramatic_and_the_warning(self):
        # One lost repeat: mean -1/18 = -5.6 points.
        self.assertEqual(self.run_grid(olivium_solved={"T1": 2})["verdict"]["verdict"], "dramatic")
        results = self.run_grid("--tolerance-points", "5", olivium_solved={"T1": 2})
        self.assertEqual(results["verdict"]["verdict"], "gain_with_accuracy_warning")
        self.assertEqual(results["design"]["tolerance_points"], 5)

    def test_more_than_one_refusal_per_ten_olivium_runs_is_failure(self):
        # 18 olivium runs. One refusal each in 2 runs: 2 x 10 = 20 > 18.
        rows = grid()
        olivium_rows = [item for item in rows if item["arm"] == "olivium"]
        olivium_rows[0]["permission_denials"] = 1
        dataset_v3(self.in_dir, rows)
        _done, results = run_v3(self.in_dir, self.out_dir)
        self.assertFalse(results["refusals"]["over_limit"])
        self.assertEqual(results["verdict"]["verdict"], "dramatic")
        olivium_rows[1]["permission_denials"] = 1
        dataset_v3(self.in_dir, rows)
        _done, results = run_v3(self.in_dir, self.out_dir)
        self.assertEqual(results["refusals"]["refusals"], 2)
        self.assertTrue(results["refusals"]["over_limit"])
        self.assertEqual(results["verdict"]["verdict"], "failure")

    def test_tokens_significantly_higher_is_failure(self):
        results = self.run_grid(olivium_tokens=2000)
        self.assertTrue(results["primary"]["tokens"]["above_null"])
        self.assertEqual(results["verdict"]["verdict"], "failure")

    def test_twenty_points_more_solved_is_dramatic_at_equal_tokens(self):
        results = self.run_grid(olivium_tokens=1000, none_solved={task: 1 for task in TASKS6})
        solve = results["primary"]["solve_rate"]
        self.assertAlmostEqual(solve["estimate"], 2 / 3.0)
        self.assertEqual(solve["sign_flip_p"], 0.03125)
        self.assertEqual(results["primary"]["tokens"]["sign_flip_p"], 1.0)
        self.assertEqual(results["verdict"]["verdict"], "dramatic")

    def test_behaviour_only_ratio_adds_the_trim_back_per_turn(self):
        trim = {"format": "olivium-bench-trim-v1", "method": "shape_capture",
                "tasks": {task: {"trim_tokens": 100} for task in TASKS6}}
        results = self.run_grid(trim=trim, turns=2, requests=3)
        behaviour = results["secondary"]["behaviour_only"]
        self.assertTrue(behaviour["available"])
        # (500 + 100 x 2) / 1000 = 0.7; with requests (500 + 100 x 3) / 1000 = 0.8.
        self.assertEqual(behaviour["by_turns"]["estimate"], 0.7)
        self.assertEqual(behaviour["by_requests_sensitivity"]["estimate"], 0.8)
        # (0.7 - 0.5) / (1 - 0.5)
        self.assertEqual(behaviour["configuration_share_of_saving"], 0.4)

    def test_behaviour_only_is_unavailable_without_a_trim_never_zero(self):
        behaviour = self.run_grid()["secondary"]["behaviour_only"]
        self.assertFalse(behaviour["available"])
        self.assertIn("no trim file", behaviour["reason"])
        wrong = self.run_grid(trim={"format": "something-else", "tasks": {}})["secondary"]["behaviour_only"]
        self.assertFalse(wrong["available"])
        partial = {"format": "olivium-bench-trim-v1", "tasks": {task: {"trim_tokens": 100} for task in TASKS6[1:]}}
        by_turns = self.run_grid(trim=partial)["secondary"]["behaviour_only"]["by_turns"]
        self.assertEqual(by_turns["tasks_used"], 5)
        self.assertEqual(sorted(by_turns["tasks_excluded"]), ["T1"])

    def test_none_lean_is_reported_apart_and_refused_by_earlier_protocols(self):
        rows = grid()
        rows += [row3(task, "none-lean", 1, 800, True) for task in TASKS6]
        dataset_v3(self.in_dir, rows)
        _done, results = run_v3(self.in_dir, self.out_dir)
        self.assertEqual(results["primary"]["tokens"]["estimate"], 0.5)
        self.assertEqual(results["secondary"]["none_lean_vs_none"]["tokens"]["estimate"], 0.8)
        self.assertEqual(results["verdict"]["verdict"], "dramatic")
        done = run_cli(self.in_dir, os.path.join(self.tmp.name, "p1"))
        self.assertEqual(done.returncode, 3)
        self.assertIn("unknown arm none-lean", done.stderr)

    def test_subagent_use_and_dollars_per_setup(self):
        rows = grid()
        olivium_rows = [item for item in rows if item["arm"] == "olivium"]
        olivium_rows[0]["tool_calls"] = {"Agent": 2, "Read": 1}
        olivium_rows[1]["tool_calls"] = {"Task": 1}
        transcript_dir = os.path.join(self.in_dir, "trials", olivium_rows[0]["run_id"])
        os.makedirs(transcript_dir)
        events = [
            {"type": "assistant", "parent_tool_use_id": None,
             "message": {"id": "m1", "usage": {"input_tokens": 999, "output_tokens": 1}}},
            {"type": "assistant", "parent_tool_use_id": "toolu_1",
             "message": {"id": "s1", "usage": {"input_tokens": 40, "output_tokens": 5, "cache_read_input_tokens": 50}}},
            {"type": "assistant", "parent_tool_use_id": "toolu_1",
             "message": {"id": "s1", "usage": {"input_tokens": 40, "output_tokens": 5, "cache_read_input_tokens": 50}}},
            {"type": "assistant", "parent_tool_use_id": "toolu_1",
             "message": {"id": "s2", "usage": {"input_tokens": 5}}},
        ]
        with open(os.path.join(transcript_dir, "transcript.jsonl"), "w", encoding="utf-8") as handle:
            for event in events:
                handle.write(json.dumps(event) + "\n")
        dataset_v3(self.in_dir, rows)
        _done, results = run_v3(self.in_dir, self.out_dir)
        olivium = results["secondary"]["subagents"]["by_setup"]["olivium"]
        self.assertEqual((olivium["runs"], olivium["runs_with_subagent"], olivium["subagent_calls"]), (18, 2, 3))
        # s1 counted once (95), s2 (5); the main-session message is not a subagent's.
        self.assertEqual((olivium["transcripts_read"], olivium["subagent_tokens"]), (1, 100))
        self.assertEqual(results["secondary"]["subagents"]["by_setup"]["none"]["subagent_calls"], 0)
        dollars = results["secondary"]["dollars"]["by_setup"]["none"]
        self.assertEqual(dollars["mean_cost_usd"], 0.01)
        self.assertEqual(dollars["cache_read_share_of_tokens"], 0.94)
        self.assertIn("cache", results["secondary"]["dollars"]["note"])

    def test_deprecation_compliance_only_where_the_rule_is_shown(self):
        sentence = "When removing public API, warn first."
        arm = os.path.join(self.in_dir, "arms", "T1", "olivium")
        os.makedirs(os.path.join(arm, ".olivium"))
        spec_doc = {"spec": {"rules": [{"statement": sentence, "source": {"signal": "practices.deprecation"}}]}}
        with open(os.path.join(arm, ".olivium", "spec.json"), "w", encoding="utf-8") as handle:
            json.dump(spec_doc, handle)
        with open(os.path.join(arm, "CLAUDE.md"), "w", encoding="utf-8") as handle:
            handle.write("<!-- header -->\n- %s\n" % sentence)
        rows = grid()
        for item in rows:
            if item["task_id"] != "T1":
                continue
            patch = PATCHES["py_class_attribute_removed"][0] if item["arm"] == "none" else PATCHES["py_attribute_kept_with_warning"][0]
            if item["arm"] == "olivium" and item["repeat"] == 3:
                continue  # no patch recorded
            directory = os.path.join(self.in_dir, "trials", item["run_id"])
            os.makedirs(directory)
            with open(os.path.join(directory, "agent.patch"), "w", encoding="utf-8") as handle:
                handle.write(patch)
        dataset_v3(self.in_dir, rows)
        _done, results = run_v3(self.in_dir, self.out_dir)
        compliance = results["secondary"]["deprecation_compliance"]
        self.assertEqual(compliance["tasks_where_rule_fired"], ["T1"])
        none = compliance["by_task"]["T1"]["none"]
        olivium = compliance["by_task"]["T1"]["olivium"]
        self.assertEqual((none["removed_without_warning"], none["compliant"]), (3, 0))
        self.assertEqual((olivium["kept_with_warning"], olivium["no_patch"], olivium["compliant"]), (2, 1, 2))

    def test_mock_meter_stamps_rehearsal(self):
        dataset_v3(self.in_dir, grid(), meter_mode="mock")
        _done, results = run_v3(self.in_dir, self.out_dir)
        self.assertTrue(results["REHEARSAL"])
        self.assertTrue(read_text(os.path.join(self.out_dir, "report.md")).startswith("# REHEARSAL: mock model, not a result"))

    def test_protocol_flag_one_or_two_keeps_the_earlier_output(self):
        dataset(self.in_dir, meter_mode="live")
        outputs = {}
        for name, extra in (("plain", []), ("p1", ["--protocol", "1"]), ("p2", ["--protocol", "2"])):
            out = os.path.join(self.tmp.name, name)
            done = subprocess.run([sys.executable, "-I", ANALYZE, "--in", self.in_dir, "--out", out] + extra,
                                  capture_output=True, text=True)
            self.assertEqual(done.returncode, 0, done.stderr)
            outputs[name] = {file_name: read_text(os.path.join(out, file_name)) for file_name in sorted(os.listdir(out))}
        self.assertEqual(outputs["plain"], outputs["p1"])
        self.assertEqual(outputs["plain"], outputs["p2"])
        self.assertIn("chart_cost_per_solved.svg", outputs["plain"])


# Twelve synthetic patches and the outcome a person reading them would give.
PATCHES = {
    "py_class_attribute_removed": ("""diff --git a/src/acme/widget.py b/src/acme/widget.py
--- a/src/acme/widget.py
+++ b/src/acme/widget.py
@@ -10,7 +10,6 @@ class Widget:
     color = "red"
-    legacy_size = 3
 
     def draw(self):
""", "removed_without_warning"),
    "py_module_function_removed": ("""diff --git a/src/acme/api.py b/src/acme/api.py
--- a/src/acme/api.py
+++ b/src/acme/api.py
@@ -1,9 +1,5 @@
 import os
-
-def old_render(value):
-    return str(value)
-
 def render(value):
""", "removed_without_warning"),
    "py_method_removed_with_warning": ("""diff --git a/src/acme/widget.py b/src/acme/widget.py
--- a/src/acme/widget.py
+++ b/src/acme/widget.py
@@ -1,4 +1,5 @@
 import typing
+import warnings
@@ -20,6 +21,9 @@ class Widget:
-    def resize(self, size):
-        self.size = size
+    def __getattr__(self, name):
+        if name == "resize":
+            warnings.warn("resize is deprecated", DeprecationWarning, stacklevel=2)
+        raise AttributeError(name)
""", "removed_with_warning"),
    "py_attribute_kept_with_warning": ("""diff --git a/src/acme/widget.py b/src/acme/widget.py
--- a/src/acme/widget.py
+++ b/src/acme/widget.py
@@ -10,7 +10,11 @@ class Widget:
-    legacy_size = 3
+    legacy_size: None = None
+
+    def __init__(self):
+        if self.legacy_size is not None:
+            warnings.warn("legacy_size is deprecated and will be removed", DeprecationWarning)
""", "kept_with_warning"),
    "py_private_function_removed": ("""diff --git a/src/acme/api.py b/src/acme/api.py
--- a/src/acme/api.py
+++ b/src/acme/api.py
@@ -1,6 +1,3 @@
-def _helper(value):
-    return value
-
 def render(value):
""", "no_removal"),
    "py_function_moved": ("""diff --git a/src/acme/api.py b/src/acme/api.py
--- a/src/acme/api.py
+++ b/src/acme/api.py
@@ -1,6 +1,3 @@
-def render(value):
-    return str(value)
-
diff --git a/src/acme/rendering.py b/src/acme/rendering.py
--- a/src/acme/rendering.py
+++ b/src/acme/rendering.py
@@ -1,3 +1,6 @@
+def render(value):
+    return str(value)
+
""", "no_removal"),
    "py_test_function_removed": ("""diff --git a/tests/test_widget.py b/tests/test_widget.py
--- a/tests/test_widget.py
+++ b/tests/test_widget.py
@@ -1,6 +1,3 @@
-def test_old_size():
-    assert True
-
 def test_draw():
""", "no_removal"),
    "py_local_variables_removed": ("""diff --git a/src/acme/widget.py b/src/acme/widget.py
--- a/src/acme/widget.py
+++ b/src/acme/widget.py
@@ -30,6 +30,5 @@ class Widget:
     def draw(self):
-        scale = 2
         return self.size
@@ -50,5 +49,4 @@ def render(value):
-    prefix = "x"
     return value
""", "no_removal"),
    "js_export_removed": ("""diff --git a/lib/index.js b/lib/index.js
--- a/lib/index.js
+++ b/lib/index.js
@@ -1,6 +1,3 @@
 'use strict'
-exports.legacyParse = function (text) {
-  return parse(text)
-}
 exports.parse = parse
""", "removed_without_warning"),
    "js_method_removed_with_deprecate": ("""diff --git a/lib/response.js b/lib/response.js
--- a/lib/response.js
+++ b/lib/response.js
@@ -40,8 +40,6 @@ res.send = function send(body) {
-res.jsonp = function jsonp(obj) {
-  return this.send(obj)
-}
+deprecate('res.jsonp: use res.json with a callback parameter')
""", "removed_with_warning"),
    "ts_function_replaced_with_warning": ("""diff --git a/src/client.ts b/src/client.ts
--- a/src/client.ts
+++ b/src/client.ts
@@ -1,8 +1,9 @@
-export function fetchAll(url: string) {
-  return request(url)
-}
+export function fetchEvery(url: string) {
+  console.warn('fetchAll() is deprecated, use fetchEvery()')
+  return request(url)
+}
""", "removed_with_warning"),
    "empty_patch": ("", "no_removal"),
}


class Protocol3Inputs(unittest.TestCase):
    """Review 2, M2: only a scored protocol 3 OUT of the frozen manifest gets a verdict."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.in_dir = os.path.join(self.tmp.name, "in")
        self.out_dir = os.path.join(self.tmp.name, "out")
        os.makedirs(self.in_dir)

    def assert_withheld(self, results, fragment):
        self.assertTrue(results["REHEARSAL"])
        self.assertEqual(results["verdict"]["verdict"], "none")
        self.assertTrue(results["verdict"]["withheld"])
        self.assertEqual(results["verdict"]["rehearsal_only"]["verdict"], "dramatic")
        self.assertTrue(any(fragment in reason for reason in results["rehearsal_reasons"]), results["rehearsal_reasons"])
        report = read_text(os.path.join(self.out_dir, "report.md"))
        self.assertTrue(report.startswith("# REHEARSAL: not a scored v3 result"), report[:80])
        self.assertIn("**No verdict.**", report)
        self.assertNotIn("**Verdict: dramatic**", report)

    def test_a_protocol_2_out_on_the_live_meter_gets_no_verdict(self):
        # The Gate 1 case: paid protocol 2 rows, no OUT/protocol.json, live meter.
        rows = grid()
        for item in rows:
            item.pop("protocol")
            item.pop("pilot")
        dataset_v3(self.in_dir, rows, record=None)
        done, results = run_v3(self.in_dir, self.out_dir)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assert_withheld(results, "no OUT/protocol.json")
        self.assert_withheld(results, "36 of 36 trial rows are not protocol 3 scored rows")
        self.assertIn("verdict: none (REHEARSAL", done.stdout)
        self.assertNotIn("dramatic", done.stdout)

    def test_a_pilot_out_gets_no_verdict(self):
        rows = grid()
        for item in rows:
            item["pilot"] = True
        dataset_v3(self.in_dir, rows, record="pilot")
        _done, results = run_v3(self.in_dir, self.out_dir)
        self.assert_withheld(results, "mode 'pilot', pilot True")
        self.assert_withheld(results, "trial rows are not protocol 3 scored rows")

    def test_another_manifest_gets_no_verdict(self):
        dataset_v3(self.in_dir, grid())
        _done, results = run_v3(self.in_dir, self.out_dir, checksum="0" * 64)
        self.assert_withheld(results, "is not the --manifest-checksum given")
        other = manifest_v3(selection={"status": "pool_before_pilot"})
        path = os.path.join(self.tmp.name, "other.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(other, handle)
        _done, results = run_v3(self.in_dir, self.out_dir, manifest=path, checksum=other["checksum"])
        self.assert_withheld(results, "OUT was made for another manifest")

    def test_a_scored_out_of_the_frozen_manifest_gets_its_verdict(self):
        dataset_v3(self.in_dir, grid())
        done, results = run_v3(self.in_dir, self.out_dir)
        self.assertFalse(results["REHEARSAL"])
        self.assertEqual(results["verdict"]["verdict"], "dramatic")
        self.assertFalse(results["verdict"]["withheld"])
        self.assertTrue(results["input"]["scored_v3_out"])
        self.assertIn("verdict: dramatic", done.stdout)

    def test_manifest_and_checksum_are_required(self):
        dataset_v3(self.in_dir, grid())
        done, _results = run_v3(self.in_dir, self.out_dir, manifest=None, checksum=None)
        self.assertEqual(done.returncode, 2)
        self.assertIn("--manifest-checksum", done.stderr)
        done, _results = run_v3(self.in_dir, self.out_dir, checksum="not-hex")
        self.assertEqual(done.returncode, 2)


def write_trial(in_dir, run_id, meter_rows=None, trace=None, transcript=None, files=None):
    directory = os.path.join(in_dir, "trials", run_id)
    os.makedirs(directory, exist_ok=True)
    if trace is not None:
        with open(os.path.join(directory, "trace.json"), "w", encoding="utf-8") as handle:
            json.dump(trace, handle)
    if transcript is not None:
        with open(os.path.join(directory, "transcript.jsonl"), "w", encoding="utf-8") as handle:
            for event in transcript:
                handle.write(json.dumps(event) + "\n")
    for name, text in (files or {}).items():
        with open(os.path.join(directory, name), "w", encoding="utf-8") as handle:
            handle.write(text)
    if meter_rows:
        path = os.path.join(in_dir, "meter", "requests.jsonl")
        with open(path, encoding="utf-8") as handle:
            kept = [line for line in handle if json.loads(line).get("run_id") != run_id]
        with open(path, "w", encoding="utf-8") as handle:
            handle.writelines(kept)
            for item in meter_rows:
                handle.write(json.dumps(dict(item, run_id=run_id, mode="live", endpoint="messages")) + "\n")


def meter_row(seq, inp, write, read, out, model="claude-sonnet-5-5"):
    return {"seq": seq, "input_tokens": inp, "cache_creation_input_tokens": write, "cache_read_input_tokens": read,
            "output_tokens": out, "model": model, "cost_nanousd": 1}


class Protocol3Secondaries(unittest.TestCase):
    """Review 2, M3, M4 and M5: attribution, context use, behaviour, grading time, subgroups, pool."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.in_dir = os.path.join(self.tmp.name, "in")
        self.out_dir = os.path.join(self.tmp.name, "out")
        os.makedirs(self.in_dir)

    def test_a_token_gain_equal_to_none_lean_is_worded_as_configuration(self):
        rows = grid() + [row3(task, "none-lean", 1, 500, True) for task in TASKS6]
        dataset_v3(self.in_dir, rows)
        done, results = run_v3(self.in_dir, self.out_dir)
        credit = results["attribution"]
        self.assertEqual(credit["olivium_vs_none_lean"]["tokens"]["estimate"], 1.0)
        self.assertFalse(credit["by_primary"]["tokens"]["credited_to_text_and_hooks"])
        self.assertEqual(results["verdict"]["verdict"], "dramatic")
        self.assertIn("configuration (settings) gain on tokens", results["verdict"]["headline_wording"])
        self.assertIn("wording: a configuration", done.stdout)
        self.assertIn("**Wording:** a configuration", read_text(os.path.join(self.out_dir, "report.md")))
        self.assertIsNone(credit["gate1_development_figures"])

    def test_a_token_gain_below_none_lean_is_credited(self):
        # olivium 500 against none-lean 800 on all six tasks: 0.625, sign-flip p = 2/64.
        rows = grid() + [row3(task, "none-lean", 1, 800, True) for task in TASKS6]
        dataset_v3(self.in_dir, rows)
        _done, results = run_v3(self.in_dir, self.out_dir)
        self.assertTrue(results["attribution"]["by_primary"]["tokens"]["credited_to_text_and_hooks"])
        self.assertIsNone(results["verdict"]["headline_wording"])

    def test_without_none_lean_nothing_is_credited_and_gate1_is_shown(self):
        dataset_v3(self.in_dir, grid())
        _done, results = run_v3(self.in_dir, self.out_dir)
        self.assertIn("configuration (settings) gain", results["verdict"]["headline_wording"])
        self.assertEqual(results["attribution"]["gate1_development_figures"]["olivium_over_none_lean_tokens_median"], 1.175)
        self.assertIn("No none-lean runs", read_text(os.path.join(self.out_dir, "report.md")))

    def test_context_use_from_meter_rows_and_the_trace(self):
        rows = grid()
        dataset_v3(self.in_dir, rows)
        transcript = [{"type": "assistant", "message": {"id": "m%d" % n}} for n in (1, 2, 3)]
        # T1 none r1: first request 2+100+0 = 102 (cold); the edit is in message 2, so the
        # requests up to it: (2+100+0+10) + (2+20+100+30) = 264; largest prompt 2+5+200 = 207.
        write_trial(self.in_dir, "T1.none.r1",
                    meter_rows=[meter_row(1, 2, 100, 0, 10), meter_row(2, 2, 20, 100, 30), meter_row(3, 2, 5, 200, 40),
                                meter_row(0, 9, 9, 9, 9, model="claude-haiku-5")],
                    trace={"first_gold_edit": {"path": "src/a.py", "tool": "Bash", "turns_before": 1}},
                    transcript=transcript)
        # T1 olivium r1: warm first request (cache read 50), never edited a fix file.
        write_trial(self.in_dir, "T1.olivium.r1", meter_rows=[meter_row(1, 2, 10, 50, 5), meter_row(2, 2, 10, 60, 5)],
                    trace={"first_gold_edit": None}, transcript=transcript[:2])
        # T2 none r1: an edit, but 3 transcript messages against 2 requests: not mapped.
        write_trial(self.in_dir, "T2.none.r1", meter_rows=[meter_row(1, 1, 1, 0, 1), meter_row(2, 1, 1, 1, 1)],
                    trace={"first_gold_edit": {"turns_before": 0}}, transcript=transcript)
        for item in rows:
            if item["run_id"] in ("T1.none.r1", "T1.olivium.r1", "T2.none.r1"):
                item["model"] = "claude-sonnet-5-5"
        with open(os.path.join(self.in_dir, "trials.jsonl"), "w", encoding="utf-8") as handle:
            for item in rows:
                handle.write(json.dumps(item) + "\n")
        _done, results = run_v3(self.in_dir, self.out_dir)
        none = results["context_use"]["by_setup"]["none"]
        olivium = results["context_use"]["by_setup"]["olivium"]
        self.assertEqual(none["first_request_tokens"]["max"], 102)
        self.assertEqual(none["largest_context"]["max"], 207)
        self.assertEqual(none["tokens_before_first_gold_edit"], {"runs": 1, "mean": 264.0, "median": 264.0, "max": 264.0})
        self.assertEqual(none["runs_with_edit_not_mapped"], 17)
        self.assertEqual((none["warm_starts"], olivium["warm_starts"]), (0, 1))
        self.assertEqual(olivium["runs_that_never_edited_a_fix_file"], 1)
        # T1: olivium first request 62 / none 102.
        ratio = results["context_use"]["olivium_over_none"]["first_request_tokens"]["per_task"]["T1"]
        self.assertAlmostEqual(ratio, 62 / 102.0)
        self.assertIn("## Context use", read_text(os.path.join(self.out_dir, "report.md")))

    def test_grading_time_behaviour_subgroups_and_pool(self):
        rows = grid()
        rows[0]["p2p_regressions"] = 2
        rows[0]["lint_ok"] = False
        dataset_v3(self.in_dir, rows, manifest=manifest_v3(languages={"T1": "typescript", "T2": "typescript"}))
        write_trial(self.in_dir, "T1.none.r1", files={
            "test_wall_seconds": "610\n", "test_exit": "137\n",
            "grade.json": json.dumps({"test_timeout_seconds": 600}),
            "agent.patch": "diff --git a/CHANGES.rst b/CHANGES.rst\ndiff --git a/tests/test_a.py b/tests/test_a.py\n",
            "details.json": json.dumps({"hook_events": {"hook_started": 2}}),
        }, transcript=[
            {"type": "assistant", "message": {"id": "m1", "content": [
                {"type": "tool_use", "id": "b1", "name": "Bash", "input": {"command": "pytest -q tests"}},
                {"type": "tool_use", "id": "b2", "name": "Bash", "input": {"command": "uv run pytest"}}]}},
            {"type": "user", "message": {"content": [
                {"type": "tool_result", "tool_use_id": "b1", "content": "bash: pytest: command not found"},
                {"type": "tool_result", "tool_use_id": "b2", "content": [{"type": "text", "text": "3 passed"}]}]}},
        ])
        write_trial(self.in_dir, "T1.olivium.r1", files={"test_wall_seconds": "40\n", "test_exit": "0\n"})
        _done, results = run_v3(self.in_dir, self.out_dir)
        secondary = results["secondary"]
        times = secondary["grading_times"]["by_setup"]
        self.assertEqual((times["none"]["killed_at_limit"], times["none"]["limit_seconds"]), (1, [600]))
        self.assertEqual((times["olivium"]["test_seconds"]["max"], times["olivium"]["limit_seconds"]), (40, [300]))
        behaviour = secondary["behaviour"]["by_setup"]["none"]
        self.assertEqual(behaviour["wrong_commands"]["command_not_found"], 1)
        self.assertEqual(behaviour["first_test_command_ok"], {"runs_with_a_test_command": 1, "ok": 0})
        self.assertEqual((behaviour["p2p_regressions"], behaviour["runs_with_a_regression"]), (2, 1))
        self.assertEqual(behaviour["runs_with_new_lint_findings"], 1)
        self.assertEqual(behaviour["hook_events"], {"hook_started": 2})
        self.assertEqual(behaviour["runs_that_changed_a_test_file"], 1)
        self.assertEqual(behaviour["changelog"], {"runs_where_the_real_fix_touched_one": 1, "runs_that_touched_one": 1})
        groups = secondary["subgroups"]
        self.assertEqual(groups["language"]["typescript"]["tasks"], ["T1", "T2"])
        self.assertEqual(groups["language"]["python"]["tokens"]["estimate"], 0.5)
        self.assertEqual(sorted(groups["toolchain_nondefault"]), [False, True] if False in groups["toolchain_nondefault"] else ["false", "true"])
        pool = secondary["pool"]
        self.assertEqual(pool["t4_share"]["share"], 0.6)
        self.assertEqual(pool["census_scored_tasks"], {"tasks": 6, "full_suite_green_at_base": 2, "not_recorded": 0})
        report = read_text(os.path.join(self.out_dir, "report.md"))
        for heading in ("### Subgroups", "### Behaviour per setup", "### Grading time of the test command", "T4 rejection share"):
            self.assertIn(heading, report)


class PatchClassifier(unittest.TestCase):
    def test_twelve_synthetic_patches(self):
        got = {name: analyze.classify_patch(text)["outcome"] for name, (text, _expected) in PATCHES.items()}
        expected = {name: outcome for name, (_text, outcome) in PATCHES.items()}
        self.assertEqual(len(PATCHES), 12)
        self.assertEqual(got, expected)

    def test_names_and_files_are_reported(self):
        result = analyze.classify_patch(PATCHES["py_method_removed_with_warning"][0])
        self.assertEqual(result["removed_names"], ["resize"])
        self.assertEqual(result["warning_files"], ["src/acme/widget.py"])


if __name__ == "__main__":
    unittest.main()
