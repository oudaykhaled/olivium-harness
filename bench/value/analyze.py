#!/usr/bin/env python3
"""Analysis of a value benchmark run. See PROTOCOL.md, section Analysis.

  python3 bench/value/analyze.py --in OUT --out DIR
  python3 bench/value/analyze.py --in OUT --out DIR --protocol 3 [--tolerance-points T]

OUT is a run.py output directory (trials.jsonl, meter/requests.jsonl, arms/...).
DIR receives results.json, report.md and chart_*.svg. Standard library only.
With --protocol 3, DIR receives the protocol 3 results.json and report.md (no
charts); protocols 1 and 2 are unchanged.

An input is treated as real only when its meter log proves every run went
through the live meter and no setup step used a rehearsal fixture. Anything
else is stamped REHEARSAL on every output.
"""

import argparse
import bisect
import hashlib
import html
import json
import math
import os
import random
import re
import statistics
import sys

ARMS = ("none", "generic", "olivium")
COMPARISONS = (("olivium", "none"), ("olivium", "generic"))
STATUSES = ("completed", "timeout", "turn_limit", "budget_exhausted", "infra_error")
SEED = 20261108
RESAMPLES = 10000
REQUIRED_FIELDS = (
    "run_id", "task_id", "arm", "repeat", "status", "solved", "f2p_passed", "f2p_total",
    "p2p_regressions", "lint_ok", "tokens", "cost_usd", "requests", "turns", "tool_calls",
    "files_read", "wasted_reads", "turns_before_first_gold_edit",
    "tool_calls_before_first_gold_edit", "patch_lines", "wall_seconds", "model",
    "claude_code_version", "harness_bytes",
)
TUNED_REPOSITORIES = ("pallets/click", "pallets/flask", "python-attrs/attrs", "expressjs/express")
TUNED_OVERLAP_STATEMENT = (
    "The analyzer and rule filters were tuned while looking at pallets/click, pallets/flask, "
    "python-attrs/attrs and expressjs/express, at the same base commits the pilot used, and the "
    "5 pilot tasks come from those repositories. Only the held-out table is free of that overlap."
)
BEFORE_AFTER_NOTE = (
    "Different runs: the pilot's old harness and this run's new harness were measured on different "
    "days with separate samples of the model. This table says what changed between the two runs; it "
    "does not show that the harness caused any difference. One more difference between them: in the pilot "
    "every arm was offered Claude Code's WebSearch and WebFetch (none of its 51 sessions used them); in "
    "this run no arm is."
)
REHEARSAL_TITLE = "REHEARSAL: mock model, not a result"
REHEARSAL_LINE = (
    "**REHEARSAL.** This came from a mock model with scripted costs. It checks that the "
    "benchmark machinery works and says nothing about whether any harness helps. Do not publish it."
)


class DataError(Exception):
    """The input cannot be analyzed as it stands."""


def _token(name):
    def read(row):
        return (row.get("tokens") or {}).get(name)
    return read


def _flag(name):
    def read(row):
        value = row.get(name)
        return None if value is None else (1.0 if value else 0.0)
    return read


def _field(name):
    def read(row):
        return row.get(name)
    return read


# (key, label, unit, better, question, reader)
METRICS = (
    ("cost_usd", "Cost per run", "usd", "lower", "fewer_tokens", _field("cost_usd")),
    ("input_tokens", "Input tokens", "tokens", "lower", "fewer_tokens", _token("input")),
    ("output_tokens", "Output tokens", "tokens", "lower", "fewer_tokens", _token("output")),
    ("cache_creation_tokens", "Cache-write tokens", "tokens", "lower", "fewer_tokens", _token("cache_creation")),
    ("cache_read_tokens", "Cache-read tokens", "tokens", "lower", "fewer_tokens", _token("cache_read")),
    ("wasted_reads", "Files read outside the real fix", "count", "lower", "better_context", _field("wasted_reads")),
    ("turns_before_first_gold_edit", "Turns before the first edit to a fixed file", "count", "lower", "better_context", _field("turns_before_first_gold_edit")),
    ("tool_calls_before_first_gold_edit", "Tool calls before that edit", "count", "lower", "better_context", _field("tool_calls_before_first_gold_edit")),
    ("solved", "Solved", "share", "higher", "more_accurate", _flag("solved")),
    ("p2p_regressions", "Regressions per run", "count", "lower", "more_accurate", _field("p2p_regressions")),
    ("lint_ok", "Linter passes", "share", "higher", "more_accurate", _flag("lint_ok")),
)
METRIC_BY_KEY = {metric[0]: metric for metric in METRICS}
QUESTIONS = (
    ("fewer_tokens", "Did the agent use fewer tokens and cost less?", "cost_usd", "cost less per run", "cost more per run"),
    ("better_context", "Did the agent have better context?", "wasted_reads", "read fewer files outside the real fix", "read more files outside the real fix"),
    ("more_accurate", "Was the agent more accurate?", "solved", "solved a larger share of runs", "solved a smaller share of runs"),
)


# ------------------------------------------------------------------ statistics
def median(values):
    return statistics.median(values)


def percentile(sorted_values, fraction):
    """Linear interpolation between order statistics (numpy's default method)."""
    count = len(sorted_values)
    if count == 1:
        return sorted_values[0]
    position = (count - 1) * fraction
    lower = math.floor(position)
    upper = min(lower + 1, count - 1)
    return sorted_values[lower] + (position - lower) * (sorted_values[upper] - sorted_values[lower])


def bootstrap_interval(values, resamples=RESAMPLES, seed=SEED):
    """Percentile bootstrap 95% interval of the median, resampling tasks with replacement.

    Every metric and comparison starts from the same seed, so one result does
    not change when another metric is added or removed.
    """
    rng = random.Random(seed)
    count = len(values)
    medians = []
    for _ in range(resamples):
        medians.append(median([values[rng.randrange(count)] for _ in range(count)]))
    medians.sort()
    return percentile(medians, 0.025), percentile(medians, 0.975)


# ----------------------------------------------------------------- input
def read_jsonl(path):
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except ValueError:
                continue  # a torn final line from an interrupted write
    return rows


def read_json(path, default=None):
    if not os.path.exists(path):
        return default
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def load_trials(in_dir):
    rows = read_jsonl(os.path.join(in_dir, "trials.jsonl"))
    if not rows:
        raise DataError("no trials found in %s" % os.path.join(in_dir, "trials.jsonl"))
    for row in rows:
        missing = [field for field in REQUIRED_FIELDS if field not in row]
        if missing:
            raise DataError("trial %s is missing fields: %s" % (row.get("run_id"), ", ".join(missing)))
        if row["status"] not in STATUSES:
            raise DataError("trial %s has unknown status %s" % (row["run_id"], row["status"]))
        if row["arm"] not in ARMS:
            raise DataError("trial %s has unknown arm %s" % (row["run_id"], row["arm"]))
    return rows


def group_runs(rows):
    """{task: {arm: {repeat: row}}}, without infra_error rows, which are never scored."""
    runs = {}
    for row in rows:
        if row["status"] == "infra_error":
            continue
        repeats = runs.setdefault(row["task_id"], {}).setdefault(row["arm"], {})
        if row["repeat"] in repeats:
            raise DataError(
                "more than one scored row for %s %s repeat %s" % (row["task_id"], row["arm"], row["repeat"])
            )
        repeats[row["repeat"]] = row
    return runs


def detect_origin(in_dir, rows):
    """Real data needs positive proof: otherwise every output is stamped REHEARSAL."""
    meter_rows = read_jsonl(os.path.join(in_dir, "meter", "requests.jsonl"))
    reasons = []
    if not meter_rows:
        reasons.append("no meter log: nothing shows these runs went through the live meter")
    modes = {row.get("mode") for row in meter_rows}
    if "mock" in modes:
        reasons.append("the meter log contains mock-mode requests")
    if modes - {"live", "mock"}:
        reasons.append("the meter log contains requests with no recognised mode")
    live_runs = {row.get("run_id") for row in meter_rows if row.get("mode") == "live"}
    unproven = sorted(row["run_id"] for row in rows if row.get("requests") and row["run_id"] not in live_runs)
    if unproven and meter_rows:
        reasons.append("%d trial(s) have no live meter record, first %s" % (len(unproven), unproven[0]))
    fixture_tasks = []
    arms_dir = os.path.join(in_dir, "arms")
    if os.path.isdir(arms_dir):
        for task in sorted(os.listdir(arms_dir)):
            for arm in ARMS:
                setup = read_json(os.path.join(arms_dir, task, "%s.setup.json" % arm), {}) or {}
                if setup.get("rehearsal_fixture"):
                    fixture_tasks.append("%s/%s" % (task, arm))
    if fixture_tasks:
        reasons.append("setup used rehearsal fixtures: %s" % ", ".join(fixture_tasks))
    return {"rehearsal": bool(reasons), "reasons": reasons, "meter_modes": sorted(mode for mode in modes if mode)}


def load_setup(in_dir, tasks):
    setup = {arm: {"cost_usd": 0.0, "cost_upper_bound_usd": 0.0, "failed": [], "tasks": {}} for arm in ARMS}
    for task in tasks:
        for arm in ARMS:
            record = read_json(os.path.join(in_dir, "arms", task, "%s.setup.json" % arm))
            if record is None:
                continue
            cost = float(record.get("cost_usd") or 0.0)
            upper = max(float(record.get("cost_upper_bound_usd") or 0.0), cost)
            setup[arm]["cost_usd"] += cost
            setup[arm]["cost_upper_bound_usd"] += upper
            setup[arm]["tasks"][task] = {"status": record.get("status"), "cost_usd": cost, "harness_bytes": record.get("harness_bytes")}
            if record.get("status") != "ok":
                setup[arm]["failed"].append(task)
    return setup


def load_as_exported(in_dir):
    base = os.path.join(in_dir, "as_exported")
    found = []
    if not os.path.isdir(base):
        return found
    for task in sorted(os.listdir(base)):
        record = read_json(os.path.join(base, task, "result.json"))
        if not record:
            continue
        row = record.get("row") or {}
        found.append({
            "task_id": task, "status": row.get("status"), "solved": row.get("solved"),
            "cost_usd": row.get("cost_usd"), "tool_calls": row.get("tool_calls"),
            "turns": row.get("turns"), "files_read": row.get("files_read"),
        })
    return found


# ------------------------------------------------------------------- analysis
def mean_or_none(values):
    present = [float(value) for value in values if value is not None]
    return sum(present) / len(present) if present else None


def clean(value):
    if isinstance(value, float):
        return round(value, 10)
    if isinstance(value, dict):
        return {key: clean(item) for key, item in value.items()}
    if isinstance(value, list):
        return [clean(item) for item in value]
    return value


def task_values(runs, tasks):
    values = {}
    for task in tasks:
        values[task] = {}
        for arm in ARMS:
            repeats = runs.get(task, {}).get(arm, {})
            rows = list(repeats.values())
            solved = sum(1 for row in rows if row["solved"])
            cost = sum(float(row["cost_usd"]) for row in rows)
            values[task][arm] = {
                "runs": len(rows),
                "solved": solved,
                "total_cost_usd": cost,
                "cost_per_solved_usd": cost / solved if solved else None,
                "means": {metric[0]: mean_or_none([metric[5](row) for row in rows]) for metric in METRICS},
                "values_used": {metric[0]: sum(1 for row in rows if metric[5](row) is not None) for metric in METRICS},
            }
    return values


def compare(values, tasks):
    results = {}
    for treated, baseline in COMPARISONS:
        key = "%s_minus_%s" % (treated, baseline)
        results[key] = {}
        for metric in METRICS:
            name = metric[0]
            per_task = {}
            for task in tasks:
                treated_mean = values[task][treated]["means"][name]
                baseline_mean = values[task][baseline]["means"][name]
                per_task[task] = None if treated_mean is None or baseline_mean is None else treated_mean - baseline_mean
            used = [per_task[task] for task in tasks if per_task[task] is not None]
            entry = {
                "per_task": per_task,
                "tasks_used": len(used),
                "tasks_excluded": [task for task in tasks if per_task[task] is None],
                "median": None,
                "ci95": None,
            }
            if used:
                low, high = bootstrap_interval(used)
                entry["median"] = median(used)
                entry["ci95"] = [low, high]
            results[key][name] = entry
    return results


def arm_totals(values, tasks, rows, setup):
    totals = {}
    for arm in ARMS:
        runs = sum(values[task][arm]["runs"] for task in tasks)
        solved = sum(values[task][arm]["solved"] for task in tasks)
        cost = sum(values[task][arm]["total_cost_usd"] for task in tasks)
        infra = [row for row in rows if row["arm"] == arm and row["status"] == "infra_error"]
        statuses = {status: sum(1 for row in rows if row["arm"] == arm and row["status"] == status) for status in STATUSES}
        totals[arm] = {
            "scored_runs": runs,
            "solved": solved,
            "solve_rate": solved / runs if runs else None,
            "total_cost_usd": cost,
            "cost_per_solved_usd": cost / solved if solved else None,
            "by_status": statuses,
            "infra_error_cost_usd": sum(float(row["cost_usd"]) for row in infra),
            "setup_cost_usd": setup[arm]["cost_usd"],
        }
    return totals


def direction_sentence(question, comparison, baseline):
    _key, _title, metric_name, lower_phrase, higher_phrase = question
    metric = METRIC_BY_KEY[metric_name]
    entry = comparison[metric_name]
    if entry["median"] is None:
        return "Against %s, %s could not be compared." % (baseline, metric[1].lower())
    low, high = entry["ci95"]
    text = "median difference %s (95%% interval %s to %s across %d tasks)" % (
        fmt_value(metric[2], entry["median"], signed=True),
        fmt_value(metric[2], low, signed=True),
        fmt_value(metric[2], high, signed=True),
        entry["tasks_used"],
    )
    if entry["tasks_used"] < 2:
        return "Against %s: only %d task has data, so no direction can be read (%s)." % (baseline, entry["tasks_used"], text)
    if high < 0:
        verdict = lower_phrase if metric[3] == "lower" else higher_phrase
        return "Against %s, on these %d tasks, the olivium arm %s (a direction, not proof): %s." % (baseline, entry["tasks_used"], verdict, text)
    if low > 0:
        verdict = higher_phrase if metric[3] == "lower" else lower_phrase
        return "Against %s, on these %d tasks, the olivium arm %s (a direction, not proof): %s." % (baseline, entry["tasks_used"], verdict, text)
    return "Against %s, no clear difference: %s; the interval includes zero." % (baseline, text)


def pilot_note(task_count, label="Pilot"):
    return (
        "%s: %d task%s, one model, one agent. This can show a direction or a problem. "
        "It cannot prove a general effect." % (label, task_count, "" if task_count == 1 else "s")
    )


def build_results(in_dir, manifest_path=None, pilot_results_path=None):
    rows = load_trials(in_dir)
    schedule = read_json(os.path.join(in_dir, "schedule.json"), {}) or {}
    tasks = schedule.get("tasks") or sorted({row["task_id"] for row in rows})
    runs = group_runs(rows)
    expected_repeats = schedule.get("repeats") or max((row["repeat"] for row in rows), default=0)
    origin = detect_origin(in_dir, rows)
    setup = load_setup(in_dir, tasks)
    values = task_values(runs, tasks)
    comparisons = compare(values, tasks)
    totals = arm_totals(values, tasks, rows, setup)
    by_status = {status: sum(1 for row in rows if row["status"] == status) for status in STATUSES}
    missing = []
    for task in tasks:
        for arm in ARMS:
            for repeat in range(1, expected_repeats + 1):
                if repeat not in runs.get(task, {}).get(arm, {}):
                    missing.append({"task_id": task, "arm": arm, "repeat": repeat})
    answers = {}
    for question in QUESTIONS:
        key = question[0]
        answers[key] = {
            "question": question[1],
            "sentences": [
                direction_sentence(question, comparisons["olivium_minus_%s" % baseline], baseline)
                for baseline in ("none", "generic")
            ],
        }
    results = {
        "REHEARSAL": origin["rehearsal"],
        "notice": REHEARSAL_TITLE if origin["rehearsal"] else None,
        "rehearsal_reasons": origin["reasons"],
        "pilot_note": pilot_note(len(tasks), "Measurement" if manifest_path else "Pilot"),
        "design": {
            "arms": list(ARMS),
            "comparisons": ["%s - %s" % pair for pair in COMPARISONS],
            "repeats_expected": expected_repeats,
            "interval": "percentile bootstrap 95% of the median, resampling tasks",
            "resamples": RESAMPLES,
            "seed": SEED,
            "percentile_method": "linear interpolation between order statistics",
        },
        "tasks": tasks,
        "input": {
            "dir": os.path.realpath(in_dir),
            "trial_rows": len(rows),
            "by_status": by_status,
            "budget_exhausted": by_status["budget_exhausted"],
            "missing_repeats": missing,
            "meter_modes": origin["meter_modes"],
        },
        "arms": totals,
        "per_task": values,
        "comparisons": comparisons,
        "answers": answers,
        "setup": setup,
        "as_exported": load_as_exported(in_dir),
    }
    if manifest_path:
        add_protocol_v2_sections(results, in_dir, rows, runs, tasks, expected_repeats, manifest_path, pilot_results_path, origin)
    return clean(results)


def subset_view(in_dir, rows, runs, tasks, expected_repeats, label, results):
    """The same analysis, restricted to a list of tasks."""
    subset_rows = [row for row in rows if row["task_id"] in tasks]
    setup = load_setup(in_dir, tasks)
    values = task_values(runs, tasks)
    comparisons = compare(values, tasks)
    answers = {}
    for question in QUESTIONS:
        answers[question[0]] = {
            "question": question[1],
            "sentences": [direction_sentence(question, comparisons["olivium_minus_%s" % baseline], baseline) for baseline in ("none", "generic")],
        }
    return {
        "REHEARSAL": results["REHEARSAL"],
        "rehearsal_reasons": results["rehearsal_reasons"],
        "pilot_note": pilot_note(len(tasks), label),
        "tasks": tasks,
        "arms": arm_totals(values, tasks, subset_rows, setup),
        "per_task": values,
        "comparisons": comparisons,
        "answers": answers,
        "setup": setup,
        "input": {"trial_rows": len(subset_rows), "by_status": {status: sum(1 for row in subset_rows if row["status"] == status) for status in STATUSES}},
    }


def add_protocol_v2_sections(results, in_dir, rows, runs, tasks, expected_repeats, manifest_path, pilot_results_path, origin):
    manifest = read_json(manifest_path)
    held_ids = [task["task_id"] for task in manifest["tasks"] if task.get("held_out")]
    pilot_ids = [task["task_id"] for task in manifest["tasks"] if not task.get("held_out")]
    held_out = [task for task in tasks if task in held_ids]
    results["protocol"] = "PROTOCOL-v2.md"
    results["manifest_checksum"] = manifest.get("checksum")
    results["tuned_repositories"] = list(TUNED_REPOSITORIES)
    results["tuned_overlap_statement"] = TUNED_OVERLAP_STATEMENT
    results["held_out_task_ids"] = held_out
    tuned_owners = {name.split("/", 1)[0] for name in TUNED_REPOSITORIES}
    held_repos = sorted({task["repo"] for task in manifest["tasks"] if task["task_id"] in held_out})
    same_family = [repo for repo in held_repos if repo.split("/", 1)[0] in tuned_owners]
    results["held_out_repositories"] = held_repos
    results["held_out_same_owner_as_tuned"] = same_family
    if same_family:
        results["tuned_overlap_statement"] += (
            " The held-out tasks come from %s, which shares an owner with a tuned repository and likely its "
            "layout and tooling conventions, so the held-out table is free of the base-commit overlap but not of "
            "that family resemblance." % ", ".join(same_family)
        )
    results["held_out"] = subset_view(in_dir, rows, runs, held_out, expected_repeats, "Held-out measurement", results) if held_out else None
    # Harness facts per task and per-run permission/hook facts the summary tables report.
    harness = {}
    for task in tasks:
        record = read_json(os.path.join(in_dir, "arms", task, "olivium.setup.json"), {}) or {}
        counts = record.get("counts") or {}
        harness[task] = {
            "rules": counts.get("rules"),
            "hooks": counts.get("hooks"),
            "allowed_commands": counts.get("allowed_commands"),
            "denied_commands": counts.get("denied_commands"),
            "diagnostics": sorted({item.get("code") for item in (record.get("diagnostics") or []) if isinstance(item, dict)}),
            "skipped_commands": len(record.get("skipped_commands") or []),
            "harness_bytes": record.get("harness_bytes"),
            "held_out": task in held_ids,
        }
    results["olivium_harness"] = harness
    denials = {}
    for arm in ARMS:
        arm_rows = [row for row in rows if row["arm"] == arm]
        denials[arm] = {
            "runs": len(arm_rows),
            "permission_denials": sum(int(row.get("permission_denials") or 0) for row in arm_rows),
            "runs_with_a_denial": sum(1 for row in arm_rows if row.get("permission_denials")),
            "stop_hook_blocks": sum(int(row.get("hook_blocks") or 0) for row in arm_rows),
            "runs_with_a_stop_block": sum(1 for row in arm_rows if row.get("hook_blocks")),
        }
    results["permission_and_hooks"] = denials
    # PROTOCOL-v2.md, change log: the web tools are removed from every arm and from /init.
    # Proven per run from Claude Code's own init event (trace.json), not assumed.
    attempts = read_jsonl(os.path.join(in_dir, "attempts.jsonl"))
    web = {"arms": {}}
    for arm in ARMS:
        checked = offered = 0
        for row in rows:
            if row["arm"] != arm:
                continue
            trace = read_json(os.path.join(in_dir, "trials", row["run_id"], "trace.json"), {}) or {}
            if "init_tools" in trace and trace["init_tools"]:
                checked += 1
                offered += 1 if trace.get("init_web_tools") else 0
        web["arms"][arm] = {
            "runs": sum(1 for row in rows if row["arm"] == arm),
            "runs_with_init_tools_recorded": checked,
            "runs_offered_a_web_tool": offered,
            "web_tool_calls": sum(int(row.get("web_tool_uses") or 0) for row in rows if row["arm"] == arm),
            "attempts_stopped_by_web_guard": sum(
                1 for item in attempts
                if item.get("arm") == arm and str(item.get("error") or "").startswith("web tools reached")),
        }
    setups = [read_json(os.path.join(in_dir, "arms", task, "generic.setup.json"), {}) or {} for task in tasks]
    web["init_setups_recorded"] = sum(1 for item in setups if "init_web_tools" in item)
    web["init_setups_offered_web"] = sum(1 for item in setups if item.get("init_web_tools"))
    results["web_tools"] = web
    results["before_after"] = before_after(results, pilot_results_path, pilot_ids) if pilot_results_path else None


def before_after(results, pilot_results_path, pilot_ids):
    pilot = read_json(pilot_results_path)
    if not pilot:
        return {"available": False, "note": "pilot results.json not found"}
    rows = []
    metrics = ("solved", "cost_usd", "wasted_reads", "turns_before_first_gold_edit", "tool_calls_before_first_gold_edit", "lint_ok")
    for task in pilot_ids:
        before = pilot["per_task"].get(task)
        after = results["per_task"].get(task)
        if not before or not after:
            continue
        entry = {"task_id": task, "old_harness_pilot": {}, "new_harness_this_run": {}, "none_pilot": {}, "none_this_run": {}}
        for metric in metrics:
            entry["old_harness_pilot"][metric] = before["olivium"]["means"].get(metric)
            entry["new_harness_this_run"][metric] = after["olivium"]["means"].get(metric)
            entry["none_pilot"][metric] = before["none"]["means"].get(metric)
            entry["none_this_run"][metric] = after["none"]["means"].get(metric)
        rows.append(entry)
    def total(arm_source, arm):
        solved = sum(arm_source["per_task"][t["task_id"]][arm]["solved"] for t in rows)
        runs = sum(arm_source["per_task"][t["task_id"]][arm]["runs"] for t in rows)
        cost = sum(arm_source["per_task"][t["task_id"]][arm]["total_cost_usd"] for t in rows)
        return {"solved": solved, "runs": runs, "total_cost_usd": cost, "cost_per_solved_usd": cost / solved if solved else None}
    summary = {}
    for arm in ("none", "generic", "olivium"):
        summary[arm] = {"pilot": total(pilot, arm), "this_run": total(results, arm)}
    return {
        "available": True,
        "note": BEFORE_AFTER_NOTE,
        "pilot_results": os.path.realpath(pilot_results_path),
        "pilot_harness": "old harness: Markdown-derived rules, exported settings not used in scored runs (see the pilot report)",
        "per_task": rows,
        "aggregate_5_pilot_tasks": summary,
    }


# ------------------------------------------------------------------ formatting
def fmt_value(unit, value, signed=False):
    if value is None:
        return "n/a"
    sign = "+" if signed and value > 0 else ""
    if unit == "usd":
        magnitude = abs(value)
        digits = 4 if magnitude < 1 else 2
        if 0 < magnitude < 0.0001:
            digits = 6
        return "%s%s$%.*f" % ("-" if value < 0 else sign, "", digits, magnitude)
    if unit == "tokens":
        return "%s%s" % (sign, format(round(value), ","))
    if unit == "count":
        text = "%.2f" % value
        return sign + (text[:-3] if text.endswith(".00") else text)
    if unit == "share":
        return "%s%.2f" % (sign, value)
    return "%s%s" % (sign, value)


def interval_text(unit, entry):
    if entry["median"] is None:
        return "n/a"
    return "%s [%s, %s]" % (
        fmt_value(unit, entry["median"], signed=True),
        fmt_value(unit, entry["ci95"][0], signed=True),
        fmt_value(unit, entry["ci95"][1], signed=True),
    )


def banner_lines(results):
    if not results["REHEARSAL"]:
        return []
    lines = [REHEARSAL_LINE, ""]
    for reason in results["rehearsal_reasons"]:
        lines.append("- Why this is marked: %s." % reason)
    lines.append("")
    return lines


def notes_near_numbers(results):
    lines = []
    if results["REHEARSAL"]:
        lines.append("> **REHEARSAL: mock model, not a result.**")
    lines.append("> %s" % results["pilot_note"])
    lines.append("")
    return lines


def render_report(results, charts):
    lines = []
    tasks = results["tasks"]
    if results["REHEARSAL"]:
        lines.append("# %s" % REHEARSAL_TITLE)
        lines.append("")
    lines.append("# Value benchmark results")
    lines.append("")
    lines.extend(banner_lines(results))
    lines.extend(notes_near_numbers(results))
    lines.append("Each run is one attempt by Claude Code to fix one real bug. `none` has no instruction file, "
                 "`generic` has a CLAUDE.md from Claude Code's own `/init`, and `olivium` has the files this "
                 "project generates. Differences are olivium minus the other arm, so a negative cost difference "
                 "means olivium was cheaper.")
    lines.append("")
    lines.append("## The three questions")
    lines.append("")
    lines.extend(notes_near_numbers(results))
    for question in QUESTIONS:
        key = question[0]
        lines.append("**%s**" % results["answers"][key]["question"])
        lines.append("")
        if key == "fewer_tokens":
            for arm in ARMS:
                arm_data = results["arms"][arm]
                lines.append("- `%s` cost per solved task: %s (%d of %d runs solved, total %s)." % (
                    arm, fmt_value("usd", arm_data["cost_per_solved_usd"]),
                    arm_data["solved"], arm_data["scored_runs"], fmt_value("usd", arm_data["total_cost_usd"]),
                ))
        for sentence in results["answers"][key]["sentences"]:
            lines.append("- %s" % sentence)
        lines.append("")
    lines.append("## How the runs ended")
    lines.append("")
    lines.extend(notes_near_numbers(results))
    lines.append("%d runs were cut off by a spending limit (`budget_exhausted`). Those runs count as unsolved and their cost counts."
                 % results["input"]["budget_exhausted"])
    lines.append("")
    lines.append("| Arm | Completed | Timeout | Turn limit | Budget exhausted | Infrastructure errors (not scored) | Solved | Cost per solved task |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for arm in ARMS:
        data = results["arms"][arm]
        counts = data["by_status"]
        lines.append("| %s | %d | %d | %d | %d | %d | %d of %d | %s |" % (
            arm, counts["completed"], counts["timeout"], counts["turn_limit"], counts["budget_exhausted"],
            counts["infra_error"], data["solved"], data["scored_runs"], fmt_value("usd", data["cost_per_solved_usd"]),
        ))
    lines.append("")
    if results["input"]["missing_repeats"]:
        lines.append("Missing runs (no scored result): %d. %s" % (
            len(results["input"]["missing_repeats"]),
            ", ".join("%s/%s/r%s" % (item["task_id"], item["arm"], item["repeat"]) for item in results["input"]["missing_repeats"][:12]),
        ))
        lines.append("")
    for chart in charts:
        lines.append("![%s](%s)" % (chart["alt"], chart["file"]))
        lines.append("")
    if results.get("tuned_overlap_statement"):
        lines.append("## Read this first: overlap with the tuning repositories")
        lines.append("")
        lines.append(results["tuned_overlap_statement"])
        lines.append("")
        held = results.get("held_out")
        if held:
            lines.append("Held-out tasks in this run: %d (%s). See the separate held-out sections below." % (
                len(held["tasks"]), ", ".join(held["tasks"])))
        else:
            lines.append("No held-out task produced data in this run.")
        lines.append("")
    if results.get("permission_and_hooks"):
        lines.append("## Permissions and hooks")
        lines.append("")
        lines.extend(notes_near_numbers(results))
        lines.append("The `olivium` arm runs as exported, with default permissions and its own allow list, so a denied tool counts against it. "
                     "`none` and `generic` use the benchmark's bypass settings, so these columns are zero for them.")
        lines.append("")
        lines.append("| Arm | Runs | Permission denials | Runs with a denial | Stop hook blocks | Runs with a Stop block |")
        lines.append("| --- | ---: | ---: | ---: | ---: | ---: |")
        for arm in ARMS:
            item = results["permission_and_hooks"][arm]
            lines.append("| %s | %d | %d | %d | %d | %d |" % (arm, item["runs"], item["permission_denials"], item["runs_with_a_denial"], item["stop_hook_blocks"], item["runs_with_a_stop_block"]))
        lines.append("")
        web = results.get("web_tools")
        if web:
            arms_web = web["arms"]
            lines.append("**Web tools.** Under this protocol every arm, and `/init`, runs with Claude Code's `WebSearch` and `WebFetch` removed "
                         "(`--disallowedTools`), and the meter refuses any request offering a web server tool. From each run's "
                         "own init event: runs offered a web tool, %s (of runs with the tool list recorded: %s). Web tool calls "
                         "attempted: %s. Attempts stopped by the web guard and repeated as infrastructure errors: %s. "
                         "`/init` sessions offered a web tool: %d of %d recorded." % (
                             ", ".join("%s %d" % (arm, arms_web[arm]["runs_offered_a_web_tool"]) for arm in ARMS),
                             ", ".join("%s %d" % (arm, arms_web[arm]["runs_with_init_tools_recorded"]) for arm in ARMS),
                             ", ".join("%s %d" % (arm, arms_web[arm]["web_tool_calls"]) for arm in ARMS),
                             ", ".join("%s %d" % (arm, arms_web[arm]["attempts_stopped_by_web_guard"]) for arm in ARMS),
                             web["init_setups_offered_web"], web["init_setups_recorded"]))
            lines.append("")
    if results.get("olivium_harness"):
        lines.append("## What the generator produced, by task")
        lines.append("")
        lines.append("Setup cost of the `olivium` arm is $0: no model call is made.")
        lines.append("")
        lines.append("| Task | Held out | Rules | Hooks | Allowed commands | Denied commands | Harness bytes | Diagnostics |")
        lines.append("| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |")
        for task in tasks:
            item = results["olivium_harness"][task]
            lines.append("| %s | %s | %s | %s | %s | %s | %s | %s |" % (
                task, "yes" if item["held_out"] else "no", item["rules"], item["hooks"], item["allowed_commands"],
                item["denied_commands"], item["harness_bytes"], ", ".join(item["diagnostics"]) or "none"))
        lines.append("")
    lines.append("## Differences, by question")
    lines.append("")
    lines.append("Median across tasks of the per-task difference, then the 95% bootstrap interval in brackets.")
    lines.append("")
    for question in QUESTIONS:
        key = question[0]
        lines.append("### %s" % results["answers"][key]["question"])
        lines.append("")
        lines.extend(notes_near_numbers(results))
        lines.append("| Metric | Better when | olivium - none | Tasks | olivium - generic | Tasks |")
        lines.append("| --- | --- | ---: | ---: | ---: | ---: |")
        for metric in METRICS:
            if metric[4] != key:
                continue
            none_entry = results["comparisons"]["olivium_minus_none"][metric[0]]
            generic_entry = results["comparisons"]["olivium_minus_generic"][metric[0]]
            lines.append("| %s | %s | %s | %d | %s | %d |" % (
                metric[1], metric[3], interval_text(metric[2], none_entry), none_entry["tasks_used"],
                interval_text(metric[2], generic_entry), generic_entry["tasks_used"],
            ))
        lines.append("")
    lines.append("## Per-task values")
    lines.append("")
    lines.append("Average of the repeats for each task and arm, then the difference. "
                 "`n/a` means no run of that task and arm produced the value, for example no edit reached a fixed file.")
    lines.append("")
    for metric in METRICS:
        name, label, unit = metric[0], metric[1], metric[2]
        lines.append("### %s" % label)
        lines.append("")
        lines.extend(notes_near_numbers(results))
        lines.append("| Task | none | generic | olivium | olivium - none | olivium - generic |")
        lines.append("| --- | ---: | ---: | ---: | ---: | ---: |")
        for task in tasks:
            cells = [fmt_value(unit, results["per_task"][task][arm]["means"][name]) for arm in ARMS]
            none_diff = results["comparisons"]["olivium_minus_none"][name]["per_task"][task]
            generic_diff = results["comparisons"]["olivium_minus_generic"][name]["per_task"][task]
            lines.append("| %s | %s | %s | %s | %s | %s |" % (
                task, cells[0], cells[1], cells[2],
                fmt_value(unit, none_diff, signed=True), fmt_value(unit, generic_diff, signed=True),
            ))
        lines.append("")
    lines.append("## Cost per solved task, by task")
    lines.append("")
    lines.extend(notes_near_numbers(results))
    lines.append("Total cost of the arm's runs on that task divided by how many of them solved it. `n/a` means none did.")
    lines.append("")
    lines.append("| Task | none | generic | olivium |")
    lines.append("| --- | ---: | ---: | ---: |")
    for task in tasks:
        cells = [fmt_value("usd", results["per_task"][task][arm]["cost_per_solved_usd"]) for arm in ARMS]
        lines.append("| %s | %s | %s | %s |" % (task, cells[0], cells[1], cells[2]))
    lines.append("")
    lines.append("## Setup cost (reported separately)")
    lines.append("")
    lines.extend(notes_near_numbers(results))
    lines.append("Includes what failed attempts spent. The upper bound also counts requests whose usage is unknown at their full reservation.")
    lines.append("")
    lines.append("| Arm | Setup cost | Upper bound | Tasks with failed setup |")
    lines.append("| --- | ---: | ---: | --- |")
    for arm in ARMS:
        lines.append("| %s | %s | %s | %s |" % (
            arm, fmt_value("usd", results["setup"][arm]["cost_usd"]),
            fmt_value("usd", results["setup"][arm]["cost_upper_bound_usd"]),
            ", ".join(results["setup"][arm]["failed"]) or "none",
        ))
    lines.append("")
    if results["as_exported"]:
        lines.append("## One run with the exported settings (not part of the analysis)")
        lines.append("")
        lines.extend(notes_near_numbers(results))
        for item in results["as_exported"]:
            lines.append("- `%s`: status `%s`, solved %s, cost %s, tool calls %s." % (
                item["task_id"], item["status"], item["solved"], fmt_value("usd", item["cost_usd"]), json.dumps(item["tool_calls"], sort_keys=True),
            ))
        lines.append("")
    held = results.get("held_out")
    if held:
        lines.append("## Held-out tasks only")
        lines.append("")
        lines.append("Same analysis restricted to the held-out tasks, which come from repositories the analyzer was not tuned on. "
                     "%s" % results["tuned_overlap_statement"])
        lines.append("")
        lines.extend(notes_near_numbers(held))
        lines.append("| Arm | Solved | Runs | Cost per solved task | Total cost |")
        lines.append("| --- | ---: | ---: | ---: | ---: |")
        for arm in ARMS:
            data = held["arms"][arm]
            lines.append("| %s | %d | %d | %s | %s |" % (arm, data["solved"], data["scored_runs"], fmt_value("usd", data["cost_per_solved_usd"]), fmt_value("usd", data["total_cost_usd"])))
        lines.append("")
        for question in QUESTIONS:
            key = question[0]
            lines.append("**%s (held-out only)**" % held["answers"][key]["question"])
            lines.append("")
            for sentence in held["answers"][key]["sentences"]:
                lines.append("- %s" % sentence)
            lines.append("")
        lines.append("| Metric | Better when | olivium - none | Tasks | olivium - generic | Tasks |")
        lines.append("| --- | --- | ---: | ---: | ---: | ---: |")
        for metric in METRICS:
            none_entry = held["comparisons"]["olivium_minus_none"][metric[0]]
            generic_entry = held["comparisons"]["olivium_minus_generic"][metric[0]]
            lines.append("| %s | %s | %s | %d | %s | %d |" % (metric[1], metric[3], interval_text(metric[2], none_entry), none_entry["tasks_used"], interval_text(metric[2], generic_entry), generic_entry["tasks_used"]))
        lines.append("")
        lines.append("| Task | Cost: none | generic | olivium | Solved: none | generic | olivium |")
        lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
        for task in held["tasks"]:
            per = held["per_task"][task]
            lines.append("| %s | %s | %s | %s | %s | %s | %s |" % (
                task, *[fmt_value("usd", per[arm]["means"]["cost_usd"]) for arm in ARMS],
                *[fmt_value("share", per[arm]["means"]["solved"]) for arm in ARMS]))
        lines.append("")
    before_after_block = results.get("before_after")
    if before_after_block:
        lines.append("## Before and after: the pilot's old harness and this run's new harness")
        lines.append("")
        if before_after_block.get("available"):
            lines.append(before_after_block["note"])
            lines.append("")
            lines.append("Aggregate over the 5 pilot tasks (solved of runs; cost per solved task):")
            lines.append("")
            lines.append("| Arm | Pilot | This run |")
            lines.append("| --- | --- | --- |")
            for arm in ARMS:
                item = before_after_block["aggregate_5_pilot_tasks"][arm]
                lines.append("| %s | %d of %d, %s | %d of %d, %s |" % (
                    arm, item["pilot"]["solved"], item["pilot"]["runs"], fmt_value("usd", item["pilot"]["cost_per_solved_usd"]),
                    item["this_run"]["solved"], item["this_run"]["runs"], fmt_value("usd", item["this_run"]["cost_per_solved_usd"])))
            lines.append("")
            lines.append("| Task | Solved share: old harness (pilot) | new harness (this run) | none (pilot) | none (this run) | Cost per run: old harness | new harness |")
            lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
            for entry in before_after_block["per_task"]:
                lines.append("| %s | %s | %s | %s | %s | %s | %s |" % (
                    entry["task_id"],
                    fmt_value("share", entry["old_harness_pilot"]["solved"]), fmt_value("share", entry["new_harness_this_run"]["solved"]),
                    fmt_value("share", entry["none_pilot"]["solved"]), fmt_value("share", entry["none_this_run"]["solved"]),
                    fmt_value("usd", entry["old_harness_pilot"]["cost_usd"]), fmt_value("usd", entry["new_harness_this_run"]["cost_usd"])))
            lines.append("")
        else:
            lines.append(before_after_block.get("note", "Pilot results are not available."))
            lines.append("")
    lines.append("## Method")
    lines.append("")
    lines.append("For each task, the repeats of each arm are averaged, leaving out runs recorded as `infra_error`. "
                 "The difference is olivium minus the other arm for that task. The headline is the median of those "
                 "differences across tasks. The interval is a percentile bootstrap: tasks are resampled with "
                 "replacement %d times with seed %d, the median is taken each time, and the 2.5th and 97.5th "
                 "percentiles are reported. Cost per solved task is the total cost of the arm's runs divided by the "
                 "number of runs that solved the task; it has no interval because the protocol defines none." % (RESAMPLES, SEED))
    lines.append("")
    lines.append(results["pilot_note"])
    lines.append("")
    if results["REHEARSAL"]:
        lines.append(REHEARSAL_LINE)
        lines.append("")
    return "\n".join(lines)


# ----------------------------------------------------------------------- charts
CHART_CSS = """
.v{--bg:#fcfcfb;--ink:#0b0b0b;--ink2:#52514e;--muted:#6a6963;--grid:#e1e0d9;--axis:#c3c2b7;--s1:#2a78d6;--s2:#eb6834;--s3:#1baf7a;--crit:#d03b3b;font-family:system-ui,-apple-system,"Segoe UI",Helvetica,Arial,sans-serif}
@media (prefers-color-scheme:dark){.v{--bg:#1a1a19;--ink:#f0efec;--ink2:#c3c2b7;--muted:#a8a69c;--grid:#2c2c2a;--axis:#383835;--s1:#3987e5;--s2:#d95926;--s3:#199e70;--crit:#d03b3b}}
.bg{fill:var(--bg)}.t{fill:var(--ink);font-size:16px;font-weight:600}.p{fill:var(--ink2);font-size:12px}.l{fill:var(--ink2);font-size:12px}.m{fill:var(--muted);font-size:11px}.h{fill:var(--ink);font-size:13px;font-weight:600}
.banner{fill:var(--crit)}.bt{fill:#fff;font-size:13px;font-weight:700}
.grid{stroke:var(--grid);stroke-width:1}.axis{stroke:var(--axis);stroke-width:1}.zero{stroke:var(--muted);stroke-width:1;stroke-dasharray:3 3}
.s1{fill:var(--s1)}.s2{fill:var(--s2)}.s3{fill:var(--s3)}.ls1{stroke:var(--s1);stroke-width:2}.ls2{stroke:var(--s2);stroke-width:2}.ls3{stroke:var(--s3);stroke-width:2}
.ring{stroke:var(--bg);stroke-width:2}
"""
ARM_SERIES = {"none": "1", "generic": "2", "olivium": "3"}


def esc(text):
    return html.escape(str(text), quote=True)


def nice_ticks(low, high, count=5):
    if low == high:
        low -= 1
        high += 1
    raw = (high - low) / float(count)
    magnitude = 10 ** math.floor(math.log10(raw))
    step = magnitude
    for multiplier in (1, 2, 2.5, 5, 10):
        step = multiplier * magnitude
        if step >= raw:
            break
    start = math.floor(low / step) * step
    stop = math.ceil(high / step) * step
    ticks = []
    value = start
    while value <= stop + step / 2:
        ticks.append(round(value, 12))
        value += step
    return ticks


def fmt_tick(unit, value, ticks):
    """Axis label with just enough digits to tell neighbouring ticks apart."""
    step = abs(ticks[1] - ticks[0]) if len(ticks) > 1 else 1.0
    digits = max(0, -int(math.floor(math.log10(step)))) if step > 0 else 0
    if unit == "usd":
        return "%s$%.*f" % ("-" if value < 0 else "+" if value > 0 else "", digits, abs(value))
    return "%s%.*f" % ("+" if value > 0 else "", digits, value)


def svg_document(results, width, title, subtitle, body):
    # body(y0) returns (svg text, y of its last element)
    y = 30 if results["REHEARSAL"] else 0
    content, end_y = body(y + 76)
    height = int(end_y) + 14
    parts = [
        '<svg xmlns="http://www.w3.org/2000/svg" class="v" width="%d" height="%d" viewBox="0 0 %d %d" role="img">' % (width, height, width, height),
        "<title>%s</title>" % esc((REHEARSAL_TITLE + ". " if results["REHEARSAL"] else "") + title),
        "<style>%s</style>" % CHART_CSS,
        '<rect class="bg" width="%d" height="%d"/>' % (width, height),
    ]
    if results["REHEARSAL"]:
        parts.append('<rect class="banner" width="%d" height="30"/>' % width)
        parts.append('<text class="bt" x="16" y="20">! %s</text>' % esc(REHEARSAL_TITLE.upper()))
    parts.append('<text class="t" x="16" y="%d">%s</text>' % (y + 26, esc(title)))
    parts.append('<text class="p" x="16" y="%d">%s</text>' % (y + 44, esc(subtitle)))
    parts.append('<text class="p" x="16" y="%d">%s</text>' % (y + 60, esc(results["pilot_note"])))
    parts.append(content)
    parts.append("</svg>")
    return "\n".join(parts)


def scale(low, high, left, right):
    if high == low:
        high = low + 1
    def to_x(value):
        return left + (float(value) - low) / (high - low) * (right - left)
    return to_x


def legend(items, x, y):
    parts = []
    for label, series in items:
        parts.append('<circle class="s%s" cx="%d" cy="%d" r="5"/>' % (series, x + 5, y - 4))
        parts.append('<text class="l" x="%d" y="%d">%s</text>' % (x + 16, y, esc(label)))
        x += 16 + 7 * len(label) + 18
    return "".join(parts)


def chart_cost_by_task(results):
    tasks = results["tasks"]
    width = 760
    left = 190
    right = width - 40
    row_height = 46
    series = []
    for task in tasks:
        for arm in ARMS:
            value = results["per_task"][task][arm]["means"]["cost_usd"]
            if value is not None:
                series.append(value)
    top_value = max(series) if series else 1.0
    ticks = nice_ticks(0.0, top_value if top_value > 0 else 1.0)
    to_x = scale(ticks[0], ticks[-1], left, right)
    def body(y0):
        parts = [legend([(arm, ARM_SERIES[arm]) for arm in ARMS], 16, y0 + 8)]
        top = y0 + 24
        for tick in ticks:
            x = to_x(tick)
            parts.append('<line class="grid" x1="%.1f" x2="%.1f" y1="%d" y2="%d"/>' % (x, x, top, top + row_height * len(tasks)))
            parts.append('<text class="m" x="%.1f" y="%d" text-anchor="middle">%s</text>' % (x, top + row_height * len(tasks) + 16, esc(fmt_tick("usd", tick, ticks))))
        for index, task in enumerate(tasks):
            y = top + index * row_height + row_height / 2.0
            parts.append('<text class="l" x="%d" y="%.1f" text-anchor="end">%s</text>' % (left - 12, y + 4, esc(task)))
            for offset, arm in zip((-10, 0, 10), ARMS):
                value = results["per_task"][task][arm]["means"]["cost_usd"]
                if value is None:
                    continue
                parts.append('<circle class="s%s ring" cx="%.1f" cy="%.1f" r="5"><title>%s</title></circle>' % (
                    ARM_SERIES[arm], to_x(value), y + offset, esc("%s, %s: %s per run" % (task, arm, fmt_value("usd", value)))))
        return "".join(parts), top + row_height * len(tasks) + 22
    return svg_document(results, width, "Average cost per run, by task and arm", "Each dot is one task and arm, averaged over its repeats.", body)


def chart_cost_per_solved(results):
    width = 760
    left = 120
    right = width - 160
    row_height = 40
    values = [results["arms"][arm]["cost_per_solved_usd"] for arm in ARMS]
    present = [value for value in values if value is not None]
    ticks = nice_ticks(0.0, max(present) if present and max(present) > 0 else 1.0)
    to_x = scale(ticks[0], ticks[-1], left, right)
    def body(y0):
        parts = []
        top = y0 + 8
        for tick in ticks:
            x = to_x(tick)
            parts.append('<line class="grid" x1="%.1f" x2="%.1f" y1="%d" y2="%d"/>' % (x, x, top, top + row_height * 3))
            parts.append('<text class="m" x="%.1f" y="%d" text-anchor="middle">%s</text>' % (x, top + row_height * 3 + 16, esc(fmt_tick("usd", tick, ticks))))
        for index, arm in enumerate(ARMS):
            data = results["arms"][arm]
            y = top + index * row_height
            parts.append('<text class="l" x="%d" y="%d" text-anchor="end">%s</text>' % (left - 12, y + row_height / 2 + 4, esc(arm)))
            value = data["cost_per_solved_usd"]
            label = "%d of %d solved" % (data["solved"], data["scored_runs"])
            if value is None:
                parts.append('<text class="l" x="%d" y="%d">no run solved (%s)</text>' % (left + 4, y + row_height / 2 + 4, esc(label)))
                continue
            bar = max(to_x(value) - left, 1.0)
            title = "%s: %s per solved task, %s" % (arm, fmt_value("usd", value), label)
            parts.append('<rect class="s%s" x="%d" y="%d" width="%.1f" height="16" rx="4"><title>%s</title></rect>' % (ARM_SERIES[arm], left, y + row_height / 2 - 8, bar, esc(title)))
            parts.append('<text class="l" x="%.1f" y="%d">%s (%s)</text>' % (left + bar + 8, y + row_height / 2 + 4, esc(fmt_value("usd", value)), esc(label)))
        return "".join(parts), top + row_height * 3 + 22
    return svg_document(results, width, "Cost per solved task, by arm", "Total cost of the arm's runs divided by the runs that solved the task.", body)


def chart_differences(results, question):
    key, title = question[0], question[1]
    metrics = [metric for metric in METRICS if metric[4] == key]
    width = 760
    left = 150
    right = width - 230
    rows = (("none", "olivium_minus_none", "1"), ("generic", "olivium_minus_generic", "2"))
    def body(y0):
        parts = [legend([("olivium - none", "1"), ("olivium - generic", "2")], 16, y0 + 8)]
        y = y0 + 22
        for metric in metrics:
            name, label, unit = metric[0], metric[1], metric[2]
            parts.append('<text class="h" x="16" y="%d">%s</text>' % (y + 12, esc("%s (%s is better)" % (label, metric[3]))))
            values = [0.0]
            for _baseline, comp, _series in rows:
                entry = results["comparisons"][comp][name]
                values.extend(item for item in entry["per_task"].values() if item is not None)
                if entry["median"] is not None:
                    values.extend(entry["ci95"])
            low, high = min(values), max(values)
            pad = (high - low) * 0.08 if high != low else 1.0
            ticks = nice_ticks(low - pad, high + pad)
            to_x = scale(ticks[0], ticks[-1], left, right)
            top = y + 20
            axis_y = top + 66
            for tick in ticks:
                x = to_x(tick)
                parts.append('<line class="grid" x1="%.1f" x2="%.1f" y1="%d" y2="%d"/>' % (x, x, top, axis_y))
                parts.append('<text class="m" x="%.1f" y="%d" text-anchor="middle">%s</text>' % (x, axis_y + 14, esc(fmt_tick(unit, tick, ticks))))
            parts.append('<line class="zero" x1="%.1f" x2="%.1f" y1="%d" y2="%d"/>' % (to_x(0), to_x(0), top, axis_y))
            for row_index, (baseline, comp, series) in enumerate(rows):
                entry = results["comparisons"][comp][name]
                row_y = top + 18 + row_index * 30
                parts.append('<text class="l" x="%d" y="%d" text-anchor="end">vs %s</text>' % (left - 12, row_y + 4, esc(baseline)))
                if entry["median"] is None:
                    parts.append('<text class="m" x="%d" y="%d">not computed: no task has this value</text>' % (left + 4, row_y + 4))
                    continue
                low_ci, high_ci = entry["ci95"]
                for task, diff in sorted(entry["per_task"].items()):
                    if diff is None:
                        continue
                    parts.append('<circle class="s%s" opacity="0.35" cx="%.1f" cy="%d" r="4"><title>%s</title></circle>' % (
                        series, to_x(diff), row_y, esc("%s, vs %s: %s" % (task, baseline, fmt_value(unit, diff, signed=True)))))
                parts.append('<line class="ls%s" x1="%.1f" x2="%.1f" y1="%d" y2="%d"/>' % (series, to_x(low_ci), to_x(high_ci), row_y, row_y))
                parts.append('<circle class="s%s ring" cx="%.1f" cy="%d" r="6"><title>%s</title></circle>' % (
                    series, to_x(entry["median"]), row_y, esc("%s vs %s: median %s" % (label, baseline, interval_text(unit, entry)))))
                parts.append('<text class="l" x="%d" y="%d">%s</text>' % (right + 12, row_y + 4, esc(interval_text(unit, entry))))
            y = axis_y + 26
        return "".join(parts), y - 8
    subtitle = "Dot: median across tasks. Line: 95% bootstrap interval. Faint dots: individual tasks."
    return svg_document(results, width, title, subtitle, body)


def write_outputs(results, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    charts = [
        {"file": "chart_cost_per_solved.svg", "alt": "Cost per solved task by arm", "render": chart_cost_per_solved},
        {"file": "chart_cost_by_task.svg", "alt": "Average cost per run by task and arm", "render": chart_cost_by_task},
    ]
    for question in QUESTIONS:
        charts.append({
            "file": "chart_%s.svg" % question[0],
            "alt": question[1],
            "render": (lambda data, item=question: chart_differences(data, item)),
        })
    for chart in charts:
        with open(os.path.join(out_dir, chart["file"]), "w", encoding="utf-8") as handle:
            handle.write(chart["render"](results))
    if results.get("held_out"):
        held_charts = [
            ("chart_held_out_cost_per_solved.svg", lambda data: chart_cost_per_solved(data)),
            ("chart_held_out_cost_by_task.svg", lambda data: chart_cost_by_task(data)),
        ]
        for question in QUESTIONS:
            held_charts.append(("chart_held_out_%s.svg" % question[0], lambda data, item=question: chart_differences(data, item)))
        for file_name, render in held_charts:
            with open(os.path.join(out_dir, file_name), "w", encoding="utf-8") as handle:
                handle.write(render(results["held_out"]))
    with open(os.path.join(out_dir, "report.md"), "w", encoding="utf-8") as handle:
        handle.write(render_report(results, charts))
    with open(os.path.join(out_dir, "results.json"), "w", encoding="utf-8") as handle:
        json.dump(results, handle, indent=2, sort_keys=False, ensure_ascii=False)
        handle.write("\n")
    return [chart["file"] for chart in charts]


# ------------------------------------------------------------------ protocol 3
# Everything below runs only with --protocol 3. Protocols 1 and 2 never call it, so
# their outputs are unchanged byte for byte.
PROTOCOL3_ARMS = ("none", "generic", "olivium", "none-lean")
PROTOCOL3_PRIMARY = ("olivium", "none")
PROTOCOL3_SECONDARY = ("olivium", "generic")
PROTOCOL3_LEAN = ("none-lean", "none")
TOKEN_PARTS = ("input", "output", "cache_creation", "cache_read")
ALPHA = 0.05
DRAMATIC_TOKEN_RATIO = 0.75
DRAMATIC_SOLVE_POINTS = 20
TOKEN_TOLERANCE_RATIO = 1.05
DEFAULT_TOLERANCE_POINTS = 10
REFUSALS_PER_TEN_RUNS = 1
SIGN_FLIP_MAX_TASKS = 40
PROTOCOL3_LEAN_CONTROL = ("olivium", "none-lean")
SUBAGENT_TOOLS = ("Agent", "Task")
TRIM_FORMAT = "olivium-bench-trim-v1"
OUT_RECORD_FORMAT = "olivium-bench-out-v3"
GRADE_KILLED_EXIT = "137"
# Gate 1 (paid rehearsal on the 8 v2 development tasks, 2026-11-11; review 2, section 2 and M3).
# Printed next to the headline only when the scored run has no none-lean runs.
GATE1_DEVELOPMENT_FIGURES = {
    "olivium_over_none_tokens_median": 0.363,
    "none_lean_over_none_tokens_median": 0.317,
    "olivium_over_none_lean_tokens_median": 1.175,
    "behaviour_only_ratio_median": 0.858,
    "source": "Gate 1 paid rehearsal, v2 development tasks (8 tasks; none-lean 1 repeat)",
}
ATTRIBUTION_RULE = (
    "PROTOCOL-v3.md, change log of 2026-11-11 (attribution): a primary that passes against none is "
    "credited to the harness's text and hooks only when olivium also passes against none-lean on that "
    "primary in the same direction; otherwise it is worded as a configuration (settings) gain, and no "
    "wording may credit CLAUDE.md or the hooks. The behaviour-only ratio is an optimistic bound for the "
    "text and hooks: it credits them with every change in behaviour that the trim itself causes."
)
DEPRECATION_SIGNAL = "practices.deprecation"
VERDICTS = (
    ("insufficient_data", "A primary has no task with data in both setups."),
    ("failure", "Tokens significantly higher, or solve rate significantly lower, or more than %d refusal "
                "of normal work per 10 olivium runs." % REFUSALS_PER_TEN_RUNS),
    ("dramatic", "Tokens at least 25%% lower and passing, or solve rate at least %d points higher and passing; "
                 "the other primary within tolerance (tokens at most +5%%; solve rate at least -T points "
                 "and not significantly lower)." % DRAMATIC_SOLVE_POINTS),
    ("gain_with_accuracy_warning", "A primary passes; the other is outside its tolerance but not significantly worse."),
    ("measurable", "A primary passes below the dramatic bar; the other is within tolerance."),
    ("no_demonstrated", "Neither primary passes."),
)
CACHE_NOTE = (
    "Dollars are secondary. A cache read is billed at a fraction of the price of a fresh input token, "
    "so the same number of tokens costs less when more of it is read from the prompt cache, and cache "
    "warmth differs between runs. The cache-read share of each setup's tokens is shown next to its cost."
)


def total_tokens(row):
    tokens = row.get("tokens") or {}
    parts = [tokens.get(name) for name in TOKEN_PARTS]
    if any(not isinstance(part, (int, float)) or isinstance(part, bool) for part in parts):
        return None
    return float(sum(parts))


def bootstrap_mean_interval(values, resamples=RESAMPLES, seed=SEED):
    """Percentile bootstrap 95% interval of the mean, resampling tasks with replacement."""
    rng = random.Random(seed)
    count = len(values)
    means = []
    for _ in range(resamples):
        means.append(sum(values[rng.randrange(count)] for _ in range(count)) / count)
    means.sort()
    return percentile(means, 0.025), percentile(means, 0.975)


def _signed_sums(values):
    sums = [0.0]
    for value in values:
        sums = [total + value for total in sums] + [total - value for total in sums]
    return sums


def sign_flip_p(values):
    """Exact two-sided sign-flip test of "symmetric around zero", statistic = sum.

    Every one of the 2^n sign assignments is counted (meet in the middle: the sums of
    the two halves are enumerated and paired with a binary search), so the p-value is
    exact, not sampled. Exact zeros carry no sign and are dropped, which leaves the
    p-value unchanged. Sums within 1e-9 (relative) of the observed one count as ties.
    """
    nonzero = [float(value) for value in values if abs(value) > 1e-12]
    count = len(nonzero)
    if count == 0:
        return 1.0
    if count > SIGN_FLIP_MAX_TASKS:
        raise DataError("the exact sign-flip test is limited to %d tasks" % SIGN_FLIP_MAX_TASKS)
    observed = abs(sum(nonzero))
    threshold = observed - 1e-9 * max(1.0, observed)
    if threshold <= 0:
        return 1.0
    half = count // 2
    left = _signed_sums(nonzero[:half])
    right = sorted(_signed_sums(nonzero[half:]))
    extreme = 0
    for total in left:
        extreme += len(right) - bisect.bisect_left(right, threshold - total)
        extreme += bisect.bisect_right(right, -threshold - total)
    return extreme / float(2 ** count)


def paired_test(values, kind):
    """Both decision tests on per-task values. kind "ratio": median of ratios, null 1,
    sign-flip on log ratios. kind "difference": mean of differences, null 0."""
    null = 1.0 if kind == "ratio" else 0.0
    entry = {
        "kind": kind, "null": null, "tasks_used": len(values), "estimate": None, "ci95": None,
        "sign_flip_p": None, "interval_excludes_null": False, "below_null": False, "above_null": False,
    }
    if not values:
        return entry
    if kind == "ratio":
        estimate = median(values)
        low, high = bootstrap_interval(values)
        p_value = sign_flip_p([math.log(value) for value in values])
    else:
        estimate = sum(values) / len(values)
        low, high = bootstrap_mean_interval(values)
        p_value = sign_flip_p(values)
    entry.update({
        "estimate": estimate, "ci95": [low, high], "sign_flip_p": p_value,
        "interval_excludes_null": high < null or low > null,
        "below_null": high < null and p_value < ALPHA,
        "above_null": low > null and p_value < ALPHA,
    })
    return entry


def load_trials_v3(in_dir):
    rows = read_jsonl(os.path.join(in_dir, "trials.jsonl"))
    if not rows:
        raise DataError("no trials found in %s" % os.path.join(in_dir, "trials.jsonl"))
    for row in rows:
        missing = [field for field in REQUIRED_FIELDS if field not in row]
        if missing:
            raise DataError("trial %s is missing fields: %s" % (row.get("run_id"), ", ".join(missing)))
        if row["status"] not in STATUSES:
            raise DataError("trial %s has unknown status %s" % (row["run_id"], row["status"]))
        if row["arm"] not in PROTOCOL3_ARMS:
            raise DataError("trial %s has unknown arm %s" % (row["run_id"], row["arm"]))
    return rows


def _plain_name(value):
    return isinstance(value, str) and value not in ("", ".", "..") and "/" not in value and "\\" not in value


def setup_means(runs, tasks, arms):
    """{task: {arm: per-task means over repeats, or None}}."""
    means = {}
    for task in tasks:
        means[task] = {}
        for arm in arms:
            repeats = runs.get(task, {}).get(arm, {})
            rows = [repeats[key] for key in sorted(repeats)]
            if not rows:
                means[task][arm] = None
                continue
            tokens = [total_tokens(row) for row in rows]
            solved = sum(1 for row in rows if row["solved"])
            means[task][arm] = {
                "runs": len(rows),
                "solved": solved,
                "solve_rate": solved / float(len(rows)),
                "mean_tokens": mean_or_none(tokens),
                "runs_without_tokens": sum(1 for value in tokens if value is None),
                "mean_turns": mean_or_none([row.get("turns") for row in rows]),
                "mean_requests": mean_or_none([row.get("requests") for row in rows]),
                "mean_cost_usd": mean_or_none([row.get("cost_usd") for row in rows]),
            }
    return means


def compare_v3(means, tasks, treated, baseline):
    ratios, differences, excluded = {}, {}, {}
    for task in tasks:
        a, b = means[task].get(treated), means[task].get(baseline)
        if a is None or b is None:
            ratios[task] = differences[task] = None
            excluded[task] = "no scored run in %s" % (treated if a is None else baseline)
            continue
        differences[task] = a["solve_rate"] - b["solve_rate"]
        if a["mean_tokens"] and b["mean_tokens"] and a["mean_tokens"] > 0 and b["mean_tokens"] > 0:
            ratios[task] = a["mean_tokens"] / b["mean_tokens"]
        else:
            ratios[task] = None
            excluded[task] = "no token count"
    tokens = paired_test([ratios[task] for task in tasks if ratios[task] is not None], "ratio")
    solve = paired_test([differences[task] for task in tasks if differences[task] is not None], "difference")
    tokens.update({"per_task": ratios, "tasks_excluded": sorted(task for task in tasks if ratios[task] is None)})
    solve.update({"per_task": differences, "tasks_excluded": sorted(task for task in tasks if differences[task] is None)})
    return {"treated": treated, "baseline": baseline, "tokens": tokens, "solve_rate": solve, "exclusions": excluded}


def refusal_counts(rows, arm="olivium"):
    scored = [row for row in rows if row["arm"] == arm and row["status"] != "infra_error"]
    refusals = sum(int(row.get("permission_denials") or 0) for row in scored)
    stop_blocks = sum(int(row.get("hook_blocks") or 0) for row in scored)
    return {
        "arm": arm, "runs": len(scored), "refusals": refusals, "stop_blocks": stop_blocks,
        "limit": "more than %d per 10 runs" % REFUSALS_PER_TEN_RUNS,
        "over_limit": refusals * 10 > REFUSALS_PER_TEN_RUNS * len(scored),
        "counted_as": "every permission denial in an olivium run (the trial row's permission_denials); "
                      "this script does not separate policy refusals from refusals of normal work, so "
                      "the count is an upper bound",
    }


def decide_verdict(primary, refusals, tolerance_points):
    tokens, solve = primary["tokens"], primary["solve_rate"]
    tokens_pass, tokens_worse = tokens["below_null"], tokens["above_null"]
    solve_pass, solve_worse = solve["above_null"], solve["below_null"]
    tokens_within = tokens["estimate"] is not None and tokens["estimate"] <= TOKEN_TOLERANCE_RATIO + 1e-12 and not tokens_worse
    solve_within = (solve["estimate"] is not None and solve["estimate"] >= -tolerance_points / 100.0 - 1e-9
                    and not solve_worse)
    tokens_dramatic = tokens_pass and tokens["estimate"] <= DRAMATIC_TOKEN_RATIO + 1e-12
    solve_dramatic = solve_pass and solve["estimate"] >= DRAMATIC_SOLVE_POINTS / 100.0 - 1e-9
    met = {
        "insufficient_data": tokens["tasks_used"] == 0 or solve["tasks_used"] == 0,
        "failure": tokens_worse or solve_worse or refusals["over_limit"],
        "dramatic": (tokens_dramatic and solve_within) or (solve_dramatic and tokens_within),
        "gain_with_accuracy_warning": (tokens_pass and not solve_within and not solve_worse)
        or (solve_pass and not tokens_within and not tokens_worse),
        "measurable": (tokens_pass and solve_within) or (solve_pass and tokens_within),
        "no_demonstrated": not tokens_pass and not solve_pass,
    }
    verdict = next(name for name, _rule in VERDICTS if met[name])
    return {
        "verdict": verdict,
        "tolerance_points": tolerance_points,
        "checks": {
            "tokens_pass": tokens_pass, "tokens_significantly_higher": tokens_worse,
            "tokens_within_tolerance": tokens_within, "tokens_at_dramatic_bar": tokens_dramatic,
            "solve_pass": solve_pass, "solve_significantly_lower": solve_worse,
            "solve_within_tolerance": solve_within, "solve_at_dramatic_bar": solve_dramatic,
            "refusals_over_limit": refusals["over_limit"],
        },
        "table": [{"verdict": name, "rule": rule, "met": met[name]} for name, rule in VERDICTS],
        "order": "the first verdict in the table whose rule is met",
    }


def load_trim(path):
    if not os.path.exists(path):
        return None, "no trim file at %s" % path
    try:
        data = read_json(path)
    except ValueError:
        return None, "the trim file is not valid JSON"
    if not isinstance(data, dict) or data.get("format") != TRIM_FORMAT:
        return None, "the trim file is not in format %s" % TRIM_FORMAT
    if not isinstance(data.get("tasks"), dict):
        return None, "the trim file has no tasks object"
    return data, None


def behaviour_only(means, tasks, trim, count_field):
    """Per task (olivium tokens + trim x olivium count) / none tokens; trim is what the
    olivium configuration removes from every request, so adding it back leaves what
    olivium's text and hooks changed."""
    per_task, trims, excluded = {}, {}, {}
    for task in tasks:
        a, b = means[task].get("olivium"), means[task].get("none")
        record = trim["tasks"].get(task)
        value = record.get("trim_tokens") if isinstance(record, dict) else None
        if not isinstance(value, int) or isinstance(value, bool):
            per_task[task], excluded[task] = None, "no trim_tokens for this task"
            continue
        trims[task] = value
        if a is None or b is None or not a["mean_tokens"] or not b["mean_tokens"] or a[count_field] is None:
            per_task[task], excluded[task] = None, "no tokens or %s in both setups" % count_field.replace("mean_", "")
            continue
        ratio = (a["mean_tokens"] + value * a[count_field]) / b["mean_tokens"]
        if ratio <= 0:
            per_task[task], excluded[task] = None, "the adjusted ratio is not positive"
            continue
        per_task[task] = ratio
    entry = paired_test([per_task[task] for task in tasks if per_task[task] is not None], "ratio")
    entry.update({"per_task": per_task, "trim_tokens": trims, "tasks_excluded": excluded})
    return entry


def behaviour_section(means, tasks, primary, trim_path):
    trim, reason = load_trim(trim_path)
    if trim is None:
        return {"available": False, "reason": reason + "; the behaviour-only ratio is not computed (never assumed zero)"}
    by_turns = behaviour_only(means, tasks, trim, "mean_turns")
    by_requests = behaviour_only(means, tasks, trim, "mean_requests")
    total = primary["tokens"]["estimate"]
    share = None
    if total is not None and by_turns["estimate"] is not None and total < 1:
        share = (by_turns["estimate"] - total) / (1 - total)
    return {
        "available": True,
        "trim_file": os.path.realpath(trim_path),
        "trim_method": trim.get("method"),
        "claude_code_version": trim.get("claude_code_version"),
        "count": "turns: main-session assistant messages in the trial row; every one is a request that "
                 "carries the trimmed prefix. Subagent and background requests do not carry it.",
        "by_turns": by_turns,
        "by_requests_sensitivity": by_requests,
        "configuration_share_of_saving": share,
        "configuration_share_note": "(behaviour-only median - token ratio median) / (1 - token ratio median); "
                                    "arithmetic on two medians, shown only when olivium used fewer tokens",
    }


def _transcript_subagent_tokens(path):
    """Tokens of assistant messages written by subagents (parent_tool_use_id set), each
    message counted once. Returns None when there is no transcript."""
    if not os.path.isfile(path):
        return None
    usage_by_message = {}
    for event in read_jsonl(path):
        if not isinstance(event, dict) or event.get("type") != "assistant" or not event.get("parent_tool_use_id"):
            continue
        message = event.get("message") or {}
        usage = message.get("usage") or {}
        key = message.get("id") or ("line-%d" % len(usage_by_message))
        usage_by_message[key] = sum(
            int(usage.get(name) or 0)
            for name in ("input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")
        )
    return sum(usage_by_message.values())


def subagent_use(in_dir, rows, arms):
    found = {}
    for arm in arms:
        scored = [row for row in rows if row["arm"] == arm and row["status"] != "infra_error"]
        if not scored:
            continue
        calls = [sum(int((row.get("tool_calls") or {}).get(name) or 0) for name in SUBAGENT_TOOLS) for row in scored]
        tokens, read = 0, 0
        for row in scored:
            if not _plain_name(row["run_id"]):
                continue
            value = _transcript_subagent_tokens(os.path.join(in_dir, "trials", row["run_id"], "transcript.jsonl"))
            if value is not None:
                tokens += value
                read += 1
        found[arm] = {
            "runs": len(scored),
            "runs_with_subagent": sum(1 for count in calls if count > 0),
            "subagent_calls": sum(calls),
            "transcripts_read": read,
            "subagent_tokens": tokens if read else None,
            "subagent_tokens_per_run": tokens / float(read) if read else None,
        }
    return {"tools": list(SUBAGENT_TOOLS), "by_setup": found,
            "note": "Subagent tokens come from the transcripts (usage of assistant messages with a "
                    "parent_tool_use_id); the meter totals in tokens already include them."}


def dollars_section(rows, means, tasks, arms):
    by_setup = {}
    for arm in arms:
        scored = [row for row in rows if row["arm"] == arm and row["status"] != "infra_error"]
        if not scored:
            continue
        parts = {name: sum(float((row.get("tokens") or {}).get(name) or 0) for row in scored) for name in TOKEN_PARTS}
        total = sum(parts.values())
        cost = sum(float(row.get("cost_usd") or 0) for row in scored)
        by_setup[arm] = {
            "runs": len(scored),
            "total_cost_usd": cost,
            "mean_cost_usd": cost / len(scored),
            "cache_read_share_of_tokens": parts["cache_read"] / total if total else None,
            "usd_per_million_tokens": cost / total * 1e6 if total else None,
        }
    ratios = {}
    for task in tasks:
        a, b = means[task].get("olivium"), means[task].get("none")
        costs = (a and a["mean_cost_usd"], b and b["mean_cost_usd"])
        ratios[task] = costs[0] / costs[1] if all(value and value > 0 for value in costs) else None
    olivium_none = paired_test([ratios[task] for task in tasks if ratios[task] is not None], "ratio")
    olivium_none["per_task"] = ratios
    return {"by_setup": by_setup, "olivium_over_none_cost_ratio": olivium_none, "note": CACHE_NOTE}


# ---------------------------------------------------- deprecation compliance
PATCH_FILE = re.compile(r"^diff --git a/(\S+) b/(\S+)")
PATCH_HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+\d+(?:,\d+)? @@ ?(.*)$")
SOURCE_SUFFIXES = (".py", ".js", ".mjs", ".cjs", ".jsx", ".ts", ".tsx")
NOT_SOURCE_PARTS = ("test", "tests", "testing", "__tests__", "spec", "docs", "doc", "examples", "benchmarks")
PY_DEF = re.compile(r"^( *)(?:async\s+)?def\s+([A-Za-z_]\w*)\s*\(")
PY_CLASS = re.compile(r"^class\s+([A-Za-z_]\w*)")
PY_ATTRIBUTE = re.compile(r"^( *)([A-Za-z_]\w*)\s*(?::[^=]*)?=(?!=)")
JS_DEFINITIONS = (
    re.compile(r"^(?:export\s+(?:default\s+)?)?(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)\s*\("),
    re.compile(r"^\s*(?:module\.)?exports\.([A-Za-z_$][\w$]*)\s*="),
    re.compile(r"^\s*export\s+(?:const|let|var|class)\s+([A-Za-z_$][\w$]*)"),
    re.compile(r"^[A-Za-z_$][\w$]*\.([A-Za-z_$][\w$]*)\s*=\s*(?:async\s+)?function\b"),
)
JS_METHOD = re.compile(r"^ {2,4}(?:static\s+|async\s+|get\s+|set\s+)*([A-Za-z_$][\w$]*)\s*\([^()]*\)\s*\{")
JS_KEYWORDS = frozenset(("if", "for", "while", "switch", "catch", "function", "return", "with", "else"))
WARN_CALL = re.compile(
    r"\b(?:warn|emitWarning|deprecate|depd|deprecated|deprecatedMethod|warnDeprecated)\s*\(|@deprecated\b"
)
DEPRECATION_WORD = re.compile(r"deprecat|RemovedIn\w*Warning|FutureWarning", re.IGNORECASE)
PATCH_OUTCOMES = ("removed_without_warning", "removed_with_warning", "kept_with_warning", "no_removal")


def _source_file(path):
    if not path.endswith(SOURCE_SUFFIXES):
        return False
    parts = path.split("/")
    name = parts[-1]
    if any(part.lower() in NOT_SOURCE_PARTS for part in parts[:-1]):
        return False
    return not (name.startswith("test_") or name == "conftest.py" or name.endswith(("_test.py",))
                or ".test." in name or ".spec." in name)


def _definitions(path, line, context):
    """Public names a source line defines, under the class or function the hunk is in."""
    if path.endswith(".py"):
        match = PY_DEF.match(line)
        if match:
            indent, name = len(match.group(1)), match.group(2)
            return [name] if indent == 0 or (indent == 4 and context.startswith("class ")) else []
        match = PY_CLASS.match(line)
        if match:
            return [match.group(1)]
        match = PY_ATTRIBUTE.match(line)
        if match:
            indent, name = len(match.group(1)), match.group(2)
            return [name] if indent == 0 or (indent == 4 and context.startswith("class ")) else []
        return []
    names = [match.group(1) for pattern in JS_DEFINITIONS for match in [pattern.match(line)] if match]
    if not names and context.startswith(("class ", "export class ", "export default class ")):
        match = JS_METHOD.match(line)
        if match and match.group(1) not in JS_KEYWORDS:
            names.append(match.group(1))
    return names


def classify_patch(text):
    """"Removes a public name and adds no warning": compare the public names that source
    lines define on removed lines with those on added lines (a name defined again
    anywhere in the patch is kept), and look for an added warning call next to a
    deprecation word in the same source file. Tests, docs and examples are not source."""
    removed, added = set(), set()
    added_text = {}
    path, context, in_hunk = None, "", False
    for raw in text.splitlines():
        header = PATCH_FILE.match(raw)
        if header:
            path, context, in_hunk = header.group(2), "", False
            continue
        hunk = PATCH_HUNK.match(raw)
        if hunk:
            context, in_hunk = hunk.group(1).strip(), True
            continue
        if path is None or not in_hunk or not _source_file(path) or not raw:
            continue
        sign, line = raw[0], raw[1:]
        if sign not in "+- ":
            continue
        if line[:1].isalpha() and line.startswith(("class ", "def ", "async def ", "export class ", "export default class ")):
            context = line
        names = [name for name in _definitions(path, line, context) if not name.startswith("_")]
        if sign == "-":
            removed.update(names)
        elif sign == "+":
            added.update(names)
            added_text.setdefault(path, []).append(line)
    gone = sorted(removed - added)
    warned = sorted(
        path for path, lines in added_text.items()
        if WARN_CALL.search("\n".join(lines)) and DEPRECATION_WORD.search("\n".join(lines))
    )
    if gone:
        outcome = "removed_with_warning" if warned else "removed_without_warning"
    else:
        outcome = "kept_with_warning" if warned else "no_removal"
    return {"outcome": outcome, "removed_names": gone, "warning_files": warned}


def _rule_shown(arm_dir):
    """True when the olivium export's spec has the deprecation practice rule and its
    CLAUDE.md shows the sentence (it can be withheld by the byte budget)."""
    spec = read_json(os.path.join(arm_dir, ".olivium", "spec.json"))
    if not isinstance(spec, dict):
        return False, False
    body = spec.get("spec") if isinstance(spec.get("spec"), dict) else spec
    statements = [rule.get("statement") for rule in body.get("rules") or []
                  if isinstance(rule, dict) and (rule.get("source") or {}).get("signal") == DEPRECATION_SIGNAL]
    if not statements:
        return False, False
    claude = os.path.join(arm_dir, "CLAUDE.md")
    shown = False
    if os.path.isfile(claude):
        with open(claude, "r", encoding="utf-8") as handle:
            text = handle.read()
        shown = any(isinstance(statement, str) and ("- %s\n" % statement) in text for statement in statements)
    return True, shown


def deprecation_compliance(in_dir, rows, tasks, arms):
    fired, by_task = [], {}
    for task in tasks:
        if not _plain_name(task):
            continue
        in_spec, shown = _rule_shown(os.path.join(in_dir, "arms", task, "olivium"))
        if not shown:
            continue
        fired.append(task)
        by_task[task] = {}
        for arm in arms:
            counts = {outcome: 0 for outcome in PATCH_OUTCOMES + ("no_patch",)}
            scored = [row for row in rows if row["task_id"] == task and row["arm"] == arm and row["status"] != "infra_error"]
            if not scored:
                continue
            for row in scored:
                patch = os.path.join(in_dir, "trials", row["run_id"], "agent.patch") if _plain_name(row["run_id"]) else None
                if patch is None or not os.path.isfile(patch):
                    counts["no_patch"] += 1
                    continue
                with open(patch, "r", encoding="utf-8", errors="replace") as handle:
                    counts[classify_patch(handle.read())["outcome"]] += 1
            counts["runs"] = len(scored)
            counts["compliant"] = len(scored) - counts["removed_without_warning"] - counts["no_patch"]
            by_task[task][arm] = counts
    return {
        "tasks_where_rule_fired": fired,
        "by_task": by_task,
        "rule": "the olivium export's CLAUDE.md shows the deprecation practice sentence",
        "classifier": "removes a public name and adds no warning = removed_without_warning (not compliant)",
        "claim": "none" if not fired else "reported per task; no claim beyond these tasks",
    }


# ------------------------------------------------- input checks (review 2, M2)
def manifest_checksum_v3(manifest):
    """lib/common.py manifest_checksum, byte for byte: analyze.py stays standalone."""
    payload = {"selection": manifest["selection"], "tasks": manifest["tasks"]}
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def load_manifest_v3(path):
    try:
        manifest = read_json(path)
    except ValueError:
        raise DataError("the manifest is not valid JSON: %s" % path)
    if not isinstance(manifest, dict) or not isinstance(manifest.get("tasks"), list) \
            or not isinstance(manifest.get("selection"), dict):
        raise DataError("not a benchmark manifest: %s" % path)
    return manifest


def scored_problems(in_dir, rows, tasks, manifest, given_checksum):
    """Why this OUT is not a scored protocol 3 run of the frozen manifest; [] when it is."""
    problems = []
    try:
        record = read_json(os.path.join(in_dir, "protocol.json"))
    except ValueError:
        record = None
    if not isinstance(record, dict):
        problems.append("no OUT/protocol.json from the protocol 3 runner")
        record = {}
    else:
        if record.get("format") != OUT_RECORD_FORMAT or record.get("protocol") != 3:
            problems.append("OUT/protocol.json is not %s for protocol 3" % OUT_RECORD_FORMAT)
        if record.get("mode") != "scored" or record.get("pilot") is not False:
            problems.append("OUT/protocol.json records mode %r, pilot %r: not a scored run" % (
                record.get("mode"), record.get("pilot")))
    bad = [row["run_id"] for row in rows if row.get("protocol") != 3 or row.get("pilot") is not False]
    if bad:
        problems.append("%d of %d trial rows are not protocol 3 scored rows (first %s)" % (len(bad), len(rows), bad[0]))
    computed = manifest_checksum_v3(manifest)
    if manifest.get("checksum") != computed:
        problems.append("the manifest's checksum field does not match its content")
    if given_checksum != computed:
        problems.append("the manifest is not the frozen one: its checksum %s is not the --manifest-checksum given"
                        % computed[:12])
    if record and record.get("manifest_checksum") != computed:
        problems.append("OUT was made for another manifest (OUT/protocol.json)")
    known = {task.get("task_id") for task in manifest["tasks"] if isinstance(task, dict)}
    missing = [task for task in tasks if task not in known]
    if missing:
        problems.append("%d task(s) of this OUT are not in the manifest (first %s)" % (len(missing), missing[0]))
    return problems


# ------------------------------------------- context-use outcomes (review 2, M4)
def _prompt_tokens(meter_row):
    return sum(int(meter_row.get(name) or 0) for name in (
        "input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))


def _request_tokens(meter_row):
    return _prompt_tokens(meter_row) + int(meter_row.get("output_tokens") or 0)


def _assistant_message_count(path):
    seen = set()
    for event in read_jsonl(path):
        if isinstance(event, dict) and event.get("type") == "assistant":
            seen.add((event.get("message") or {}).get("id"))
    return len(seen)


def run_context(in_dir, row, meter_rows):
    """One run's context-use values from the meter rows (seq order) and its trace.

    first_request_tokens: prompt tokens (input + cache write + cache read) of the run's
    first request on its main model. largest_context: the largest such prompt. warm_start:
    that first request read from the prompt cache. tokens_before_first_gold_edit: total
    tokens (output included) of every request up to and including the one whose answer
    made the first edit of a file the real fix changed (shell edits count, as the trace
    finds them). It maps the edit's assistant message (k-th, subagents included) to the
    k-th request, so it is "not available" unless the run's request rows (all of them, or
    those on the main model) and its transcript messages are equally many.
    """
    messages = sorted((item for item in meter_rows if item.get("endpoint", "messages") == "messages"),
                      key=lambda item: int(item.get("seq") or 0))
    main = [item for item in messages if item.get("model") == row.get("model")] or messages
    entry = {"first_request_tokens": None, "largest_context": None, "warm_start": None,
             "tokens_before_first_gold_edit": None, "gold_edit": "not_available"}
    if not main:
        entry["reason"] = "no meter rows"
        return entry
    entry["first_request_tokens"] = _prompt_tokens(main[0])
    entry["largest_context"] = max(_prompt_tokens(item) for item in main)
    entry["warm_start"] = int(main[0].get("cache_read_input_tokens") or 0) > 0
    if not _plain_name(row["run_id"]):
        entry["reason"] = "run id is not a plain name"
        return entry
    base = os.path.join(in_dir, "trials", row["run_id"])
    try:
        trace = read_json(os.path.join(base, "trace.json"))
    except ValueError:
        trace = None
    if not isinstance(trace, dict):
        entry["reason"] = "no trace.json"
        return entry
    first = trace.get("first_gold_edit")
    if not first:
        entry["gold_edit"] = "never"
        return entry
    count = _assistant_message_count(os.path.join(base, "transcript.jsonl"))
    # Every request, or, when Claude Code also made background calls on another model that
    # leave no transcript message, the main-model requests; never a guess between them.
    basis = next(((name, items) for name, items in (("all requests", messages), ("main-model requests", main))
                  if len(items) == count), None)
    if basis is None:
        entry["reason"] = "%d transcript messages, %d meter requests (%d on the main model)" % (count, len(messages), len(main))
        return entry
    upto = int(first.get("turns_before") or 0) + 1
    entry["tokens_before_first_gold_edit"] = sum(_request_tokens(item) for item in basis[1][:upto])
    entry["gold_edit"] = "edited"
    entry["gold_edit_basis"] = basis[0]
    return entry


def _summary(values):
    present = [float(value) for value in values if value is not None]
    if not present:
        return {"runs": 0, "mean": None, "median": None, "max": None}
    return {"runs": len(present), "mean": sum(present) / len(present), "median": median(present), "max": max(present)}


def context_use(in_dir, rows, tasks, arms):
    """The named context-use outcomes per setup, and olivium / none per task."""
    meter = {}
    for item in read_jsonl(os.path.join(in_dir, "meter", "requests.jsonl")):
        meter.setdefault(item.get("run_id"), []).append(item)
    per_run = {}
    for row in rows:
        if row["status"] == "infra_error" or row["arm"] not in arms:
            continue
        per_run[row["run_id"]] = (row, run_context(in_dir, row, meter.get(row["run_id"], [])))
    fields = ("first_request_tokens", "tokens_before_first_gold_edit", "largest_context")
    by_setup = {}
    for arm in arms:
        entries = [entry for row, entry in per_run.values() if row["arm"] == arm]
        if not entries:
            continue
        item = {field: _summary([entry[field] for entry in entries]) for field in fields}
        item.update({
            "runs": len(entries),
            "warm_starts": sum(1 for entry in entries if entry["warm_start"]),
            "runs_without_meter_rows": sum(1 for entry in entries if entry["warm_start"] is None),
            "runs_that_never_edited_a_fix_file": sum(1 for entry in entries if entry["gold_edit"] == "never"),
            "runs_with_edit_not_mapped": sum(1 for entry in entries if entry["gold_edit"] == "not_available"),
        })
        by_setup[arm] = item
    ratios = {}
    for field in fields:
        per_task = {}
        for task in tasks:
            means = []
            for arm in PROTOCOL3_PRIMARY:
                values = [entry[field] for row, entry in per_run.values()
                          if row["task_id"] == task and row["arm"] == arm and entry[field] is not None]
                means.append(sum(values) / float(len(values)) if values else None)
            per_task[task] = means[0] / means[1] if all(value for value in means) else None
        entry = paired_test([per_task[task] for task in tasks if per_task[task] is not None], "ratio")
        entry["per_task"] = per_task
        ratios[field] = entry
    return {
        "by_setup": by_setup,
        "olivium_over_none": ratios,
        "definitions": {
            "first_request_tokens": "prompt tokens (input + cache write + cache read) of the run's first request on its main model",
            "tokens_before_first_gold_edit": "total tokens of every request up to and including the one whose answer first "
                                             "edited a file the real fix changed (shell edits count); runs that never "
                                             "edited one are counted, not averaged",
            "largest_context": "the largest prompt (input + cache write + cache read) of any main-model request of the run",
            "warm_start": "the run's first main-model request read from the prompt cache (a cache another run left)",
        },
    }


# ----------------------------------------------------- other secondaries (M4)
CHANGELOG_NAME = re.compile(r"^(changelog|changes|history|news|release[-_ ]?notes)", re.IGNORECASE)
TEST_PATH_PARTS = frozenset(("tests", "test", "__tests__", "__test__", "testing", "spec", "specs"))
TEST_FILE_NAME = re.compile(r"^(test_.*\.py|.*_test\.py|conftest\.py|.*\.(test|spec)\.(js|jsx|mjs|cjs|ts|tsx|mts|cts))$")
WRONG_COMMAND_PATTERNS = (
    ("command_not_found", re.compile(r"command not found|: not found$|No such file or directory: '?(?:uv|pytest|npx|node)", re.MULTILINE)),
    ("no_module_named", re.compile(r"No module named")),
    ("unknown_option", re.compile(r"unrecognized arguments|[Uu]nknown option|unknown command|Unknown argument")),
    ("zero_tests_collected", re.compile(r"collected 0 items|no tests ran|No test files found|No tests found")),
)
TEST_COMMAND_WORDS = re.compile(r"\b(pytest|vitest|jest|mocha|npm (?:run )?test|yarn test|pnpm test|node --test)\b")


def _is_changelog(path):
    parts = path.split("/")
    return "changelog.d" in [part.lower() for part in parts] or bool(CHANGELOG_NAME.match(parts[-1]))


def _is_test_path(path):
    parts = path.split("/")
    return any(part in TEST_PATH_PARTS for part in parts[:-1]) or bool(TEST_FILE_NAME.match(parts[-1]))


def _patch_paths(path):
    found = []
    if not os.path.isfile(path):
        return None
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            match = PATCH_FILE.match(line)
            if match:
                found.append(match.group(2))
    return found


def _result_text(block):
    content = block.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(item.get("text", "") for item in content if isinstance(item, dict) and isinstance(item.get("text"), str))
    return ""


def command_outcomes(path):
    """Wrong-command results and whether the first test command worked, from a transcript."""
    commands, order, results = {}, [], {}
    for event in read_jsonl(path):
        if not isinstance(event, dict):
            continue
        content = (event.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            if event.get("type") == "assistant" and block.get("type") == "tool_use" and block.get("name") == "Bash":
                if block.get("id") not in commands:
                    commands[block.get("id")] = str((block.get("input") or {}).get("command") or "")
                    order.append(block.get("id"))
            elif event.get("type") == "user" and block.get("type") == "tool_result":
                results[block.get("tool_use_id")] = _result_text(block)
    counts = {name: 0 for name, _pattern in WRONG_COMMAND_PATTERNS}
    for tool_id in order:
        text = results.get(tool_id, "")
        for name, pattern in WRONG_COMMAND_PATTERNS:
            if pattern.search(text):
                counts[name] += 1
    first_test = next((tool_id for tool_id in order if TEST_COMMAND_WORDS.search(commands[tool_id])), None)
    first_ok = None
    if first_test is not None:
        text = results.get(first_test, "")
        first_ok = not any(pattern.search(text) for _name, pattern in WRONG_COMMAND_PATTERNS)
    return {"wrong_commands": counts, "first_test_command_ok": first_ok, "bash_calls": len(order)}


def run_behaviour(in_dir, rows, tasks, arms, manifest):
    """Turns, wall time, reads, edits, commands, hooks, regressions, lint and conventions per setup."""
    gold = {task.get("task_id"): task.get("gold_files") or [] for task in manifest["tasks"] if isinstance(task, dict)}
    by_setup = {}
    for arm in arms:
        scored = [row for row in rows if row["arm"] == arm and row["status"] != "infra_error"]
        if not scored:
            continue
        wrong = {name: 0 for name, _pattern in WRONG_COMMAND_PATTERNS}
        first_ok = first_seen = transcripts = 0
        hook_events = {}
        changelog_due = changelog_touched = tests_touched = patches = 0
        for row in scored:
            if not _plain_name(row["run_id"]):
                continue
            base = os.path.join(in_dir, "trials", row["run_id"])
            if os.path.isfile(os.path.join(base, "transcript.jsonl")):
                transcripts += 1
                outcome = command_outcomes(os.path.join(base, "transcript.jsonl"))
                for name, value in outcome["wrong_commands"].items():
                    wrong[name] += value
                if outcome["first_test_command_ok"] is not None:
                    first_seen += 1
                    first_ok += int(outcome["first_test_command_ok"])
            try:
                details = read_json(os.path.join(base, "details.json")) or {}
            except ValueError:
                details = {}
            for name, value in (details.get("hook_events") or {}).items():
                hook_events[name] = hook_events.get(name, 0) + int(value or 0)
            paths = _patch_paths(os.path.join(base, "agent.patch"))
            if paths is not None:
                patches += 1
                tests_touched += int(any(_is_test_path(path) for path in paths))
                if any(_is_changelog(path) for path in gold.get(row["task_id"], [])):
                    changelog_due += 1
                    changelog_touched += int(any(_is_changelog(path) for path in paths))
        before = [row.get("turns_before_first_gold_edit") for row in scored]
        by_setup[arm] = {
            "runs": len(scored),
            "turns": _summary([row.get("turns") for row in scored]),
            "agent_wall_seconds": _summary([row.get("wall_seconds") for row in scored]),
            "files_read_outside_the_fix": _summary([row.get("wasted_reads") for row in scored]),
            "turns_before_first_gold_edit": _summary(before),
            "tool_calls_before_first_gold_edit": _summary([row.get("tool_calls_before_first_gold_edit") for row in scored]),
            "runs_without_a_fix_file_edit": sum(1 for value in before if value is None),
            "wrong_commands": wrong,
            "transcripts_read": transcripts,
            "first_test_command_ok": {"runs_with_a_test_command": first_seen, "ok": first_ok},
            "p2p_regressions": sum(int(row.get("p2p_regressions") or 0) for row in scored),
            "runs_with_a_regression": sum(1 for row in scored if int(row.get("p2p_regressions") or 0) > 0),
            "runs_with_new_lint_findings": sum(1 for row in scored if row.get("lint_ok") is False),
            "stop_blocks": sum(int(row.get("hook_blocks") or 0) for row in scored),
            "hook_events": dict(sorted(hook_events.items())),
            "patches_read": patches,
            "runs_that_changed_a_test_file": tests_touched,
            "changelog": {"runs_where_the_real_fix_touched_one": changelog_due, "runs_that_touched_one": changelog_touched},
        }
    return {
        "by_setup": by_setup,
        "notes": {
            "wrong_commands": "tool results of Bash calls matching: command not found; No module named; unknown option or "
                              "unrecognised arguments; a test run that collected 0 tests",
            "first_test_command_ok": "the run's first Bash call naming a test runner gave none of those results",
            "new_lint_findings": "the grader's lint step failed on the agent's patch; T5 required it to pass with the real fix",
        },
    }


def grading_times(in_dir, rows, arms):
    """Grading wall time of the test command and kills at the limit, per setup (review 2, M5)."""
    by_setup = {}
    for arm in arms:
        walls, killed, limits, graded = [], 0, set(), 0
        for row in rows:
            if row["arm"] != arm or row["status"] == "infra_error" or not _plain_name(row["run_id"]):
                continue
            base = os.path.join(in_dir, "trials", row["run_id"])
            wall = os.path.join(base, "test_wall_seconds")
            if not os.path.isfile(wall):
                continue
            graded += 1
            with open(wall, "r", encoding="utf-8", errors="replace") as handle:
                text = handle.read().strip()
            if text.isdigit():
                walls.append(int(text))
            exit_path = os.path.join(base, "test_exit")
            if os.path.isfile(exit_path):
                with open(exit_path, "r", encoding="utf-8", errors="replace") as handle:
                    killed += int(handle.read().strip() == GRADE_KILLED_EXIT)
            try:
                grade = read_json(os.path.join(base, "grade.json")) or {}
            except ValueError:
                grade = {}
            limits.add(grade.get("test_timeout_seconds", 300))
        if graded:
            by_setup[arm] = {"graded_runs": graded, "test_seconds": _summary(walls), "killed_at_limit": killed,
                             "limit_seconds": sorted(limits)}
    return {"by_setup": by_setup,
            "note": "a test command killed at the limit is scored as not solved; protocol 3 grades with a 600 s limit, "
                    "twice the selection limit (change log of 2026-11-11, grading time limit)"}


def subgroups(means, tasks, manifest):
    """The primaries within each language and each toolchain_nondefault value. Never used for the verdict."""
    info = {task.get("task_id"): task for task in manifest["tasks"] if isinstance(task, dict)}
    out = {}
    for key in ("language", "toolchain_nondefault"):
        groups = {}
        for task in tasks:
            value = (info.get(task) or {}).get(key)
            groups.setdefault(json.dumps(value), []).append(task)
        out[key] = {}
        for value, members in sorted(groups.items()):
            comparison = compare_v3(means, members, *PROTOCOL3_PRIMARY)
            out[key][json.loads(value) if value != "null" else "unknown"] = {
                "tasks": members, "tokens": {k: comparison["tokens"][k] for k in ("estimate", "ci95", "sign_flip_p", "tasks_used")},
                "solve_rate": {k: comparison["solve_rate"][k] for k in ("estimate", "ci95", "sign_flip_p", "tasks_used")},
            }
    return out


def pool_record(manifest, tasks):
    selection = manifest["selection"]
    info = {task.get("task_id"): task for task in manifest["tasks"] if isinstance(task, dict)}
    green = [task for task in tasks if (info.get(task) or {}).get("full_suite_green_at_base") is True]
    unknown = [task for task in tasks if not isinstance((info.get(task) or {}).get("full_suite_green_at_base"), bool)]
    return {
        "t4_share": selection.get("t4_share") or "not recorded in the manifest",
        "census_pool": selection.get("census") or "not recorded in the manifest",
        "census_scored_tasks": {"tasks": len(tasks), "full_suite_green_at_base": len(green), "not_recorded": len(unknown)},
        "selection_status": selection.get("status"),
        "manifest_checksum": manifest.get("checksum"),
    }


def attribution(means, tasks, arms, primary, verdict):
    """Whether a passing primary may be credited to the harness's text and hooks (M3)."""
    control = compare_v3(means, tasks, *PROTOCOL3_LEAN_CONTROL) if "none-lean" in arms else None
    credited = {}
    for name, good in (("tokens", "below_null"), ("solve_rate", "above_null")):
        passed = bool(primary[name][good])
        credited[name] = {
            "passes_against_none": passed,
            "passes_against_none_lean": bool(control and control[name][good]),
            "credited_to_text_and_hooks": bool(passed and control and control[name][good]),
        }
    gains = verdict["verdict"] in ("dramatic", "gain_with_accuracy_warning", "measurable")
    configuration = [name for name, item in credited.items() if item["passes_against_none"] and not item["credited_to_text_and_hooks"]]
    wording = None
    if gains and configuration:
        wording = ("a configuration (settings) gain on %s: olivium does not pass against none-lean there, so no wording "
                   "may credit CLAUDE.md or the hooks" % " and ".join(name.replace("_", " ") for name in configuration))
    return {
        "rule": ATTRIBUTION_RULE,
        "olivium_vs_none_lean": control,
        "by_primary": credited,
        "headline_wording": wording,
        "gate1_development_figures": None if control else GATE1_DEVELOPMENT_FIGURES,
    }


def build_results_v3(in_dir, tolerance_points=DEFAULT_TOLERANCE_POINTS, trim_path=None, manifest_path=None,
                     manifest_checksum=None):
    rows = load_trials_v3(in_dir)
    if not manifest_path:
        raise DataError("protocol 3 needs --manifest (the frozen manifest) and --manifest-checksum")
    manifest = load_manifest_v3(manifest_path)
    schedule = read_json(os.path.join(in_dir, "schedule.json"), {}) or {}
    tasks = schedule.get("tasks") or sorted({row["task_id"] for row in rows})
    runs = group_runs(rows)
    origin = detect_origin(in_dir, rows)
    not_scored = scored_problems(in_dir, rows, tasks, manifest, manifest_checksum)
    if not_scored:
        origin["rehearsal"] = True
        origin["reasons"] = origin["reasons"] + ["not a scored v3 OUT: %s" % problem for problem in not_scored]
    arms = [arm for arm in PROTOCOL3_ARMS if any(row["arm"] == arm for row in rows)]
    means = setup_means(runs, tasks, arms)
    primary = compare_v3(means, tasks, *PROTOCOL3_PRIMARY)
    refusals = refusal_counts(rows)
    decided = decide_verdict(primary, refusals, tolerance_points)
    credit = attribution(means, tasks, arms, primary, decided)
    if origin["rehearsal"]:
        # No verdict from anything but a scored v3 OUT on the live meter (review 2, M2).
        verdict = {"verdict": "none", "withheld": True,
                   "reason": "REHEARSAL: %s" % "; ".join(origin["reasons"]),
                   "tolerance_points": tolerance_points, "rehearsal_only": decided}
    else:
        verdict = dict(decided, withheld=False, headline_wording=credit["headline_wording"])
    trim_path = trim_path or os.path.join(in_dir, "trim.json")
    by_status = {arm: {status: sum(1 for row in rows if row["arm"] == arm and row["status"] == status)
                       for status in STATUSES} for arm in arms}
    setups = {}
    for arm in arms:
        present = [means[task][arm] for task in tasks if means[task][arm] is not None]
        setups[arm] = {
            "scored_runs": sum(item["runs"] for item in present),
            "solved": sum(item["solved"] for item in present),
            "tasks": len(present),
            "mean_tokens_per_run": mean_or_none([item["mean_tokens"] for item in present]),
            "mean_turns_per_run": mean_or_none([item["mean_turns"] for item in present]),
            "by_status": by_status[arm],
        }
    results = {
        "protocol": 3,
        "REHEARSAL": origin["rehearsal"],
        "notice": REHEARSAL_TITLE if origin["rehearsal"] else None,
        "rehearsal_reasons": origin["reasons"],
        "design": {
            "primary": "olivium against none: tokens per run (median across tasks of the per-task ratio of "
                       "means, tokens = input + output + cache_creation + cache_read) and solve rate (mean "
                       "across tasks of the per-task difference of solved shares)",
            "passes_when": "the 95%% percentile bootstrap interval excludes the null (1 for a ratio, 0 for a "
                           "difference) and the exact two-sided sign-flip test gives p < %.2f" % ALPHA,
            "sign_flip_statistic": "sum of log ratios (tokens) or of differences (solve rate)",
            "resamples": RESAMPLES,
            "seed": SEED,
            "tolerance_points": tolerance_points,
            "token_tolerance_ratio": TOKEN_TOLERANCE_RATIO,
            "dramatic_token_ratio": DRAMATIC_TOKEN_RATIO,
            "dramatic_solve_points": DRAMATIC_SOLVE_POINTS,
            "excluded_from_scoring": "infra_error rows",
        },
        "tasks": tasks,
        "input": {"dir": os.path.realpath(in_dir), "trial_rows": len(rows), "meter_modes": origin["meter_modes"],
                  "manifest": os.path.realpath(manifest_path), "manifest_checksum": manifest_checksum_v3(manifest),
                  "scored_v3_out": not not_scored, "not_scored_because": not_scored},
        "setups": setups,
        "per_task": means,
        "primary": primary,
        "refusals": refusals,
        "verdict": verdict,
        "attribution": credit,
        "context_use": context_use(in_dir, rows, tasks, arms),
        "secondary": {
            "olivium_vs_generic": compare_v3(means, tasks, *PROTOCOL3_SECONDARY) if "generic" in arms else None,
            "behaviour_only": behaviour_section(means, tasks, primary, trim_path),
            "subagents": subagent_use(in_dir, rows, arms),
            "dollars": dollars_section(rows, means, tasks, arms),
            "none_lean_vs_none": (compare_v3(means, tasks, *PROTOCOL3_LEAN) if "none-lean" in arms else None),
            "deprecation_compliance": deprecation_compliance(in_dir, rows, tasks, arms),
            "behaviour": run_behaviour(in_dir, rows, tasks, arms, manifest),
            "grading_times": grading_times(in_dir, rows, arms),
            "subgroups": subgroups(means, tasks, manifest),
            "pool": pool_record(manifest, tasks),
        },
    }
    return clean(results)


def _ratio_text(entry):
    if entry["estimate"] is None:
        return "n/a"
    return "%.3f (%+.1f%%), 95%% interval %.3f to %.3f, sign-flip p = %.4f, %d tasks" % (
        entry["estimate"], (entry["estimate"] - 1) * 100, entry["ci95"][0], entry["ci95"][1],
        entry["sign_flip_p"], entry["tasks_used"])


def _points_text(entry):
    if entry["estimate"] is None:
        return "n/a"
    return "%+.1f points, 95%% interval %+.1f to %+.1f, sign-flip p = %.4f, %d tasks" % (
        entry["estimate"] * 100, entry["ci95"][0] * 100, entry["ci95"][1] * 100, entry["sign_flip_p"],
        entry["tasks_used"])


REHEARSAL_TITLE_V3 = "REHEARSAL: not a scored v3 result"
REHEARSAL_LINE_V3 = (
    "**REHEARSAL.** This output did not come from a scored protocol 3 run of the frozen manifest on the "
    "live meter, so it carries no verdict. It checks that the analysis machinery works. Do not publish it."
)


def render_report_v3(results):
    lines = []
    if results["REHEARSAL"]:
        if "mock" in results["input"]["meter_modes"] or not results["input"]["meter_modes"]:
            lines += ["# %s" % REHEARSAL_TITLE, "", REHEARSAL_LINE, ""]
        else:
            lines += ["# %s" % REHEARSAL_TITLE_V3, "", REHEARSAL_LINE_V3, ""]
        lines += ["- Why this is marked: %s." % reason for reason in results["rehearsal_reasons"]] + [""]
    verdict = results["verdict"]
    lines += ["# Value benchmark results, protocol 3", ""]
    if verdict["withheld"]:
        lines += ["**No verdict.** %s" % verdict["reason"], "",
                  "The table below shows which rules the rehearsal numbers would meet; it is a check of the "
                  "machinery, not a result.", ""]
        table = verdict["rehearsal_only"]
    else:
        lines += ["**Verdict: %s** (tolerance T = %d points)." % (verdict["verdict"], verdict["tolerance_points"]), ""]
        if verdict.get("headline_wording"):
            lines += ["**Wording:** %s." % verdict["headline_wording"], ""]
        table = verdict
    credit = results["attribution"]
    control = credit["olivium_vs_none_lean"]
    if control:
        lines += ["- Olivium against none-lean (the none setup with only the settings trim): tokens %s; solve rate %s." % (
            _ratio_text(control["tokens"]), _points_text(control["solve_rate"]))]
    else:
        figures = credit["gate1_development_figures"]
        lines += ["- No none-lean runs, so no gain can be credited to the text and hooks. %s: olivium / none %.3f, "
                  "none-lean / none %.3f, olivium / none-lean %.3f, behaviour-only ratio %.3f (medians)." % (
                      figures["source"], figures["olivium_over_none_tokens_median"],
                      figures["none_lean_over_none_tokens_median"], figures["olivium_over_none_lean_tokens_median"],
                      figures["behaviour_only_ratio_median"])]
    lines += ["- %s" % credit["rule"], ""]
    primary = results["primary"]
    lines += ["## Primary outcomes, olivium against none", ""]
    lines += ["- Tokens per run, ratio olivium / none: %s." % _ratio_text(primary["tokens"])]
    lines += ["- Solve rate, olivium minus none: %s." % _points_text(primary["solve_rate"])]
    refusals = results["refusals"]
    lines += ["- Harness refusals in olivium runs: %d in %d runs (limit: %s); Stop blocks: %d. %s." % (
        refusals["refusals"], refusals["runs"], refusals["limit"], refusals["stop_blocks"],
        refusals["counted_as"][0].upper() + refusals["counted_as"][1:])]
    lines += ["", "A primary passes only when both tests agree: %s." % results["design"]["passes_when"], ""]
    lines += ["| Verdict | Rule | Met |", "|---|---|---|"]
    for item in table["table"]:
        lines.append("| %s | %s | %s |" % (item["verdict"], item["rule"], "yes" if item["met"] else "no"))
    lines += ["", "The verdict is %s." % table["order"], ""]
    context = results["context_use"]
    lines += ["## Context use (named secondary outcomes)", "",
              "| Setup | Runs | First request, mean | Before first fix-file edit, mean | Never edited | Largest context, mean | Warm starts |",
              "|---|---|---|---|---|---|---|"]
    for arm, item in context["by_setup"].items():
        lines.append("| %s | %d | %s | %s | %d | %s | %d |" % (
            arm, item["runs"], fmt_value("tokens", item["first_request_tokens"]["mean"]),
            fmt_value("tokens", item["tokens_before_first_gold_edit"]["mean"]), item["runs_that_never_edited_a_fix_file"],
            fmt_value("tokens", item["largest_context"]["mean"]), item["warm_starts"]))
    lines += [""]
    for field, entry in context["olivium_over_none"].items():
        lines.append("- olivium / none, %s: %s." % (field.replace("_", " "), _ratio_text(entry)))
    lines += [""] + ["- %s: %s." % (name.replace("_", " ").capitalize(), text) for name, text in context["definitions"].items()]
    lines += [""]
    lines += ["## Setups", "", "| Setup | Tasks | Scored runs | Solved | Mean tokens per run | Mean turns per run |",
              "|---|---|---|---|---|---|"]
    for arm, item in results["setups"].items():
        lines.append("| %s | %d | %d | %d | %s | %s |" % (
            arm, item["tasks"], item["scored_runs"], item["solved"],
            fmt_value("tokens", item["mean_tokens_per_run"]), fmt_value("count", item["mean_turns_per_run"])))
    secondary = results["secondary"]
    lines += ["", "## Secondary", ""]
    generic = secondary["olivium_vs_generic"]
    if generic:
        lines += ["- Olivium against /init (generic): tokens %s; solve rate %s." % (
            _ratio_text(generic["tokens"]), _points_text(generic["solve_rate"]))]
    behaviour = secondary["behaviour_only"]
    if behaviour["available"]:
        lines += ["- Behaviour-only ratio, (olivium tokens + trim x olivium turns) / none tokens: %s." % _ratio_text(behaviour["by_turns"])]
        lines += ["- The same with requests instead of turns (sensitivity): %s." % _ratio_text(behaviour["by_requests_sensitivity"])]
        if behaviour["configuration_share_of_saving"] is not None:
            lines += ["- Share of the token saving that is configuration: %.0f%% %s." % (
                behaviour["configuration_share_of_saving"] * 100, behaviour["configuration_share_note"])]
    else:
        lines += ["- Behaviour-only ratio: not available (%s)." % behaviour["reason"]]
    lean = secondary["none_lean_vs_none"]
    if lean:
        lines += ["- none-lean against none (unscored setup, 1 repeat per task): tokens %s; solve rate %s." % (
            _ratio_text(lean["tokens"]), _points_text(lean["solve_rate"]))]
    pool = secondary["pool"]
    share = pool["t4_share"]
    if isinstance(share, dict):
        lines += ["- T4 rejection share: %d of %d candidates that reached T4 (%s)." % (
            share.get("rejected_by_t4", 0), share.get("reached_t4", 0),
            "n/a" if share.get("share") is None else "%.1f%%" % (share["share"] * 100))]
    else:
        lines += ["- T4 rejection share: %s." % share]
    census = pool["census_scored_tasks"]
    lines += ["- Full-suite census: %d of %d scored tasks have every other test passing at the base commit "
              "(not recorded for %d)." % (census["full_suite_green_at_base"], census["tasks"], census["not_recorded"])]
    lines += ["", "### Subgroups (never used for the verdict)", "",
              "| Group | Value | Tasks | Tokens olivium / none | Solve rate olivium - none |", "|---|---|---|---|---|"]
    for key, groups in secondary["subgroups"].items():
        for value, item in groups.items():
            tokens, solve = item["tokens"], item["solve_rate"]
            lines.append("| %s | %s | %d | %s | %s |" % (
                key, value, len(item["tasks"]),
                "n/a" if tokens["estimate"] is None else "%.3f (p %.3f)" % (tokens["estimate"], tokens["sign_flip_p"]),
                "n/a" if solve["estimate"] is None else "%+.1f points (p %.3f)" % (solve["estimate"] * 100, solve["sign_flip_p"])))
    behaviour_rows = secondary["behaviour"]["by_setup"]
    lines += ["", "### Behaviour per setup", "",
              "| Setup | Runs | Turns, mean | Agent wall s, mean | Reads outside fix, mean | Turns before fix edit, mean | No fix edit | Wrong commands | First test command ok | Regressions (runs) | New lint findings | Stop blocks | Test file changed | Changelog touched / due |",
              "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for arm, item in behaviour_rows.items():
        lines.append("| %s | %d | %s | %s | %s | %s | %d | %d | %d of %d | %d (%d) | %d | %d | %d of %d | %d / %d |" % (
            arm, item["runs"], fmt_value("count", item["turns"]["mean"]), fmt_value("count", item["agent_wall_seconds"]["mean"]),
            fmt_value("count", item["files_read_outside_the_fix"]["mean"]), fmt_value("count", item["turns_before_first_gold_edit"]["mean"]),
            item["runs_without_a_fix_file_edit"], sum(item["wrong_commands"].values()),
            item["first_test_command_ok"]["ok"], item["first_test_command_ok"]["runs_with_a_test_command"],
            item["p2p_regressions"], item["runs_with_a_regression"], item["runs_with_new_lint_findings"], item["stop_blocks"],
            item["runs_that_changed_a_test_file"], item["patches_read"],
            item["changelog"]["runs_that_touched_one"], item["changelog"]["runs_where_the_real_fix_touched_one"]))
    times = secondary["grading_times"]
    lines += ["", "### Grading time of the test command", "", "| Setup | Graded runs | Median s | Max s | Killed at the limit | Limit s |",
              "|---|---|---|---|---|---|"]
    for arm, item in times["by_setup"].items():
        lines.append("| %s | %d | %s | %s | %d | %s |" % (
            arm, item["graded_runs"], fmt_value("count", item["test_seconds"]["median"]), fmt_value("count", item["test_seconds"]["max"]),
            item["killed_at_limit"], ", ".join(str(value) for value in item["limit_seconds"])))
    lines += ["", times["note"] + "."]
    lines += ["", "### Subagent use", "", "| Setup | Runs | Runs with a subagent | Subagent calls | Subagent tokens per run |",
              "|---|---|---|---|---|"]
    for arm, item in secondary["subagents"]["by_setup"].items():
        lines.append("| %s | %d | %d | %d | %s |" % (arm, item["runs"], item["runs_with_subagent"], item["subagent_calls"],
                                                     fmt_value("tokens", item["subagent_tokens_per_run"])))
    lines += ["", secondary["subagents"]["note"], "", "### Dollars", "",
              "| Setup | Runs | Mean cost per run | Cache-read share of tokens | Dollars per million tokens |",
              "|---|---|---|---|---|"]
    for arm, item in secondary["dollars"]["by_setup"].items():
        share = item["cache_read_share_of_tokens"]
        lines.append("| %s | %d | %s | %s | %s |" % (
            arm, item["runs"], fmt_value("usd", item["mean_cost_usd"]),
            "n/a" if share is None else "%.1f%%" % (share * 100), fmt_value("usd", item["usd_per_million_tokens"])))
    lines += ["", "Cost ratio olivium / none: %s." % _ratio_text(secondary["dollars"]["olivium_over_none_cost_ratio"]),
              "", secondary["dollars"]["note"], "", "### Deprecation compliance", ""]
    compliance = secondary["deprecation_compliance"]
    if not compliance["tasks_where_rule_fired"]:
        lines.append("The deprecation rule was not shown in any task's olivium export, so there is nothing to report.")
    else:
        lines += ["Tasks where %s; %s." % (compliance["rule"], compliance["classifier"]), "",
                  "| Task | Setup | Runs | Removed without warning | Removed with warning | Kept with warning | No removal | No patch |",
                  "|---|---|---|---|---|---|---|---|"]
        for task, arms in compliance["by_task"].items():
            for arm, counts in arms.items():
                lines.append("| %s | %s | %d | %d | %d | %d | %d | %d |" % (
                    task, arm, counts["runs"], counts["removed_without_warning"], counts["removed_with_warning"],
                    counts["kept_with_warning"], counts["no_removal"], counts["no_patch"]))
    lines.append("")
    return "\n".join(lines)


def write_outputs_v3(results, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "report.md"), "w", encoding="utf-8") as handle:
        handle.write(render_report_v3(results))
    with open(os.path.join(out_dir, "results.json"), "w", encoding="utf-8") as handle:
        json.dump(results, handle, indent=2, sort_keys=False, ensure_ascii=False)
        handle.write("\n")


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--in", dest="in_dir", required=True, help="run.py output directory")
    parser.add_argument("--out", required=True, help="directory for results.json, report.md and SVG charts")
    parser.add_argument("--manifest", help="protocol 2: the manifest with held_out flags (enables the held-out and before/after sections); "
                                           "protocol 3: the frozen manifest (required)")
    parser.add_argument("--manifest-checksum",
                        help="protocol 3 (required): the frozen manifest's checksum as recorded in the PROTOCOL-v3.md change "
                             "log; any other manifest, a pilot, or an OUT not written by the protocol 3 runner gives no verdict")
    parser.add_argument("--pilot-results", help="protocol 2: the pilot results.json for the before and after comparison")
    parser.add_argument("--protocol", choices=("1", "2", "3"),
                        help="3: the protocol 3 analysis (ratio and solve-rate primaries, both tests, verdict); "
                             "1 and 2 (or no flag) keep the earlier analysis unchanged")
    parser.add_argument("--tolerance-points", type=int, default=DEFAULT_TOLERANCE_POINTS,
                        help="protocol 3: solve-rate tolerance T in points (default %d)" % DEFAULT_TOLERANCE_POINTS)
    parser.add_argument("--trim", help="protocol 3: the per-task trim file (default OUT/trim.json)")
    args = parser.parse_args(argv)
    if args.protocol == "3":
        return main_v3(parser, args)
    if args.manifest_checksum:
        parser.error("--manifest-checksum is protocol 3 only")
    try:
        results = build_results(args.in_dir, args.manifest, args.pilot_results)
    except DataError as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 3
    write_outputs(results, args.out)
    if results["REHEARSAL"]:
        print("REHEARSAL: outputs stamped (%s)" % "; ".join(results["rehearsal_reasons"]))
    print("wrote %s" % os.path.realpath(args.out))
    return 0


def main_v3(parser, args):
    if args.pilot_results:
        parser.error("--pilot-results belongs to protocol 2")
    if not args.manifest or not args.manifest_checksum:
        parser.error("protocol 3 needs --manifest (the frozen manifest) and --manifest-checksum (its checksum from the "
                     "PROTOCOL-v3.md change log)")
    if not re.match(r"^[0-9a-f]{64}$", args.manifest_checksum):
        parser.error("--manifest-checksum must be 64 lower-case hex digits")
    if not 0 <= args.tolerance_points <= 100:
        parser.error("--tolerance-points must be between 0 and 100")
    try:
        results = build_results_v3(args.in_dir, args.tolerance_points, args.trim, args.manifest, args.manifest_checksum)
    except DataError as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 3
    write_outputs_v3(results, args.out)
    if results["REHEARSAL"]:
        print("REHEARSAL: outputs stamped (%s)" % "; ".join(results["rehearsal_reasons"]))
    if results["verdict"]["withheld"]:
        print("verdict: none (REHEARSAL, not a scored v3 result)")
    else:
        print("verdict: %s" % results["verdict"]["verdict"])
        if results["verdict"].get("headline_wording"):
            print("wording: %s" % results["verdict"]["headline_wording"])
    print("wrote %s" % os.path.realpath(args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
