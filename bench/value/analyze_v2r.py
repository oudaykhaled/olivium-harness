#!/usr/bin/env python3
"""Analysis of the v2r re-run (PROTOCOL-v2r.md, "Metrics and analysis"). Standard library only.

  python3 bench/value/analyze_v2r.py --in OUT --out DIR

OUT is the run.py output directory of `run --protocol 2 --arms none,generic,olivium,olivium-nn`.
DIR receives results.json and report.md. The statistics are analyze.py's, unchanged: per task the
mean of the scored runs of each arm, the per-task difference, the median across tasks and a
percentile bootstrap 95% interval of that median (10,000 resamples, seed 20261108, tasks resampled
with replacement). This script only sets the four arms, the three primary comparisons and the
added metrics, and adds the protocol's checks (version, model, infra errors, stop rules).

An input is real only when analyze.detect_origin finds every run in the live meter log and no
setup made from a rehearsal fixture; otherwise every output is stamped REHEARSAL.
"""

import argparse
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import analyze as A  # noqa: E402

ARMS = ("none", "generic", "olivium", "olivium-nn")
PRIMARY = (("olivium", "none"), ("olivium", "olivium-nn"), ("olivium", "generic"))
PRIMARY_METRICS = ("total_tokens", "cost_usd", "solved")
CLAUDE_CODE_VERSION = "2.1.311"
MODEL = "claude-sonnet-5-5"
SCHEDULED_RUNS = 96
INFRA_LIMIT_SHARE = 0.10
TOTAL_CAP_USD = 15.0
DEVELOPMENT_STATEMENT = (
    "These are development tasks: the generator was changed while looking at results on these same 8 tasks "
    "(including the three pallets/werkzeug tasks), so no task here is held out. The result can show a direction "
    "or a problem on tasks the generator was tuned on; it cannot show a gain on unseen repositories."
)


def _total_tokens(row):
    tokens = row.get("tokens") or {}
    parts = [tokens.get(name) for name in ("input", "output", "cache_creation", "cache_read")]
    return None if any(part is None for part in parts) else float(sum(parts))


def _tool_count(*names):
    def read(row):
        calls = row.get("tool_calls") or {}
        return float(sum(int(calls.get(name) or 0) for name in names))
    return read


def _field(name):
    def read(row):
        value = row.get(name)
        return None if value is None else float(value)
    return read


EXTRA_METRICS = (
    ("total_tokens", "Total tokens per run", "tokens", "lower", "fewer_tokens", _total_tokens),
    ("turns", "Turns per run", "count", "lower", "fewer_tokens", _field("turns")),
    ("permission_denials", "Permission denials per run", "count", "lower", "more_accurate", _field("permission_denials")),
    ("hook_blocks", "Stop-hook blocks per run", "count", "lower", "more_accurate", _field("hook_blocks")),
    ("skill_calls", "Skill tool calls per run", "count", "none", "native", _tool_count("Skill")),
    ("agent_calls", "Agent/Task tool calls per run", "count", "none", "native", _tool_count("Agent", "Task")),
)


def configure():
    """analyze.py reads these module globals at call time."""
    A.ARMS = ARMS
    A.COMPARISONS = PRIMARY
    if not any(metric[0] == "total_tokens" for metric in A.METRICS):
        A.METRICS = tuple(A.METRICS) + EXTRA_METRICS
    A.METRIC_BY_KEY = {metric[0]: metric for metric in A.METRICS}


def find_schedule(in_dir):
    for path in sorted(glob.glob(os.path.join(in_dir, "schedule*.json"))):
        data = A.read_json(path, {}) or {}
        if tuple(data.get("arms") or ()) == ARMS:
            return path, data
    return None, {}


def protocol_checks(in_dir, rows, schedule):
    scored = [row for row in rows if row["status"] != "infra_error"]
    wrong_version = sorted(row["run_id"] for row in scored if row.get("claude_code_version") != CLAUDE_CODE_VERSION)
    wrong_model = sorted(row["run_id"] for row in scored if row.get("model") != MODEL)
    infra = [row["run_id"] for row in rows if row["status"] == "infra_error"]
    scheduled = len(schedule.get("order") or []) or SCHEDULED_RUNS
    web = sorted(row["run_id"] for row in rows if int(row.get("web_tool_uses") or 0) > 0)
    meter_rows = A.read_jsonl(os.path.join(in_dir, "meter", "requests.jsonl"))
    meter_total = sum(int(row.get("cost_nanousd") or 0) for row in meter_rows) / 1e9
    return {
        "claude_code_version_expected": CLAUDE_CODE_VERSION,
        "runs_on_another_version": wrong_version,
        "model_expected": MODEL,
        "runs_on_another_model": wrong_model,
        "scheduled_runs": scheduled,
        "infra_error_rows": len(infra),
        "infra_error_limit": int(scheduled * INFRA_LIMIT_SHARE),
        "infra_error_limit_passed": len(infra) > int(scheduled * INFRA_LIMIT_SHARE),
        "runs_with_web_tool_uses": web,
        "meter_rows": len(meter_rows),
        "meter_total_usd": round(meter_total, 6),
        "total_cap_usd": TOTAL_CAP_USD,
        "total_cap_passed": meter_total > TOTAL_CAP_USD,
    }


def build(in_dir):
    configure()
    rows = A.load_trials(in_dir)
    schedule_path, schedule = find_schedule(in_dir)
    tasks = schedule.get("tasks") or sorted({row["task_id"] for row in rows})
    expected_repeats = schedule.get("repeats") or 3
    runs = A.group_runs(rows)
    origin = A.detect_origin(in_dir, rows)
    setup = A.load_setup(in_dir, tasks)
    values = A.task_values(runs, tasks)
    comparisons = A.compare(values, tasks)
    totals = A.arm_totals(values, tasks, rows, setup)
    for arm in ARMS:
        arm_rows = [row for task in tasks for row in runs.get(task, {}).get(arm, {}).values()]
        tokens = [_total_tokens(row) for row in arm_rows if _total_tokens(row) is not None]
        totals[arm]["total_tokens"] = sum(tokens)
        totals[arm]["median_total_tokens_per_run"] = A.median(tokens) if tokens else None
        totals[arm]["median_cost_per_run_usd"] = A.median([float(row["cost_usd"]) for row in arm_rows]) if arm_rows else None
        totals[arm]["skill_calls"] = sum(_tool_count("Skill")(row) for row in arm_rows)
        totals[arm]["agent_calls"] = sum(_tool_count("Agent", "Task")(row) for row in arm_rows)
        totals[arm]["runs_using_skill_or_agent"] = sum(
            1 for row in arm_rows if _tool_count("Skill", "Agent", "Task")(row) > 0)
    missing = [{"task_id": task, "arm": arm, "repeat": repeat}
               for task in tasks for arm in ARMS for repeat in range(1, expected_repeats + 1)
               if repeat not in runs.get(task, {}).get(arm, {})]
    native = {}
    for task in tasks:
        record = A.read_json(os.path.join(in_dir, "arms", task, "olivium.setup.json"), {}) or {}
        files = record.get("harness_files") or []
        native[task] = {
            "skills": sorted({path.split("/")[2] for path in files if path.startswith(".claude/skills/") and path.count("/") >= 3}),
            "agents": sorted(os.path.basename(path)[:-3] for path in files
                             if path.startswith(".claude/agents/") and path.endswith(".md")),
        }
    results = {
        "REHEARSAL": origin["rehearsal"],
        "notice": A.REHEARSAL_TITLE if origin["rehearsal"] else None,
        "rehearsal_reasons": origin["reasons"],
        "protocol": "PROTOCOL-v2r.md",
        "development_tasks": DEVELOPMENT_STATEMENT,
        "design": {
            "arms": list(ARMS),
            "primary_comparisons": ["%s - %s" % pair for pair in PRIMARY],
            "primary_metrics": list(PRIMARY_METRICS),
            "repeats_expected": expected_repeats,
            "interval": "percentile bootstrap 95% of the median, resampling tasks",
            "resamples": A.RESAMPLES,
            "seed": A.SEED,
        },
        "tasks": tasks,
        "input": {
            "trial_rows": len(rows),
            "schedule_file": os.path.basename(schedule_path) if schedule_path else None,
            "by_status": {status: sum(1 for row in rows if row["status"] == status) for status in A.STATUSES},
            "missing_repeats": missing,
            "meter_modes": origin["meter_modes"],
        },
        "checks": protocol_checks(in_dir, rows, schedule),
        "setup": setup,
        "native_in_olivium_export": native,
        "arms": totals,
        "per_task": values,
        "comparisons": comparisons,
    }
    return A.clean(results)


def report(results):
    lines = []
    if results["REHEARSAL"]:
        lines += ["# %s" % A.REHEARSAL_TITLE, "", A.REHEARSAL_LINE, ""]
        lines += ["Reasons: %s" % "; ".join(results["rehearsal_reasons"]), ""]
    lines += ["# Value benchmark v2r: results", "", "> " + results["development_tasks"], ""]
    lines += ["## Per arm", "", "| Arm | Scored runs | Solved | Total cost | Median cost per run | Median tokens per run | Skill calls | Agent calls |",
              "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for arm in ARMS:
        t = results["arms"][arm]
        lines.append("| `%s` | %d | %d | %s | %s | %s | %d | %d |" % (
            arm, t["scored_runs"], t["solved"], A.fmt_value("usd", t["total_cost_usd"]),
            A.fmt_value("usd", t["median_cost_per_run_usd"]), A.fmt_value("tokens", t["median_total_tokens_per_run"]),
            t["skill_calls"], t["agent_calls"]))
    lines += ["", "## Primary comparisons", "",
              "Median per-task difference (treated minus baseline) and 95% bootstrap interval across tasks.", "",
              "| Comparison | Total tokens per run | Cost per run | Solved share |", "| --- | --- | --- | --- |"]
    for treated, baseline in PRIMARY:
        key = "%s_minus_%s" % (treated, baseline)
        cells = [A.interval_text(A.METRIC_BY_KEY[name][2], results["comparisons"][key][name]) for name in PRIMARY_METRICS]
        lines.append("| `%s` − `%s` | %s |" % (treated, baseline, " | ".join(cells)))
    lines += ["", "An interval that includes zero is a difference these data cannot tell from no effect.", ""]
    lines += ["## Setup cost", ""]
    for arm in ARMS:
        lines.append("- `%s`: %s" % (arm, A.fmt_value("usd", results["setup"][arm]["cost_usd"])))
    checks = results["checks"]
    lines += ["", "## Protocol checks", "",
              "- Runs on another Claude Code version: %d; on another model: %d." % (
                  len(checks["runs_on_another_version"]), len(checks["runs_on_another_model"])),
              "- infra_error rows: %d (stop limit: more than %d)." % (checks["infra_error_rows"], checks["infra_error_limit"]),
              "- Meter: %d rows, %s (cap %s)." % (checks["meter_rows"], A.fmt_value("usd", checks["meter_total_usd"]),
                                                  A.fmt_value("usd", checks["total_cap_usd"])),
              "- Missing repeats: %d." % len(results["input"]["missing_repeats"]), ""]
    return "\n".join(lines) + "\n"


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--in", dest="in_dir", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    try:
        results = build(args.in_dir)
    except A.DataError as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 3
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "results.json"), "w", encoding="utf-8") as handle:
        json.dump(results, handle, indent=2, sort_keys=True)
        handle.write("\n")
    with open(os.path.join(args.out, "report.md"), "w", encoding="utf-8") as handle:
        handle.write(report(results))
    print("%s: %d rows; %s" % ("REHEARSAL" if results["REHEARSAL"] else "LIVE", results["input"]["trial_rows"],
                               os.path.join(args.out, "report.md")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
