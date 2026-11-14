"""The generic arm: Claude Code's own /init, in isolation, through the meter."""

import os
import shutil

from lib.common import GENERIC_PROMPT, MODEL, BenchError, read_jsonl, tree_bytes, tree_digest, tree_files
from lib import dockerops as dk
from lib import meterctl
from lib import mockplans
from lib import session as ses
from lib import transcript


def usage_so_far(ctx, task_id):
    """Meter usage of every /init attempt for this task, including failed ones."""
    if ctx.meter is not None:
        ctx.meter.sync_log()
    base_run_id = "setup-generic.%s" % task_id
    rows = [row for row in read_jsonl(os.path.join(ctx.out, "meter", "requests.jsonl"))
            if str(row.get("run_id", "")).startswith(base_run_id)]
    return meterctl.usage_summary(rows)


def build(ctx, task, material_dir):
    task_id = task["task_id"]
    base_run_id = "setup-generic.%s" % task_id
    prior_ids = {row.get("run_id") for row in read_jsonl(ctx.meter.log_path)
                 if str(row.get("run_id", "")).startswith(base_run_id)}
    run_id = base_run_id if not prior_ids else "%s.a%d" % (base_run_id, len(prior_ids) + 1)
    run_dir = os.path.join(ctx.out, "setup", "generic", task_id)
    shutil.rmtree(run_dir, ignore_errors=True)
    os.makedirs(run_dir)

    prompt = GENERIC_PROMPT.encode("utf-8")
    if not ctx.paid:
        prompt = ("/init\n\n%s\n" % mockplans.plan_marker(mockplans.init_plan())).encode("utf-8")
    session = None
    try:
        session = ses.run_session(
            ctx, run_id, task, prompt, arm_dirs=[], settings_bytes=ctx.settings_bytes(),
            permission_mode="bypassPermissions", run_dir=run_dir,
        )
        out_tar = os.path.join(run_dir, "claude_md.tar")
        dk.cp_out_file(session["container"], "/work/repo/CLAUDE.md", out_tar, timeout=120)
        written = dk.extract_members(
            out_tar, {"CLAUDE.md": "CLAUDE.md"}, run_dir, max_member_bytes=1 << 20,
        )
        os.unlink(out_tar)
    finally:
        if session is not None:
            dk.remove(session["container"])
    if "CLAUDE.md" not in written:
        raise BenchError("/init produced no CLAUDE.md for %s" % task_id)

    arm_dir = ctx.arm_dir(task_id, "generic")
    shutil.rmtree(arm_dir, ignore_errors=True)
    os.makedirs(arm_dir)
    shutil.copy2(os.path.join(run_dir, "CLAUDE.md"), os.path.join(arm_dir, "CLAUDE.md"))

    rows = ctx.meter.rows_for(run_id)
    meterctl.dump_rows(os.path.join(run_dir, "meter_rows.jsonl"), rows)
    # Setup cost includes any earlier attempt for this task: that money was spent.
    all_rows = [row for row in read_jsonl(ctx.meter.log_path)
                if str(row.get("run_id", "")).startswith(base_run_id)]
    usage = meterctl.usage_summary(all_rows)
    trace = transcript.analyze(os.path.join(run_dir, "transcript.jsonl"), [], None)
    status = transcript.classify(session["exit_code"], session["host_timeout"], trace, rows)
    extra = {}
    if getattr(ctx, "protocol", 1) == 2:
        # PROTOCOL-v2.md, change log: /init runs without the web tools, like every arm.
        extra["init_web_tools"] = trace["init_web_tools"]
        extra["web_tool_uses"] = trace["web_tool_uses"]
        problems = transcript.web_guard(trace, rows)
        if problems:
            extra["error"] = "web tools reached /init: %s" % "; ".join(problems)
            status = "failed"
    return {
        **extra,
        "status": "ok" if status == "completed" else status,
        "arm": "generic",
        "task_id": task_id,
        "mode": "paid" if ctx.paid else "rehearsal",
        "rehearsal_fixture": not ctx.paid,
        "run_id": run_id,
        "model": MODEL,
        "turns": trace["turns"],
        "tokens": usage["tokens"],
        "cost_usd": usage["cost_usd"],
        "requests": usage["requests"],
        "wall_seconds": session["wall_seconds"],
        "claude_code_version": trace["claude_code_version"],
        "image_id": session["image_id"],
        "harness_files": tree_files(arm_dir),
        "harness_bytes": tree_bytes(arm_dir),
        "arm_sha256": tree_digest(arm_dir),
    }


__all__ = ["build", "read_jsonl"]
