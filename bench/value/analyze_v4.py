#!/usr/bin/env python3
"""v4 development rehearsal analysis (PROTOCOL-v4dev.md). Standard library only.

    python3 -I bench/value/analyze_v4.py --out OUT --report REPORT.json [--manifest PATH] [--md REPORT.md]

Reads a protocol-2 OUT (trials.jsonl, trials/<run_id>/{transcript.jsonl,meter_rows.jsonl},
arms/<task>/<arm>.setup.json, meter/requests.jsonl). Reads data only; executes nothing.

- Tokens per run = input + output + cache_creation + cache_read of the trial row
  (the meter's messages rows), as in Gate 1.
- Task-balanced mean: per task the mean over its scored repeats, then the mean over the
  tasks scored in both compared arms.
- Comparisons: olivium-ai vs none-lean (primary), olivium vs none-lean, olivium-ai vs
  olivium, olivium-det vs olivium-ai (ablation), each when both arms have scored runs.
- Decision rule (design.md 6.2, on the harder tasks): continue if the token ratio
  olivium-ai/none-lean is at most 0.80, or the solve rate is at least 15 points higher
  with the ratio at most 1.0. Otherwise stop or redesign. Development numbers are never
  evidence of value.
- An OUT with any mock meter row, rehearsal setup or mock bundle is stamped MOCK and gets
  no decision.
"""

import argparse
import json
import os
import re
import statistics
import sys

ANALYSIS_ID = "analyze-v4/1"
CARD_PREFIX = "Olivium locator (learned from this repository's history; check before relying on it):"
REWRITE_RE = re.compile(r"^olivium: (ran |\S+ is not installed here)")
MISSING_RE = re.compile(r"command not found|: not found|Failed to spawn|No module named|is not installed|"
                        r"executable file not found|No such file or directory \(os error")
EXIT_RE = re.compile(r"^Exit code ([0-9]+)")
TEST_RE = re.compile(r"(pytest|py\.test|\btox\b|\bnox\b|npm (run )?test|npx (mocha|jest|vitest)|mocha|jest|vitest|"
                     r"unittest|node_modules/\.bin/(mocha|vitest|jest))")
ARMS_ORDER = ("none", "none-lean", "olivium", "olivium-det", "olivium-ai")
PAIRS = (("olivium-ai", "none-lean", "primary"), ("olivium", "none-lean", "reference"),
         ("olivium-ai", "olivium", "information"), ("olivium-det", "olivium-ai", "ablation"),
         ("none-lean", "none", "trim"))
TOKEN_FIELDS = ("input", "output", "cache_creation", "cache_read")
DECISION = {"continue_if_token_ratio_at_most": 0.80, "or_solve_points_at_least": 15.0, "with_token_ratio_at_most": 1.0}
TARGET = {"token_ratio_at_most": 0.75, "solve_points_at_least": 20.0, "other_within_points": 10.0}


# ------------------------------------------------------------------ reading
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
                continue
    return rows


def read_json(path, default=None):
    if not os.path.exists(path):
        return default
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def text_of(content):
    if isinstance(content, str):
        return content
    parts = []
    if isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text" and isinstance(block.get("text"), str):
                parts.append(block["text"])
    return "".join(parts)


def main_model(rows):
    models = [row.get("model") for row in rows if row.get("endpoint") == "messages" and row.get("model")]
    if not models:
        return None
    return max(sorted(set(models)), key=models.count)


def main_rows(rows):
    """The main session's messages rows in seq order (background calls on another model left out)."""
    model = main_model(rows)
    kept = [row for row in rows if row.get("endpoint") == "messages" and row.get("model") == model
            and row.get("mock_kind") != "background"]
    return sorted(kept, key=lambda row: int(row.get("seq") or 0))


def row_tokens(row):
    return int(row.get("input_tokens") or 0) + int(row.get("output_tokens") or 0) + \
        int(row.get("cache_creation_input_tokens") or 0) + int(row.get("cache_read_input_tokens") or 0)


def prompt_tokens(row):
    return int(row.get("input_tokens") or 0) + int(row.get("cache_creation_input_tokens") or 0) + \
        int(row.get("cache_read_input_tokens") or 0)


def parse_transcript(path, gold_files):
    """Tool calls, hook events and the request index of each call, from a stream-json transcript."""
    calls = {}
    order = []
    message_ids = []
    cards = []
    rewrite_hooks = 0
    for event in read_jsonl(path):
        kind = event.get("type")
        if kind == "system" and event.get("subtype") == "hook_response":
            output = event.get("output") if isinstance(event.get("output"), str) else (event.get("stdout") or "")
            hook = event.get("hook_event") or event.get("hook_name")
            if hook == "UserPromptSubmit" and output.startswith(CARD_PREFIX):
                cards.append(output)
            if hook == "PreToolUse" and '"updatedInput"' in output:
                rewrite_hooks += 1
        elif kind == "assistant":
            message = event.get("message") or {}
            mid = message.get("id")
            if mid and mid not in message_ids:
                message_ids.append(mid)
            for block in message.get("content") or []:
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    calls[block.get("id")] = {"tool": block.get("name"), "input": block.get("input") or {},
                                              "request": message_ids.index(mid) + 1 if mid in message_ids else None}
                    order.append(block.get("id"))
        elif kind == "user":
            content = (event.get("message") or {}).get("content")
            if not isinstance(content, list):
                continue
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_result" and block.get("tool_use_id") in calls:
                    call = calls[block["tool_use_id"]]
                    out = text_of(block.get("content"))
                    call["out_bytes"] = len(out.encode("utf-8"))
                    call["is_error"] = bool(block.get("is_error"))
                    call["head"] = out[:400]
    gold = set(gold_files or [])
    first_gold_edit = None
    failed = 0
    test_bytes = 0
    rewrites_seen = 0
    for cid in order:
        call = calls[cid]
        tool = call["tool"]
        head = call.get("head", "")
        if tool == "Bash":
            command = str(call["input"].get("command") or "")
            match = EXIT_RE.match(head)
            if call.get("is_error") or (match and match.group(1) != "0") or MISSING_RE.search(head):
                failed += 1
            if TEST_RE.search(command):
                test_bytes += call.get("out_bytes", 0)
            if REWRITE_RE.match(head):
                rewrites_seen += 1
        elif call.get("is_error"):
            failed += 1
        if tool in ("Edit", "Write", "MultiEdit") and first_gold_edit is None:
            path = str(call["input"].get("file_path") or "")
            rel = path[len("/work/repo/"):] if path.startswith("/work/repo/") else path
            if rel in gold:
                first_gold_edit = call["request"]
    hits = [any(path in card for path in gold) for card in cards]
    return {
        "tool_calls": len(order),
        "assistant_messages": len(message_ids),
        "failed_calls": failed,
        "test_output_bytes": test_bytes,
        "cards_shown": len(cards),
        "card_bytes": [len(card.encode("utf-8")) for card in cards],
        "card_gold_hit": hits,
        "rewrite_hooks_fired": rewrite_hooks,
        "rewritten_outputs_seen": rewrites_seen,
        "first_gold_edit_request": first_gold_edit,
    }


# ------------------------------------------------------------------ runs
def scored_rows(out):
    """One scored row per (task, arm, repeat): the row that is not infra_error."""
    chosen = {}
    attempts = {}
    for row in read_jsonl(os.path.join(out, "trials.jsonl")):
        key = (row.get("task_id"), row.get("arm"), row.get("repeat"))
        attempts[key] = attempts.get(key, 0) + 1
        if row.get("status") != "infra_error":
            chosen[key] = row
    return chosen, attempts


def run_metrics(out, row, gold_files):
    run_dir = os.path.join(out, "trials", row["run_id"])
    meter = read_jsonl(os.path.join(run_dir, "meter_rows.jsonl"))
    mains = main_rows(meter)
    trace = parse_transcript(os.path.join(run_dir, "transcript.jsonl"), gold_files)
    tokens = sum(int((row.get("tokens") or {}).get(field) or 0) for field in TOKEN_FIELDS)
    before = None
    if trace["first_gold_edit_request"] is not None and mains:
        before = sum(row_tokens(item) for item in mains[:trace["first_gold_edit_request"]])
    return {
        "run_id": row["run_id"],
        "task_id": row["task_id"],
        "arm": row["arm"],
        "repeat": row["repeat"],
        "status": row.get("status"),
        "solved": bool(row.get("solved")),
        "tokens": tokens,
        "cost_usd": float(row.get("cost_usd") or 0.0),
        "requests": int(row.get("requests") or 0),
        "main_requests": len(mains),
        "first_request_tokens": prompt_tokens(mains[0]) if mains else None,
        "tokens_before_first_gold_edit": before,
        "budget_exhausted": row.get("status") == "budget_exhausted",
        **{key: trace[key] for key in ("tool_calls", "failed_calls", "test_output_bytes", "cards_shown", "card_bytes",
                                       "card_gold_hit", "rewrite_hooks_fired", "rewritten_outputs_seen",
                                       "first_gold_edit_request")},
    }


# ------------------------------------------------------------------ statistics
def mean(values):
    values = [v for v in values if v is not None]
    return (sum(values) / len(values)) if values else None


def per_task(runs, arm, key):
    """{task: mean over that task's scored repeats} for one arm and metric."""
    table = {}
    for run in runs:
        if run["arm"] != arm:
            continue
        value = run[key]
        if isinstance(value, bool):
            value = 1.0 if value else 0.0
        table.setdefault(run["task_id"], []).append(value)
    return {task: mean(values) for task, values in table.items() if mean(values) is not None}


def balanced(runs, arm, other, key, tasks=None):
    """Task-balanced means of key for arm and other over the tasks both have."""
    a = per_task(runs, arm, key)
    b = per_task(runs, other, key)
    common = sorted(set(a) & set(b) & (set(tasks) if tasks is not None else set(a)))
    if not common:
        return None, None, []
    return mean([a[t] for t in common]), mean([b[t] for t in common]), common


def compare(runs, arm, other, tasks=None):
    tok_a, tok_b, common = balanced(runs, arm, other, "tokens", tasks)
    if not common:
        return None
    result = {"arm": arm, "against": other, "tasks": common, "n_tasks": len(common)}
    for key in ("tokens", "solved", "requests", "main_requests", "first_request_tokens", "tokens_before_first_gold_edit",
                "failed_calls", "test_output_bytes", "cost_usd", "tool_calls"):
        a, b, both = balanced(runs, arm, other, key, common)
        result[key] = {"arm": _r(a), "against": _r(b), "tasks": len(both)}
    result["token_ratio"] = _r(tok_a / tok_b) if tok_b else None
    ratios = []
    a_tok = per_task(runs, arm, "tokens")
    b_tok = per_task(runs, other, "tokens")
    for task in common:
        if b_tok[task]:
            ratios.append(a_tok[task] / b_tok[task])
    result["per_task_token_ratio"] = {task: _r(a_tok[task] / b_tok[task]) for task in common if b_tok[task]}
    result["median_task_token_ratio"] = _r(statistics.median(ratios)) if ratios else None
    sa, sb = result["solved"]["arm"], result["solved"]["against"]
    result["solve_points"] = _r((sa - sb) * 100.0) if sa is not None and sb is not None else None
    # Configuration (what the prefix adds on every request) apart from behaviour (the rest).
    fa, fb = result["first_request_tokens"]["arm"], result["first_request_tokens"]["against"]
    ra = result["main_requests"]["arm"]
    if fa is not None and fb is not None and ra is not None and tok_a is not None and tok_b is not None:
        config = (fa - fb) * ra
        result["delta_tokens"] = {"total": _r(tok_a - tok_b), "configuration_prefix": _r(config),
                                  "behaviour": _r(tok_a - tok_b - config)}
    return result


def _r(value, digits=4):
    return None if value is None else round(float(value), digits)


def decision(cmp, complete):
    if cmp is None:
        return {"decision": None, "why": "no olivium-ai and none-lean runs on the same harder tasks"}
    if not complete:
        return {"decision": "incomplete", "why": "a scheduled run is missing or was stopped by a budget"}
    ratio, points = cmp["token_ratio"], cmp["solve_points"]
    if ratio is not None and ratio <= DECISION["continue_if_token_ratio_at_most"]:
        return {"decision": "continue", "why": "token ratio %.3f <= %.2f" % (ratio, DECISION["continue_if_token_ratio_at_most"])}
    if points is not None and ratio is not None and points >= DECISION["or_solve_points_at_least"] and ratio <= DECISION["with_token_ratio_at_most"]:
        return {"decision": "continue", "why": "solve rate +%.1f points with token ratio %.3f" % (points, ratio)}
    return {"decision": "stop_or_redesign", "why": "token ratio %s, solve points %s" % (ratio, points)}


def target(cmp):
    if cmp is None:
        return None
    ratio, points = cmp["token_ratio"], cmp["solve_points"]
    tokens_met = ratio is not None and ratio <= TARGET["token_ratio_at_most"] and points is not None and points >= -TARGET["other_within_points"]
    solve_met = points is not None and points >= TARGET["solve_points_at_least"] and ratio is not None and ratio <= 1 + TARGET["other_within_points"] / 100.0
    return {"tokens_route_met": tokens_met, "solve_route_met": solve_met, "rule": TARGET}


# ------------------------------------------------------------------ learning
def learning_table(out, tasks):
    table = {}
    for task_id in tasks:
        for arm in ("olivium-ai", "olivium-det"):
            setup = read_json(os.path.join(out, "arms", task_id, "%s.setup.json" % arm))
            if not setup:
                continue
            learning = setup.get("learning") or {}
            tokens = learning.get("tokens") or {}
            table.setdefault(task_id, {})[arm] = {
                "status": setup.get("status"),
                "learner_status": learning.get("status"),
                "learner_status_reason": learning.get("status_reason"),
                "model": learning.get("model"),
                "bundle_sha256": learning.get("bundle_sha256"),
                "requests": learning.get("requests"),
                "tokens_total": sum(int(tokens.get(k) or 0) for k in ("input", "output", "cache_read", "cache_write")),
                "cost_usd_meter": float(setup.get("cost_usd") or 0.0),
                "cost_usd_bundle": learning.get("cost_usd"),
                "reused": bool(learning.get("reused")),
                "kept": learning.get("kept"),
                "dropped": learning.get("dropped"),
                "locator": locator_brief(learning.get("spec_locator")),
            }
    return table


def locator_brief(locator):
    """The locator gate fields of a setup, without index rows or constants (older setups carried them)."""
    if not isinstance(locator, dict):
        return None
    return {key: locator.get(key) for key in ("status", "replay_n", "top3_hits", "wrong", "max_card_bytes", "rendered")
            if key in locator}


def is_mock(out, setups):
    for row in read_jsonl(os.path.join(out, "meter", "requests.jsonl")):
        if row.get("mode") == "mock" or "mock_kind" in row:
            return True
    for setup in setups:
        if setup.get("mode") == "rehearsal" or (setup.get("learning") or {}).get("status") == "mock":
            return True
    return False


def load_gold(manifest_path, task_ids):
    if not manifest_path:
        return {}, {}
    manifest = read_json(manifest_path) or {}
    gold, harder = {}, {}
    for task in manifest.get("tasks") or []:
        if task.get("task_id") in task_ids:
            gold[task["task_id"]] = list(task.get("gold_files") or [])
            harder[task["task_id"]] = bool(task.get("v4dev"))
    return gold, harder


def default_manifest(task_ids):
    """corpus/manifest-v2.json when it holds every task (the mock run's v2 tasks); never a v3 file."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "corpus", "manifest-v2.json")
    manifest = read_json(path) or {}
    known = {task.get("task_id") for task in manifest.get("tasks") or []}
    return path if task_ids and set(task_ids) <= known else None


def analyze(out, manifest_path=None):
    chosen, attempts = scored_rows(out)
    task_ids = sorted({key[0] for key in chosen} | {key[0] for key in attempts})
    manifest_path = manifest_path or default_manifest(task_ids)
    gold, harder = load_gold(manifest_path, set(task_ids))
    runs = [run_metrics(out, row, gold.get(row["task_id"])) for _key, row in sorted(chosen.items(), key=lambda kv: kv[1]["run_id"])]
    setups = []
    for task_id in task_ids:
        for arm in ARMS_ORDER:
            setup = read_json(os.path.join(out, "arms", task_id, "%s.setup.json" % arm))
            if setup:
                setups.append(setup)
    mock = is_mock(out, setups)
    groups = {"all": task_ids,
              "harder": [t for t in task_ids if harder.get(t)],
              "easy": [t for t in task_ids if t in harder and not harder[t]]}
    comparisons = {}
    for name, tasks in groups.items():
        comparisons[name] = {"%s_vs_%s" % (a, b): compare(runs, a, b, tasks) for a, b, _role in PAIRS}
    scheduled = []
    for path in sorted(os.listdir(out)) if os.path.isdir(out) else []:
        if path.startswith("schedule") and path.endswith(".json"):
            scheduled.extend(tuple(spec) for spec in (read_json(os.path.join(out, path)) or {}).get("order") or [])
    missing = sorted({spec for spec in scheduled if (spec[0], spec[1], spec[2]) not in chosen})
    complete = not missing and not any(run["budget_exhausted"] for run in runs)
    primary_group = "harder" if groups["harder"] else "all"
    primary = comparisons[primary_group]["olivium-ai_vs_none-lean"]
    arms = {}
    for arm in ARMS_ORDER:
        mine = [run for run in runs if run["arm"] == arm]
        if not mine:
            continue
        arms[arm] = {
            "runs": len(mine),
            "solved": sum(1 for run in mine if run["solved"]),
            "mean_tokens": _r(mean([run["tokens"] for run in mine])),
            "mean_requests": _r(mean([run["requests"] for run in mine])),
            "mean_first_request_tokens": _r(mean([run["first_request_tokens"] for run in mine])),
            "cards_shown": sum(run["cards_shown"] for run in mine),
            "card_gold_hits": sum(sum(1 for hit in run["card_gold_hit"] if hit) for run in mine),
            "runs_with_card": sum(1 for run in mine if run["cards_shown"]),
            "rewrite_hooks_fired": sum(run["rewrite_hooks_fired"] for run in mine),
            "failed_calls": sum(run["failed_calls"] for run in mine),
            "cost_usd": _r(sum(run["cost_usd"] for run in mine), 6),
        }
    learning = learning_table(out, task_ids)
    ai_learning = [entry["olivium-ai"] for entry in learning.values() if "olivium-ai" in entry]
    amortized = None
    if primary and ai_learning:
        saved = (primary["tokens"]["against"] or 0) - (primary["tokens"]["arm"] or 0)
        mean_learning_tokens = mean([entry["tokens_total"] for entry in ai_learning])
        amortized = {
            "mean_learning_tokens_per_task_base": _r(mean_learning_tokens),
            # A reused bundle (prepared from an inspected one) costs this OUT's meter nothing, but it was paid
            # for when it was learned: its own learner record carries that cost.
            "mean_learning_cost_usd_per_task_base": _r(mean([
                float(entry["cost_usd_bundle"] or 0.0) if entry["reused"] else entry["cost_usd_meter"]
                for entry in ai_learning]), 6),
            "tokens_saved_per_run": _r(saved),
            "break_even_runs": _r(mean_learning_tokens / saved, 2) if saved > 0 else None,
            "note": "break_even_runs is null when olivium-ai saved no tokens per run",
        }
    report = {
        "analysis": ANALYSIS_ID,
        "stamp": "MOCK" if mock else "DEV",
        "label": "development data; not evidence of value" + ("; MOCK: scripted model and costs, no decision" if mock else ""),
        "out": os.path.basename(os.path.normpath(out)),
        "manifest": os.path.basename(manifest_path) if manifest_path else None,
        "tasks": task_ids,
        "groups": groups,
        "complete": complete,
        "missing_runs": [list(spec) for spec in missing],
        "infra_attempts": sum(max(0, n - (1 if key in chosen else 0)) for key, n in attempts.items()),
        "arms": arms,
        "comparisons": comparisons,
        "primary_group": primary_group,
        "decision": None if mock else decision(primary if groups["harder"] else None, complete),
        "target": None if mock else target(primary),
        "learning": learning,
        "amortized": amortized,
        "runs": runs,
    }
    return report


def markdown(report):
    lines = ["# v4 development rehearsal analysis (%s)" % report["stamp"], "", report["label"], ""]
    lines.append("| arm | runs | solved | mean tokens | mean requests | first request | cards (gold hit) | rewrites |")
    lines.append("|---|---|---|---|---|---|---|---|")
    for arm, row in report["arms"].items():
        lines.append("| %s | %d | %d | %s | %s | %s | %d (%d) | %d |" % (
            arm, row["runs"], row["solved"], row["mean_tokens"], row["mean_requests"], row["mean_first_request_tokens"],
            row["cards_shown"], row["card_gold_hits"], row["rewrite_hooks_fired"]))
    lines.append("")
    primary = report["comparisons"][report["primary_group"]]["olivium-ai_vs_none-lean"]
    if primary:
        # Review M5: a token ratio is never shown without what learning cost, in tokens, next to it.
        amortized = report.get("amortized") or {}
        even = amortized.get("break_even_runs")
        lines.append("Primary (%s tasks, %d): olivium-ai/none-lean token ratio %s, solve %+s points; learning %s "
                     "tokens ($%s) per task base, %s." % (
                         report["primary_group"], primary["n_tasks"], primary["token_ratio"], primary["solve_points"],
                         amortized.get("mean_learning_tokens_per_task_base", "n/a"),
                         amortized.get("mean_learning_cost_usd_per_task_base", "n/a"),
                         "break-even after %s sessions on the same base" % even if even
                         else "no break-even (no tokens saved per run)"))
    lines.append("Decision: %s" % (json.dumps(report["decision"]) if report["decision"] else "none (MOCK or no data)"))
    return "\n".join(lines) + "\n"


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--manifest")
    parser.add_argument("--md")
    args = parser.parse_args(argv)
    if args.manifest and "v3" in os.path.basename(args.manifest):
        parser.error("the v4 dev analysis never reads a v3 manifest")
    if not os.path.isfile(os.path.join(args.out, "trials.jsonl")):
        print("error: no trials.jsonl in %s" % args.out, file=sys.stderr)
        return 3
    report = analyze(args.out, args.manifest)
    with open(args.report, "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, sort_keys=True)
        handle.write("\n")
    if args.md:
        with open(args.md, "w", encoding="utf-8") as handle:
            handle.write(markdown(report))
    amortized = report.get("amortized") or {}
    even = amortized.get("break_even_runs")
    print("%s: %d runs, %d tasks, decision %s; learning %s tokens per task base, %s" % (
        report["stamp"], len(report["runs"]), len(report["tasks"]), (report["decision"] or {}).get("decision"),
        amortized.get("mean_learning_tokens_per_task_base", "n/a"),
        "break-even after %s sessions" % even if even else "no break-even (no tokens saved per run)"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
