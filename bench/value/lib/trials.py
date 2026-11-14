"""Execute, grade and record one scored trial or the as-exported run."""

import datetime
import json
import os

from lib.common import (
    CLAUDE_CODE_VERSION,
    EXPORTED_SETTINGS_ARMS,
    FILELESS_ARMS,
    GRADE_TEST_TIMEOUT_V3_S,
    MODEL,
    PROMPT_SUFFIX,
    BenchError,
    append_jsonl,
    read_jsonl,
    sha256_bytes,
    sha256_file,
    tree_digest,
    tree_files,
    write_json_atomic,
)
from lib import dockerops as dk
from lib import meterctl
from lib import mockplans
from lib import session as ses
from lib import transcript
from grade import grader

LIMIT_STATUSES = ("timeout", "turn_limit", "budget_exhausted")
# Protocol v2: a trial stopped because a web tool reached it. run.py stops the run on it.
WEB_GUARD_ERROR = "web tools reached the session"
# Protocol 3: a trial that ran another Claude Code than the pinned one. run.py stops the run on it.
VERSION_PIN_ERROR = "claude code is not the pinned version"


def protocol_v3(ctx):
    return getattr(ctx, "protocol_version", None) == 3


def label_row(ctx, row):
    """Protocol 3 rows say so, and whether they are pilot rows. Other protocols' rows are unchanged."""
    if protocol_v3(ctx):
        row["protocol"] = 3
        row["pilot"] = bool(getattr(ctx, "pilot", False))
    return row


def now_iso():
    return datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"


def scored_prompt(ctx, task, material_dir, arm_dirs=None):
    with open(os.path.join(material_dir, "issue.md"), "r", encoding="utf-8") as handle:
        issue = handle.read()
    prompt = issue.rstrip("\n") + "\n\n" + PROMPT_SUFFIX + "\n"
    if not ctx.paid:
        with open(os.path.join(material_dir, "gold.patch"), "r", encoding="utf-8", errors="replace") as handle:
            gold = handle.read()
        plan = mockplans.scenario_plan(ctx.scenario, task, gold, mockplans.native_names(arm_dirs))
        prompt += "\n" + mockplans.plan_marker(plan) + "\n"
    return prompt.encode("utf-8")


def empty_row(spec, task):
    return {
        "run_id": spec["run_id"],
        "task_id": spec["task_id"],
        "arm": spec["arm"],
        "repeat": spec["repeat"],
        "status": "infra_error",
        "solved": False,
        "f2p_passed": 0,
        "f2p_total": len(task["f2p"]),
        "p2p_regressions": None,
        "lint_ok": None,
        "tokens": {"input": 0, "output": 0, "cache_creation": 0, "cache_read": 0},
        "cost_usd": 0.0,
        "requests": 0,
        "turns": 0,
        "tool_calls": {},
        "files_read": 0,
        "wasted_reads": 0,
        "turns_before_first_gold_edit": None,
        "tool_calls_before_first_gold_edit": None,
        "patch_lines": 0,
        "wall_seconds": 0.0,
        "model": MODEL,
        "claude_code_version": None,
        "harness_bytes": 0,
        "permission_denials": 0,
        "hook_blocks": 0,
    }


def check_harness_files(arm_dirs, settings_bytes, run_dir):
    """Compare what the container recorded before the agent started with what the arm should have."""
    expected = {}
    for arm_dir in arm_dirs:
        for rel in tree_files(arm_dir):
            expected[rel] = sha256_file(os.path.join(arm_dir, rel))
    observed = {}
    listing = os.path.join(run_dir, "harness-files.sha256")
    if os.path.exists(listing):
        with open(listing, "r", encoding="utf-8") as handle:
            for line in handle:
                parts = line.rstrip("\n").split("  ", 1)
                if len(parts) == 2:
                    observed[parts[1]] = parts[0]
    missing = sorted(set(expected) - set(observed))
    unexpected = sorted(set(observed) - set(expected))
    changed = sorted(rel for rel in expected if rel in observed and expected[rel] != observed[rel])
    settings_expected = sha256_bytes(settings_bytes) if settings_bytes is not None else None
    settings_seen = None
    settings_path = os.path.join(run_dir, "settings-in.sha256")
    if os.path.exists(settings_path):
        with open(settings_path, "r", encoding="utf-8") as handle:
            text = handle.read().split()
            settings_seen = text[0] if text else None
    settings_match = settings_expected == settings_seen
    return {
        "ok": not missing and not unexpected and not changed and settings_match,
        "files_expected": len(expected),
        "files_observed": len(observed),
        "missing": missing,
        "unexpected": unexpected,
        "changed": changed,
        "settings_sha256_expected": settings_expected,
        "settings_sha256_in_container": settings_seen,
        "settings_match": settings_match,
    }


def run_and_grade(ctx, spec, task, material_dir, arm_dirs, settings_bytes, permission_mode, run_dir):
    """Session, trace, patch extraction, teardown, grade. Returns (row, details)."""
    os.makedirs(run_dir, exist_ok=True)
    row = empty_row(spec, task)
    prompt = scored_prompt(ctx, task, material_dir, arm_dirs)
    gold_files = task["gold_files"]
    details = {
        "prompt_sha256": sha256_bytes(prompt),
        "settings_sha256": sha256_bytes(settings_bytes) if settings_bytes is not None else None,
        "arm_sha256": [tree_digest(path) for path in arm_dirs],
        "permission_mode": permission_mode,
        "limit_turns": ctx.limit_turns,
        "limit_seconds": ctx.limit_seconds,
    }
    with open(os.path.join(run_dir, "prompt.txt"), "wb") as handle:
        handle.write(prompt)
    session = None
    try:
        session = ses.run_session(ctx, spec["run_id"], task, prompt, arm_dirs, settings_bytes, permission_mode, run_dir)
        details.update({
            "image": session["image"], "image_id": session["image_id"],
            "exit_code": session["exit_code"], "host_timeout": session["host_timeout"],
        })
        row["harness_bytes"] = session["harness_bytes"]
        row["wall_seconds"] = session["wall_seconds"]
        if getattr(ctx, "protocol", 1) == 2:
            check = check_harness_files(arm_dirs, settings_bytes, run_dir)
            details["harness_check"] = check
            write_json_atomic(os.path.join(run_dir, "harness_check.json"), check)
            if spec["arm"] in EXPORTED_SETTINGS_ARMS:
                exported = ctx.olivium_exported_settings(spec["task_id"], spec["arm"])
                details["exported_settings_sha256"] = sha256_bytes(exported)
                details["settings_equal_exported"] = (settings_bytes == exported)
                if not details["settings_equal_exported"]:
                    check["ok"] = False
            if not check["ok"]:
                # The harness did not reach the container as the protocol requires.
                details["error"] = "harness files or settings did not match the arm (%s)" % check
                details["classified_status"] = "infra_error"
                row["status"] = "infra_error"
                return row, details
        rows = ctx.meter.rows_for(spec["run_id"])
        meterctl.dump_rows(os.path.join(run_dir, "meter_rows.jsonl"), rows)
        usage = meterctl.usage_summary(rows)
        row.update({"tokens": usage["tokens"], "cost_usd": usage["cost_usd"], "requests": usage["requests"]})
        models = [item.get("model") for item in rows if item.get("model") and item.get("endpoint") == "messages"]
        if models:
            # Not rows[0]: Claude Code may open with a background call on the small model.
            row["model"] = max(sorted(set(models)), key=models.count)
        trace = transcript.analyze(
            os.path.join(run_dir, "transcript.jsonl"), gold_files, grader.repo_file_set(material_dir),
        )
        write_json_atomic(os.path.join(run_dir, "trace.json"), trace)
        row.update({
            "turns": trace["turns"],
            "tool_calls": trace["tool_calls"],
            "files_read": trace["files_read"],
            "wasted_reads": trace["wasted_reads"],
            "turns_before_first_gold_edit": trace["turns_before_first_gold_edit"],
            "tool_calls_before_first_gold_edit": trace["tool_calls_before_first_gold_edit"],
            "claude_code_version": trace["claude_code_version"],
            "permission_denials": trace["permission_denials"],
            "hook_blocks": trace["hook_blocks"],
        })
        details["permission_mode_observed"] = trace.get("permission_mode")
        details["hook_events"] = trace.get("hook_events")
        details["permission_denied_tools"] = trace.get("permission_denied_tools")
        if protocol_v3(ctx) and trace["claude_code_version"] != CLAUDE_CODE_VERSION:
            # Protocol 3 pins Claude Code; a run on another version measures something else.
            details["error"] = "%s: the transcript reports %s, the protocol pins %s" % (
                VERSION_PIN_ERROR, trace["claude_code_version"], CLAUDE_CODE_VERSION)
            details["classified_status"] = "infra_error"
            row["status"] = "infra_error"
            return row, details
        status = transcript.classify(session["exit_code"], session["host_timeout"], trace, rows)
        details["classified_status"] = status
        details["claude_code_total_cost_usd"] = (trace.get("result") or {}).get("total_cost_usd")
        row["status"] = status
        if getattr(ctx, "protocol", 1) == 2:
            row["web_tool_uses"] = trace.get("web_tool_uses", 0)
            details["init_web_tools"] = trace.get("init_web_tools")
            details["web_tool_uses"] = trace.get("web_tool_uses", 0)
            details["meter_server_tools"] = sorted({name for item in rows for name in (item.get("server_tools") or [])})
            problems = transcript.web_guard(trace, rows)
            if problems:
                # PROTOCOL-v2.md, change log: no arm may have the web. This is a benchmark failure.
                details["error"] = "%s: %s" % (WEB_GUARD_ERROR, "; ".join(problems))
                details["classified_status"] = "infra_error"
                row["status"] = "infra_error"
                return row, details
        if status == "infra_error":
            return row, details
        patch_path = grader.extract_patch(ctx, task, session["container"], run_dir)
        dk.remove(session["container"])
        session = None
        with open(patch_path, "r", encoding="utf-8", errors="replace") as handle:
            patch_text = handle.read()
        row["patch_lines"] = transcript.patch_line_count(patch_text)
        result = grader.grade(ctx, task, patch_path, material_dir, run_dir,
                              test_timeout_s=GRADE_TEST_TIMEOUT_V3_S if protocol_v3(ctx) else None)
        details["grade"] = result
        write_json_atomic(os.path.join(run_dir, "grade.json"), result)
        if result.get("status") != "ok":
            row["status"] = "infra_error"
            return row, details
        row["f2p_passed"] = result["f2p_passed"]
        row["f2p_total"] = result["f2p_total"]
        row["p2p_regressions"] = result["p2p_regressions"]
        row["lint_ok"] = result["lint_ok"]
        row["solved"] = bool(result["solved"]) and status == "completed"
        return row, details
    except (dk.DockerError, BenchError, OSError, ValueError) as exc:
        details["error"] = "%s: %s" % (type(exc).__name__, str(exc)[:500])
        row["status"] = "infra_error"
        return row, details
    finally:
        if session is not None:
            dk.remove(session["container"])


def _recorded_error(ctx, run_id):
    path = os.path.join(ctx.trial_dir(run_id), "details.json")
    if not os.path.exists(path):
        return ""
    with open(path, "r", encoding="utf-8") as handle:
        return str(json.load(handle).get("error") or "")


def web_guard_failed(ctx, run_id):
    """True when this trial was stopped because a web tool reached it (protocol v2)."""
    return _recorded_error(ctx, run_id).startswith(WEB_GUARD_ERROR)


def version_pin_failed(ctx, run_id):
    """True when this trial ran another Claude Code than the pinned one (protocol 3)."""
    return _recorded_error(ctx, run_id).startswith(VERSION_PIN_ERROR)


def execute_trial(ctx, spec, task, material_dir):
    """Run one scored trial and append its row to trials.jsonl."""
    run_dir = ctx.trial_dir(spec["run_id"])
    os.makedirs(run_dir, exist_ok=True)
    state = dict(spec, stage="running", started_at=now_iso())
    write_json_atomic(os.path.join(run_dir, "state.json"), state)
    arm_dirs = [] if spec["arm"] in FILELESS_ARMS else [ctx.arm_dir(spec["task_id"], spec["arm"])]
    settings_bytes, permission_mode = ctx.arm_run_config(spec["task_id"], spec["arm"])
    row, details = run_and_grade(
        ctx, spec, task, material_dir, arm_dirs, settings_bytes, permission_mode, run_dir,
    )
    append_jsonl(ctx.trials_path, label_row(ctx, row))
    finished = dict(state, stage="done", finished_at=now_iso(), status=row["status"])
    write_json_atomic(os.path.join(run_dir, "state.json"), finished)
    write_json_atomic(os.path.join(run_dir, "details.json"), details)
    append_jsonl(ctx.attempts_path, label_row(ctx, {
        "run_id": spec["run_id"], "task_id": spec["task_id"], "arm": spec["arm"],
        "repeat": spec["repeat"], "attempt": spec["attempt"], "status": row["status"],
        "error": details.get("error"), "started_at": state["started_at"],
        "finished_at": finished["finished_at"], "image_id": details.get("image_id"),
        "prompt_sha256": details.get("prompt_sha256"),
    }))
    return row


def finalize_interrupted(ctx, tasks_by_id):
    """A run directory with no recorded row was interrupted: score it infra_error."""
    recorded = {row.get("run_id") for row in read_jsonl(ctx.trials_path)}
    base = os.path.join(ctx.out, "trials")
    if not os.path.isdir(base):
        return []
    finalized = []
    for name in sorted(os.listdir(base)):
        state_path = os.path.join(base, name, "state.json")
        if name in recorded or not os.path.exists(state_path):
            continue
        import json

        with open(state_path, "r", encoding="utf-8") as handle:
            state = json.load(handle)
        task = tasks_by_id.get(state.get("task_id"))
        if task is None:
            continue
        row = empty_row(state, task)
        rows = ctx.meter.rows_for(state["run_id"]) if ctx.meter is not None else []
        if rows:
            usage = meterctl.usage_summary(rows)
            row.update({"tokens": usage["tokens"], "cost_usd": usage["cost_usd"], "requests": usage["requests"]})
        row["status"] = "infra_error"
        append_jsonl(ctx.trials_path, label_row(ctx, row))
        append_jsonl(ctx.attempts_path, label_row(ctx, {
            "run_id": state["run_id"], "task_id": state["task_id"], "arm": state["arm"],
            "repeat": state["repeat"], "attempt": state.get("attempt"), "status": "infra_error",
            "error": "interrupted before a result was recorded",
            "started_at": state.get("started_at"), "finished_at": now_iso(),
        }))
        write_json_atomic(state_path, dict(state, stage="done", status="infra_error", finished_at=now_iso()))
        finalized.append(state["run_id"])
    return finalized
