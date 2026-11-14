#!/usr/bin/env python3
"""Counterfactual token model over recorded Olivium runs. A MODEL, NOT A MEASUREMENT.

Question: had the recorded Olivium runs used the stage-1 design, how many tokens
would they have used, against the recorded no-harness runs of the same tasks?

Inputs are recorded runs only (meter rows and transcripts). For each Olivium run:

  1. Turns the design removes (whole turns only; a turn that also did real work stays):
       harm      every call in the turn was refused, or probed for a tool or
                 interpreter, or ran a lint/type-check tool that is not installed
                 (items 3 and 5: environment facts, refusal text), or read a file
                 the recorded CLAUDE.md said to read first (that line is withheld)
       lint      additionally, every call ran only lint, format or type-check
                 commands (item 1: the root file stops listing them; the Stop
                 hook formats and lints changed files)
     Removing request j saves its own tokens plus the context it added
     (context[j+1] - context[j]) on every later request. A read-first call in a
     turn that also did other work is removed alone: its input and result
     (characters / 2.775, at most the turn's measured growth) leave every later
     request. `git status` and `git diff --stat` count as neither work nor lint.
  2. The per-request prefix changes, applied to every remaining request:
       standard  the root file's price changes from the recorded CLAUDE.md to
                 the new one (price = 0 if comment-only, else 110 + bytes / 2.8;
                 contract.md section 6)
       lean      the prefix becomes none's prefix minus the measured trim plus
                 the new root file's price; the recorded excess over none is
                 measured per task from the first metered request

Predictions per task are means over repeats; the headline is the median across
tasks of (predicted Olivium tokens / recorded none tokens), the protocol's
primary statistic. Nothing about the model's behaviour changes except the
removed turns: the model assumes the agent would have done everything else the
same, which no one can know. Gate 0 row 11 reads: behaviour part (standard,
no trim) at most 1.03; with the measured trim (lean) at most 0.65.

  python3 bench/value/replay/counterfactual.py \\
      --none <bench-out>/value-v2-2026-11-09/trials \\
      --olivium <bench-out>/value-v2-2026-11-10-fix/trials \\
      --old-arms "<bench-out>/value-v2-2026-11-10-fix/arms/{task}/olivium" \\
      --out FILE.json
"""

import argparse
import collections
import json
import os
import re
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import calls as calls_mod  # noqa: E402

# Measured by the red-team request capture (final plan section 0; contract.md section 5):
# lean settings against none on Claude Code 2.1.311, express-7366 (-11,700) and attrs-1593 (-11,652).
DEFAULT_TRIM = 11700
# contract.md section 9: the example lean root file (changelog line + fixed line).
DEFAULT_NEW_ROOT_BYTES = 104
LINT_TOOLS = {"ruff", "mypy", "dmypy", "pyright", "eslint", "black", "flake8", "isort", "prettier", "pre-commit",
              "pylint", "tsc", "stubtest", "standard", "xo", "biome"}
NEUTRAL = {"cd", "tail", "head", "echo", "true", "printf", "sort", "uniq", "wc", "sleep", ":"}
PROBE_RE = re.compile(r"^(which|type|command -v|hash)\b|^(uv python (list|find))\b|^(pip3?|uv pip) (show|list)\b"
                      r"|^ls\b.*(\.venv/bin|/usr/(local/)?bin|\.local/|\.pyenv|/opt/)|^python3?\.[0-9]+ (-V|--version)\b")
MISSING_RE = re.compile(r"command not found|: not found|Failed to spawn|No such file or directory \(os error|"
                        r"No module named '?(mypy|pyright|ruff|pre_commit)|is not installed|executable file not found", re.I)
RUNNERS = (("uv", "run"), ("poetry", "run"), ("pdm", "run"), ("hatch", "run"), ("pipenv", "run"))
READ_FIRST_RE = re.compile(r"Read `([^`]+)` first", re.I)
CHARS_PER_TOKEN = 2.775  # calibration from the red-team request capture (contract.md section 6)


def price(nbytes):
    return 0 if nbytes <= 0 else 110 + (nbytes * 10 + 27) // 28


def visible_bytes(path):
    """Bytes of CLAUDE.md the model sees: HTML comments are stripped by Claude Code."""
    if not os.path.isfile(path):
        return 0
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    return len(text.strip().encode("utf-8"))


def tool_of(items):
    """The program a piece runs, past runners such as uv run, python -m, npx."""
    index = 0
    while index < len(items):
        word = items[index].rsplit("/", 1)[-1]
        if any(items[index:index + 2] == list(pair) for pair in RUNNERS):
            index += 2
            while index < len(items) and items[index].startswith("-"):
                index += 2 if items[index] in ("--with", "--group", "--python", "-p", "--extra") else 1
            continue
        if word in ("npx", "uvx", "bunx"):
            index += 1
            while index < len(items) and items[index].startswith("-"):
                index += 1
            continue
        if re.match(r"^python[0-9.]*$", word) and items[index + 1:index + 2] == ["-m"]:
            index += 2
            continue
        if word in ("npm", "pnpm", "yarn") and items[index + 1:index + 2] == ["run"] and index + 2 < len(items):
            script = items[index + 2]
            return "lint-script" if re.match(r"^(lint|format|typecheck|type-check|check-types)", script) else word
        return word
    return ""


def read_first_files(claude_md_path):
    if not os.path.isfile(claude_md_path):
        return []
    with open(claude_md_path, "r", encoding="utf-8", errors="replace") as handle:
        names = [match.group(1) for match in READ_FIRST_RE.finditer(handle.read())]
    return [name[2:] if name.startswith("./") else name for name in names]


def is_read_first(call, files):
    path = call["input"].get("file_path") if call["name"] == "Read" and isinstance(call["input"], dict) else None
    return isinstance(path, str) and any(path == name or path.endswith("/" + name) for name in files)


def review_only(items):
    return items[:1] == ["git"] and (items[1:2] == ["status"] or (items[1:2] == ["diff"] and ("--stat" in items or "--name-only" in items)))


def classify_call(call, read_first=()):
    """harm, lint or work."""
    if call.get("refused") or is_read_first(call, read_first):
        return "harm"
    if call["name"] != "Bash":
        return "work"
    command = call["input"].get("command") if isinstance(call["input"], dict) else None
    if not isinstance(command, str):
        return "work"
    kinds = set()
    for piece, separator in calls_mod.split_segments(command):
        items = calls_mod.command_words(piece)
        if not items:
            continue
        joined = " ".join(items)
        tool = tool_of(items)
        if PROBE_RE.search(joined):
            kinds.add("probe")
        elif tool in LINT_TOOLS or tool == "lint-script":
            kinds.add("lint")
        elif tool in NEUTRAL or (tool == "grep" and separator == "|") or review_only(items):
            continue
        else:
            kinds.add("work")
    if "work" in kinds or not kinds:
        return "work"
    if "probe" in kinds:
        return "harm"
    # Only lint, format or type-check commands: harm when the tool turned out to be missing.
    return "harm" if MISSING_RE.search(call.get("result") or "") else "lint"


def request_rows(trial_dir):
    rows = []
    with open(os.path.join(trial_dir, "meter_rows.jsonl"), "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                row = json.loads(line)
                if row.get("endpoint") == "messages" and row.get("status") == "ok":
                    rows.append(row)
    rows.sort(key=lambda row: row.get("seq") or 0)
    out = []
    for row in rows:
        context = int(row.get("input_tokens") or 0) + int(row.get("cache_creation_input_tokens") or 0) + int(row.get("cache_read_input_tokens") or 0)
        out.append({"context": context, "total": context + int(row.get("output_tokens") or 0)})
    return out


def run_record(trial_dir):
    calls, info = calls_mod.read_transcript(os.path.join(trial_dir, "transcript.jsonl"))
    rows = request_rows(trial_dir)
    by_turn = collections.defaultdict(list)
    for call in calls:
        if call.get("main") and call.get("turn"):
            by_turn[call["turn"]].append(call)
    return {"calls": calls, "turns": info["turns"], "rows": rows, "by_turn": by_turn,
            "aligned": info["turns"] == len(rows)}


def removable(record, variant, read_first):
    """(whole turns removed, {turn: tokens of read-first calls removed alone})."""
    allowed = {"harm"} if variant == "harm" else {"harm", "lint"}
    turns, partial = [], {}
    for turn, turn_calls in sorted(record["by_turn"].items()):
        kinds = [classify_call(call, read_first) for call in turn_calls]
        if kinds and all(kind in allowed for kind in kinds):
            turns.append(turn)
            continue
        alone = [call for call in turn_calls if is_read_first(call, read_first)]
        if alone:
            chars = sum(call.get("result_chars", 0) + len(json.dumps(call["input"])) for call in alone)
            partial[turn] = int(chars / CHARS_PER_TOKEN)
    return turns, partial


def predict(record, removed, partial, per_request_delta):
    rows = record["rows"]
    n = len(rows)
    total = sum(row["total"] for row in rows)
    saved = 0
    for turn in removed:
        j = turn - 1
        if j >= n:
            continue
        growth = rows[j + 1]["context"] - rows[j]["context"] if j + 1 < n else 0
        saved += rows[j]["total"] + max(growth, 0) * (n - j - 1)
    for turn, tokens in partial.items():
        j = turn - 1
        if j + 1 >= n:
            continue
        growth = max(rows[j + 1]["context"] - rows[j]["context"], 0)
        saved += min(tokens, growth) * (n - j - 1)
    remaining = n - len([t for t in removed if t - 1 < n])
    return total - saved + per_request_delta * remaining, remaining


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--none", required=True, help="trial directories with the recorded no-harness runs")
    parser.add_argument("--olivium", required=True, help="trial directories with the recorded Olivium runs")
    parser.add_argument("--old-arms", required=True, help="the recorded Olivium export per task, with {task}")
    parser.add_argument("--new-arms", help="regenerated export per task, with {task}: its CLAUDE.md sets the new price")
    parser.add_argument("--new-root-bytes", type=int, default=DEFAULT_NEW_ROOT_BYTES,
                        help="model-visible bytes of the new CLAUDE.md when --new-arms is not given (default: the contract example)")
    parser.add_argument("--trim", type=int, default=DEFAULT_TRIM, help="measured lean trim per request against none")
    parser.add_argument("--shape-dir", help="shape_run.py outputs per task (DIR/<task>/shape.json with setups fix, cand, "
                                            "cand-standard): per-request deltas measured instead of the formula")
    parser.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    none_runs = [d for d in calls_mod.trial_dirs(os.path.realpath(args.none)) if d[2] == "none"]
    oliv_runs = [d for d in calls_mod.trial_dirs(os.path.realpath(args.olivium)) if d[2] == "olivium"]
    tasks = sorted({d[1] for d in oliv_runs})
    report = {"schema": "olivium-counterfactual/1", "label": "A MODEL, NOT A MEASUREMENT", "trim_per_request": args.trim,
              "tasks": {}, "runs": []}
    ratios = collections.defaultdict(list)
    pooled = collections.defaultdict(lambda: [0.0, 0.0])
    for task in tasks:
        none_records = [run_record(d[4]) for d in none_runs if d[1] == task]
        oliv = [(d[0], run_record(d[4])) for d in oliv_runs if d[1] == task]
        none_tokens = statistics.mean(sum(r["total"] for r in rec["rows"]) for rec in none_records)
        none_first = statistics.median(rec["rows"][0]["context"] for rec in none_records)
        oliv_first = statistics.median(rec["rows"][0]["context"] for _name, rec in oliv)
        excess = oliv_first - none_first
        old_md = os.path.join(args.old_arms.replace("{task}", task), "CLAUDE.md")
        old_bytes = visible_bytes(old_md)
        read_first = read_first_files(old_md)
        new_bytes = visible_bytes(os.path.join(args.new_arms.replace("{task}", task), "CLAUDE.md")) if args.new_arms else args.new_root_bytes
        p_old, p_new = price(old_bytes), price(new_bytes)
        provenance = os.path.join(args.new_arms.replace("{task}", task), ".olivium", "guidance-provenance.json") if args.new_arms else None
        if provenance and os.path.isfile(provenance):
            # The export's own number (contract.md section 6), so the model prices the file as the CLI shows it.
            with open(provenance, "r", encoding="utf-8") as handle:
                stated = json.load(handle)
            if isinstance(stated.get("est_tokens_per_request"), int):
                new_bytes, p_new = stated.get("rendered_bytes", new_bytes), stated["est_tokens_per_request"]
        deltas = {"standard": -(p_old - p_new), "lean": -(excess + args.trim - p_new)}
        delta_source = "formula: root-file prices (standard); recorded excess + measured trim (lean)"
        if args.shape_dir:
            # Measured per task on the same Claude Code version: the candidate's first request against the recorded
            # fix arm's, in the same capture run (shape.py). Includes the environment-check line when it prints.
            with open(os.path.join(args.shape_dir, task, "shape.json"), "r", encoding="utf-8") as handle:
                measured = json.load(handle)["setups"]
            deltas = {"standard": measured["cand-standard"]["est_tokens"] - measured["fix"]["est_tokens"],
                      "lean": measured["cand"]["est_tokens"] - measured["fix"]["est_tokens"]}
            delta_source = "request shape: candidate minus recorded fix arm, mock-meter capture"
        row = {"none_runs": len(none_records), "olivium_runs": len(oliv), "none_tokens_mean": round(none_tokens),
               "olivium_recorded_mean": round(statistics.mean(sum(r["total"] for r in rec["rows"]) for _n, rec in oliv)),
               "first_request_none": none_first, "first_request_olivium": oliv_first, "recorded_excess_per_request": excess,
               "root_bytes_old": old_bytes, "read_first_withheld": read_first, "root_bytes_new": new_bytes, "price_old": p_old, "price_new": p_new,
               "per_request_delta": deltas, "per_request_delta_source": delta_source, "predicted": {}, "turns": {}}
        row["recorded_ratio"] = round(row["olivium_recorded_mean"] / none_tokens, 4)
        ratios["recorded"].append(row["recorded_ratio"])
        pooled["recorded"][0] += row["olivium_recorded_mean"]
        pooled["recorded"][1] += none_tokens
        row["turns"]["none_mean"] = round(statistics.mean(len(rec["rows"]) for rec in none_records), 2)
        row["turns"]["olivium_recorded_mean"] = round(statistics.mean(len(rec["rows"]) for _n, rec in oliv), 2)
        for variant in ("harm", "lint"):
            for profile in ("standard", "lean"):
                values, turns_left = [], []
                for name, rec in oliv:
                    removed, partial = removable(rec, variant, read_first)
                    value, remaining = predict(rec, removed, partial, deltas[profile])
                    values.append(value)
                    turns_left.append(remaining)
                    if profile == "standard":
                        report["runs"].append({"run_id": name, "variant": variant, "aligned": rec["aligned"],
                                               "turns": len(rec["rows"]), "removed_turns": removed,
                                               "read_first_tokens_removed_by_turn": {str(k): v for k, v in partial.items()}})
                key = "%s_%s" % (variant, profile)
                mean = statistics.mean(values)
                row["predicted"][key] = {"tokens_mean": round(mean), "ratio_vs_none": round(mean / none_tokens, 4),
                                         "turns_mean": round(statistics.mean(turns_left), 2)}
                ratios[key].append(mean / none_tokens)
                pooled[key][0] += mean
                pooled[key][1] += none_tokens
        report["tasks"][task] = row
    report["summary"] = {key: {"median_ratio": round(statistics.median(values), 4), "min": round(min(values), 4),
                               "max": round(max(values), 4), "tasks": len(values),
                               "pooled_ratio": round(pooled[key][0] / pooled[key][1], 4)} for key, values in ratios.items()}
    behaviour = max(report["summary"]["harm_standard"]["median_ratio"], report["summary"]["lint_standard"]["median_ratio"])
    with_trim = max(report["summary"]["harm_lean"]["median_ratio"], report["summary"]["lint_lean"]["median_ratio"])
    report["gate0_row11"] = {
        "behaviour_part_median_ratio_worst_variant": behaviour, "behaviour_limit": 1.03, "behaviour_pass": behaviour <= 1.03,
        "with_trim_median_ratio_worst_variant": with_trim, "with_trim_limit": 0.65, "with_trim_pass": with_trim <= 0.65,
    }
    report["unaligned_runs"] = sorted({r["run_id"] for r in report["runs"] if not r["aligned"]})
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, sort_keys=True)
        handle.write("\n")
    print("A MODEL, NOT A MEASUREMENT. Median across %d tasks of Olivium tokens / none tokens:" % len(tasks))
    print("  recorded fix run:                 %.3f  (pooled over tasks %.3f)" % (
        report["summary"]["recorded"]["median_ratio"], report["summary"]["recorded"]["pooled_ratio"]))
    for key, label in (("harm_standard", "remove harm turns, standard"), ("lint_standard", "remove harm+lint turns, standard"),
                       ("harm_lean", "remove harm turns, lean trim"), ("lint_lean", "remove harm+lint turns, lean trim")):
        s = report["summary"][key]
        print("  %-34s %.3f  (tasks %.3f to %.3f; pooled %.3f)" % (label + ":", s["median_ratio"], s["min"], s["max"], s["pooled_ratio"]))
    gate = report["gate0_row11"]
    print("Gate 0 row 11: behaviour %.3f (limit 1.03) %s; with trim %.3f (limit 0.65) %s" % (
        gate["behaviour_part_median_ratio_worst_variant"], "pass" if gate["behaviour_pass"] else "FAIL",
        gate["with_trim_median_ratio_worst_variant"], "pass" if gate["with_trim_pass"] else "FAIL"))
    if report["unaligned_runs"]:
        print("runs whose transcript turns and metered requests differ: %s" % ", ".join(report["unaligned_runs"]))
    return 0 if gate["behaviour_pass"] and gate["with_trim_pass"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
