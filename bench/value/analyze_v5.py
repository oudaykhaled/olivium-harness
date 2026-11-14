#!/usr/bin/env python3
"""v5 development test analysis (pre-registered in plan.md). Standard library only; reads data only.

    python3 -I analyze_v5.py --out OUT --report REPORT.json [--md REPORT.md] [--x-arm olivium-x]

Reads a protocol-2 OUT (trials.jsonl, trials/<run_id>/{transcript.jsonl,meter_rows.jsonl},
meter/requests.jsonl, schedule*.json).  Executes nothing.

- Tokens per run = input + output + cache_creation + cache_read of the trial row (the meter's
  messages rows), as in Gate 1 and v4.
- Scored run = per (task, arm, repeat) the last attempt that is not infra_error.
- Task-balanced mean = per task the mean over its scored repeats, then the mean over the tasks
  scored in both arms.  Token ratio = task-balanced mean(olivium-x) / task-balanced mean(none-lean).
- Solve points = (task-balanced solve rate of olivium-x - that of none-lean) x 100.
- DECISION (the program TARGET, fixed before any paid run):
    pass        complete, token ratio <= 0.75 and solve points >= -10
    fail        complete and not pass
    incomplete  a scheduled run is missing or a run was stopped by a budget
  Only --x-arm olivium-x gets a decision; any other value is a dry check of this script.
- Always reported next to the decision: configuration (first-request difference x olivium-x
  requests) and behaviour (the rest); the decision line names the larger part.
- Supplementary (descriptive, not decisive): 95% bootstrap interval of the ratio (tasks and runs
  resampled, 20,000, seed 20261112), exact sign-flip p over per-task log ratios, median per-task
  ratio, and lever counters per arm: output cuts seen, PreToolUse rewrites with a timeout,
  background moves, wait requests, independent exploration pairs, edit->test pairs, failed calls,
  test output bytes.
- An OUT with any mock meter row is stamped MOCK and gets no decision.
"""

import argparse
import itertools
import json
import math
import os
import random
import re
import statistics
import sys

ANALYSIS_ID = "analyze-v5/1"
CONTROL = "none-lean"
TARGET = {"token_ratio_at_most": 0.75, "solve_points_at_least": -10.0}
TOKEN_FIELDS = ("input", "output", "cache_creation", "cache_read")
BOOT_N = 20000
BOOT_SEED = 20261112
CUT_RE = re.compile(r"\[olivium: cut ")
BG_RE = re.compile(r"moved to the background|Command running in background with ID")
EXIT_RE = re.compile(r"^Exit code ([0-9]+)")
MISSING_RE = re.compile(r"command not found|: not found|Failed to spawn|No module named|is not installed|"
                        r"executable file not found")
# The v4 classifier (v4/scripts/gate1_levers.py, as in v5/scripts/v5lib.py), unchanged.
TEST_RE = re.compile(r"(pytest|py\.test|tox\b|nox\b|npm (run )?test|npx (mocha|jest|vitest)|mocha|jest|vitest|mix test|go test|"
                     r"cargo test|unittest)")
LINT_RE = re.compile(r"(ruff|flake8|pylint|mypy|pyright|eslint|prettier|black|isort|tsc\b|pre-commit|mix format|mix credo)")
EDIT_RE = re.compile(r"(python3? - <<|python3? -c .*(write|replace)|sed -i|perl -pi|tee |> [^&]|cat >|apply|patch )")
EXPLORE_RE = re.compile(r"^\s*(cd [^;&]+[;&]+\s*)?(grep|rg|find|ls|cat|head|tail|sed -n|awk|wc|tree|"
                        r"git (log|show|grep|diff|status|blame)|nl )")
RUN_RE = re.compile(r"(python3? |uv run python|node -e|node )")
WAIT_RE = re.compile(r"(^|[;&|(]\s*)(sleep \d|until |while |pkill|kill |wait\b)|/tasks/[a-z0-9]+\.output")
BLOCKED_RE = re.compile(r"^<tool_use_error>(Blocked: sleep|Error: No such tool available: (Monitor|TaskOutput|TaskStop))")
GUARD_RE = re.compile(r"Olivium guard: ")
TOK_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_./-]{2,}|\d{2,}")


def read_jsonl(path):
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    pass
    return rows


def read_json(path, default=None):
    if not os.path.exists(path):
        return default
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
    return ""


def klass(tool, cmd):
    if tool != "Bash":
        return "explore" if tool == "Read" else ("edit" if tool in ("Edit", "Write", "MultiEdit") else "other")
    c = cmd.strip()
    if TEST_RE.search(c):
        return "test"
    if LINT_RE.search(c):
        return "lint"
    if EDIT_RE.search(c) and not EXPLORE_RE.match(c):
        return "edit"
    if EXPLORE_RE.match(c):
        return "explore"
    if RUN_RE.search(c):
        return "run"
    if c.startswith("git "):
        return "explore"
    return "other"


def hook_json(text):
    for line in (text or "").splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if isinstance(obj, dict):
                return obj
    return {}


def toks(text):
    return set(TOK_RE.findall(text or ""))


def parse(run_dir):
    calls, order, mids = {}, [], []
    hooks = {"shaper_rewrites": 0, "timeout_rewrites": 0}
    for ev in read_jsonl(os.path.join(run_dir, "transcript.jsonl")):
        kind = ev.get("type")
        if kind == "system" and ev.get("subtype") == "hook_response" and ev.get("hook_event") == "PreToolUse":
            out = ev.get("output") if isinstance(ev.get("output"), str) else (ev.get("stdout") or "")
            upd = ((hook_json(out).get("hookSpecificOutput") or {}).get("updatedInput"))
            if isinstance(upd, dict):
                hooks["shaper_rewrites"] += "command" in upd
                hooks["timeout_rewrites"] += "timeout" in upd
        elif kind == "assistant":
            msg = ev.get("message") or {}
            mid = msg.get("id")
            if mid and mid not in mids:
                mids.append(mid)
            for b in msg.get("content") or []:
                if isinstance(b, dict) and b.get("type") == "tool_use":
                    calls[b.get("id")] = {"tool": b.get("name"), "input": b.get("input") or {},
                                          "request": mids.index(mid) + 1 if mid in mids else None, "out": ""}
                    order.append(b.get("id"))
        elif kind == "user":
            content = (ev.get("message") or {}).get("content")
            if isinstance(content, list):
                for b in content:
                    if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("tool_use_id") in calls:
                        c = calls[b["tool_use_id"]]
                        c["out"] = text_of(b.get("content"))
                        c["is_error"] = bool(b.get("is_error"))
    prompt = ""
    if os.path.exists(os.path.join(run_dir, "prompt.txt")):
        with open(os.path.join(run_dir, "prompt.txt"), "r", encoding="utf-8", errors="replace") as fh:
            prompt = fh.read()
    return [calls[i] for i in order], hooks, prompt


def lever_counters(calls, n, prompt):
    by_req = {}
    for c in calls:
        cmd = str(c["input"].get("command") or "") if c["tool"] == "Bash" else ""
        c["cmd"] = cmd
        c["klass"] = klass(c["tool"], cmd)
        by_req.setdefault(c["request"], []).append(c)
    failed = sum(1 for c in calls if c.get("is_error") or (EXIT_RE.match(c["out"]) and EXIT_RE.match(c["out"]).group(1) != "0")
                 or (c["tool"] == "Bash" and MISSING_RE.search(c["out"][:400])))
    test_bytes = sum(len(c["out"].encode()) for c in calls if c["klass"] == "test")
    cuts = sum(len(CUT_RE.findall(c["out"])) for c in calls)
    guard = sum(1 for c in calls if GUARD_RE.search(c["out"][:300]))
    bg = [c["request"] for c in calls if BG_RE.search(c["out"])]
    wait = 0
    if bg:
        for k in range(min(bg) + 1, n):
            cs = by_req.get(k, [])
            if not cs or all(c["tool"] in ("Monitor", "TaskOutput", "TaskStop") or BLOCKED_RE.search(c["out"])
                             or WAIT_RE.search(c["cmd"] or str(c["input"].get("file_path") or "")) for c in cs):
                wait += 1
    indep = dep = edit_test = 0
    known = toks(prompt)
    prev = None
    prev_known = set()
    for k in range(1, n + 1):
        cs = by_req.get(k, [])
        cmd_t = set().union(*[toks(c["cmd"] or str(c["input"].get("file_path") or "")) for c in cs]) if cs else set()
        out_t = set().union(*[toks(c["out"]) for c in cs]) if cs else set()
        explore = bool(cs) and all(c["klass"] == "explore" for c in cs)
        if prev is not None and explore:
            new = set().union(*[toks(c["out"]) for c in by_req[prev]]) - prev_known
            if cmd_t & new:
                dep += 1
            else:
                indep += 1
        if k > 1 and cs and all(c["klass"] == "test" for c in cs):
            p = by_req.get(k - 1, [])
            if p and all(c["klass"] == "edit" for c in p):
                edit_test += 1
        prev_known = set(known) | cmd_t
        known |= cmd_t | out_t
        prev = k if explore else None
    return {"failed_calls": failed, "test_output_bytes": test_bytes, "output_cuts_seen": cuts, "guard_denials": guard,
            "background_moves": len(bg), "wait_requests": wait, "independent_explore_pairs": indep,
            "dependent_explore_pairs": dep, "edit_then_test_pairs": edit_test, "tool_calls": len(calls)}


def scored_rows(out):
    chosen, attempts = {}, {}
    for row in read_jsonl(os.path.join(out, "trials.jsonl")):
        key = (row.get("task_id"), row.get("arm"), row.get("repeat"))
        attempts[key] = attempts.get(key, 0) + 1
        if row.get("status") != "infra_error":
            chosen[key] = row
    return chosen, attempts


def run_metrics(out, row):
    run_dir = os.path.join(out, "trials", row["run_id"])
    meter = [r for r in read_jsonl(os.path.join(run_dir, "meter_rows.jsonl")) if r.get("endpoint") == "messages"]
    models = [r.get("model") for r in meter if r.get("model")]
    main_model = max(sorted(set(models)), key=models.count) if models else None
    mains = sorted([r for r in meter if r.get("model") == main_model], key=lambda r: int(r.get("seq") or 0))
    first = (int(mains[0].get("input_tokens") or 0) + int(mains[0].get("cache_creation_input_tokens") or 0)
             + int(mains[0].get("cache_read_input_tokens") or 0)) if mains else None
    calls, hooks, prompt = parse(run_dir)
    n = int(row.get("requests") or len(mains))
    m = {"run_id": row["run_id"], "task_id": row["task_id"], "arm": row["arm"], "repeat": row["repeat"],
         "status": row.get("status"), "solved": bool(row.get("solved")),
         "tokens": sum(int((row.get("tokens") or {}).get(f) or 0) for f in TOKEN_FIELDS),
         "cost_usd": float(row.get("cost_usd") or 0.0), "requests": n, "main_requests": len(mains),
         "first_request_tokens": first, "budget_exhausted": row.get("status") == "budget_exhausted",
         "shaper_rewrites": hooks["shaper_rewrites"], "timeout_rewrites": hooks["timeout_rewrites"]}
    m.update(lever_counters(calls, n, prompt))
    return m


def mean(values):
    values = [v for v in values if v is not None]
    return sum(values) / len(values) if values else None


def per_task(runs, arm, key):
    table = {}
    for r in runs:
        if r["arm"] == arm:
            v = r[key]
            table.setdefault(r["task_id"], []).append(1.0 if v is True else 0.0 if v is False else v)
    return {t: mean(v) for t, v in table.items() if mean(v) is not None}


def _r(v, d=4):
    return None if v is None else round(float(v), d)


def bootstrap(runs, x_arm, tasks):
    rng = random.Random(BOOT_SEED)
    by = {(t, a): [r["tokens"] for r in runs if r["task_id"] == t and r["arm"] == a] for t in tasks for a in (x_arm, CONTROL)}
    vals = []
    for _ in range(BOOT_N):
        ts = [rng.choice(tasks) for _ in tasks]
        num = den = 0.0
        for t in ts:
            xs = by[(t, x_arm)]
            cs = by[(t, CONTROL)]
            num += mean([rng.choice(xs) for _ in xs])
            den += mean([rng.choice(cs) for _ in cs])
        vals.append(num / den)
    vals.sort()
    return [_r(vals[int(0.025 * BOOT_N)]), _r(vals[int(0.975 * BOOT_N) - 1])]


def sign_flip(logs):
    if not logs:
        return None
    obs = abs(sum(logs))
    hits = total = 0
    for signs in itertools.product((1, -1), repeat=len(logs)):
        total += 1
        if abs(sum(s * v for s, v in zip(signs, logs))) >= obs - 1e-12:
            hits += 1
    return _r(hits / total)


def compare(runs, x_arm):
    a_tok, b_tok = per_task(runs, x_arm, "tokens"), per_task(runs, CONTROL, "tokens")
    tasks = sorted(set(a_tok) & set(b_tok))
    if not tasks:
        return None
    res = {"arm": x_arm, "against": CONTROL, "tasks": tasks, "n_tasks": len(tasks)}
    keys = ("tokens", "solved", "requests", "main_requests", "first_request_tokens", "cost_usd", "failed_calls",
            "test_output_bytes", "output_cuts_seen", "shaper_rewrites", "timeout_rewrites", "guard_denials",
            "background_moves", "wait_requests",
            "independent_explore_pairs", "edit_then_test_pairs", "tool_calls")
    for key in keys:
        a, b = per_task(runs, x_arm, key), per_task(runs, CONTROL, key)
        res[key] = {"arm": _r(mean([a.get(t) for t in tasks])), "against": _r(mean([b.get(t) for t in tasks]))}
    ta, tb = res["tokens"]["arm"], res["tokens"]["against"]
    res["token_ratio"] = _r(ta / tb) if tb else None
    res["per_task_token_ratio"] = {t: _r(a_tok[t] / b_tok[t]) for t in tasks if b_tok[t]}
    ratios = [a_tok[t] / b_tok[t] for t in tasks if b_tok[t]]
    res["median_task_token_ratio"] = _r(statistics.median(ratios)) if ratios else None
    sa, sb = res["solved"]["arm"], res["solved"]["against"]
    res["solve_points"] = _r((sa - sb) * 100.0) if sa is not None and sb is not None else None
    fa, fb, ra = res["first_request_tokens"]["arm"], res["first_request_tokens"]["against"], res["main_requests"]["arm"]
    if None not in (fa, fb, ra, ta, tb):
        config = (fa - fb) * ra
        res["delta_tokens"] = {"total": _r(ta - tb), "configuration_prefix": _r(config), "behaviour": _r(ta - tb - config)}
    res["supplementary"] = {"bootstrap_95": bootstrap(runs, x_arm, tasks),
                            "sign_flip_p": sign_flip([math.log(r) for r in ratios if r > 0]),
                            "tasks_lower": sum(1 for r in ratios if r < 1), "tasks_higher": sum(1 for r in ratios if r > 1)}
    return res


def decision(cmp, complete, x_arm, mock):
    if mock:
        return {"decision": None, "why": "MOCK"}
    if x_arm != "olivium-x":
        return {"decision": None, "why": "dry check with --x-arm %s; only olivium-x gets a decision" % x_arm}
    if cmp is None:
        return {"decision": None, "why": "no olivium-x and none-lean runs on the same tasks"}
    if not complete:
        return {"decision": "incomplete", "why": "a scheduled run is missing or was stopped by a budget"}
    ratio, points = cmp["token_ratio"], cmp["solve_points"]
    ok = ratio is not None and points is not None and ratio <= TARGET["token_ratio_at_most"] \
        and points >= TARGET["solve_points_at_least"]
    d = cmp.get("delta_tokens") or {}
    part = None
    if d.get("total") is not None and d["total"] < 0:
        part = "configuration" if (d.get("configuration_prefix") or 0) < (d.get("behaviour") or 0) else "behaviour"
    return {"decision": "pass" if ok else "fail",
            "why": "token ratio %s (bar %.2f), solve points %s (bar %+.0f); larger part of the saving: %s" % (
                ratio, TARGET["token_ratio_at_most"], points, TARGET["solve_points_at_least"], part)}


def analyze(out, x_arm):
    chosen, attempts = scored_rows(out)
    runs = [run_metrics(out, row) for _k, row in sorted(chosen.items(), key=lambda kv: kv[1]["run_id"])
            if row.get("arm") in (x_arm, CONTROL)]
    mock = any(r.get("mode") == "mock" or "mock_kind" in r for r in read_jsonl(os.path.join(out, "meter", "requests.jsonl")))
    scheduled = []
    for name in sorted(os.listdir(out)):
        if name.startswith("schedule") and name.endswith(".json"):
            scheduled.extend(tuple(s) for s in (read_json(os.path.join(out, name)) or {}).get("order") or []
                             if len(s) >= 3 and s[1] in (x_arm, CONTROL))
    missing = sorted({s for s in scheduled if (s[0], s[1], s[2]) not in chosen})
    complete = not missing and not any(r["budget_exhausted"] for r in runs)
    cmp = compare(runs, x_arm)
    arms = {}
    for arm in (CONTROL, x_arm):
        mine = [r for r in runs if r["arm"] == arm]
        if mine:
            arms[arm] = {"runs": len(mine), "solved": sum(r["solved"] for r in mine),
                         "mean_tokens": _r(mean([r["tokens"] for r in mine])),
                         "mean_requests": _r(mean([r["requests"] for r in mine])),
                         "mean_first_request_tokens": _r(mean([r["first_request_tokens"] for r in mine])),
                         "cost_usd": _r(sum(r["cost_usd"] for r in mine), 6),
                         **{k: sum(r[k] for r in mine) for k in ("failed_calls", "output_cuts_seen", "shaper_rewrites",
                                                                 "timeout_rewrites", "guard_denials",
                                                                 "background_moves", "wait_requests",
                                                                 "independent_explore_pairs", "edit_then_test_pairs")}}
    return {"analysis": ANALYSIS_ID, "stamp": "MOCK" if mock else "DEV",
            "label": "development data, screening only; not evidence of value", "x_arm": x_arm,
            "complete": complete, "missing_runs": [list(s) for s in missing],
            "infra_attempts": sum(max(0, n - (1 if k in chosen else 0)) for k, n in attempts.items()),
            "arms": arms, "primary": cmp, "decision": decision(cmp, complete, x_arm, mock), "target": TARGET,
            "runs": runs}


def markdown(rep):
    p = rep["primary"] or {}
    lines = ["# v5 development test analysis (%s)" % rep["stamp"], "", rep["label"], "",
             "| arm | runs | solved | mean tokens | mean requests | first request | cuts | shaper rewrites | timeout rewrites | "
             "guard denials | bg moves | wait req |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for arm, a in rep["arms"].items():
        lines.append("| %s | %d | %d | %s | %s | %s | %d | %d | %d | %d | %d | %d |" % (
            arm, a["runs"], a["solved"], a["mean_tokens"], a["mean_requests"], a["mean_first_request_tokens"],
            a["output_cuts_seen"], a["shaper_rewrites"], a["timeout_rewrites"], a["guard_denials"],
            a["background_moves"], a["wait_requests"]))
    lines += ["", "Primary: %s/none-lean token ratio %s, solve %s points, split %s, bootstrap %s, sign-flip p %s." % (
        rep["x_arm"], p.get("token_ratio"), p.get("solve_points"), json.dumps(p.get("delta_tokens")),
        (p.get("supplementary") or {}).get("bootstrap_95"), (p.get("supplementary") or {}).get("sign_flip_p")),
        "Decision: %s" % json.dumps(rep["decision"])]
    return "\n".join(lines) + "\n"


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True)
    ap.add_argument("--report", required=True)
    ap.add_argument("--md")
    ap.add_argument("--x-arm", default="olivium-x")
    a = ap.parse_args(argv)
    if not os.path.isfile(os.path.join(a.out, "trials.jsonl")):
        print("error: no trials.jsonl in %s" % a.out, file=sys.stderr)
        return 3
    rep = analyze(a.out, a.x_arm)
    with open(a.report, "w", encoding="utf-8") as fh:
        json.dump(rep, fh, indent=2, sort_keys=True)
        fh.write("\n")
    if a.md:
        with open(a.md, "w", encoding="utf-8") as fh:
            fh.write(markdown(rep))
    p = rep["primary"] or {}
    print("%s: %d runs; %s/none-lean ratio %s, solve %s points; decision %s" % (
        rep["stamp"], len(rep["runs"]), rep["x_arm"], p.get("token_ratio"), p.get("solve_points"),
        (rep["decision"] or {}).get("decision")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
