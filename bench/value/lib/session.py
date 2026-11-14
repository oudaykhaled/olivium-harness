"""One isolated Claude Code session in an agent container, via docker cp only."""

import os
import time

from lib.common import AGENT_LIMITS, ARMS_DIR, MODEL, BenchError, tree_files
from lib import dockerops as dk

DUMMY_KEY = "olivium-bench-dummy-key"
AGENT_UID = 1001
MAX_OUT_ARCHIVE = 1 << 30


def arm_entries(arm_dir):
    """Tar entries (arcname under in/arm/) for an arm's files, and their total bytes."""
    entries = []
    total = 0
    for rel in tree_files(arm_dir):
        with open(os.path.join(arm_dir, rel), "rb") as handle:
            data = handle.read()
        total += len(data)
        entries.append(("in/arm/%s" % rel, data, 0o644))
    return entries, total


def run_session(ctx, run_id, task, prompt, arm_dirs, settings_bytes, permission_mode, run_dir):
    """Create, copy in, start, wait, and copy out the agent's /work/out.

    Returns a dict with the container name (still present; the caller removes
    it), exit_code, host_timeout, wall_seconds and harness_bytes.
    """
    name = "olivium-bench-agent-%s-%s" % (ctx.tag, _short(run_id))
    dk.remove(name)
    env = {
        "ANTHROPIC_BASE_URL": "http://meter:8080/run/%s" % run_id,
        "ANTHROPIC_API_KEY": DUMMY_KEY,
        "BENCH_MODEL": MODEL,
        "BENCH_MAX_TURNS": str(ctx.limit_turns),
        "BENCH_TIMEOUT_S": str(ctx.limit_seconds),
        "BENCH_PERMISSION_MODE": permission_mode,
    }
    if getattr(ctx, "protocol", 1) == 2:
        # PROTOCOL-v2.md: plain `uv run` needs the network offline without this, in every arm.
        env["UV_NO_SYNC"] = "1"
        # Records hook lifecycle events in the transcript; adds events, not behaviour.
        env["BENCH_INCLUDE_HOOK_EVENTS"] = "1"
        # Removes WebSearch and WebFetch in every arm and in /init alike (PROTOCOL-v2.md,
        # change log): WebSearch would reach the open internet through the API.
        env["BENCH_DISALLOW_WEB"] = "1"
    image = ctx.agent_image(task)
    entries = [("in/prompt.txt", prompt, 0o644)]
    with open(os.path.join(ARMS_DIR, "entry.sh"), "rb") as handle:
        entries.append(("in/entry.sh", handle.read(), 0o755))
    if settings_bytes is not None:
        entries.append(("in/settings.json", settings_bytes, 0o644))
    harness_bytes = 0
    for arm_dir in arm_dirs:
        items, total = arm_entries(arm_dir)
        entries.extend(items)
        harness_bytes += total
    dk.create(
        name, image, network=ctx.meter.internal,
        memory=AGENT_LIMITS["memory"], cpus=AGENT_LIMITS["cpus"], pids=AGENT_LIMITS["pids"],
        env=env, command=["/bin/bash", "/work/in/entry.sh"],
    )
    dk.cp_in(name, "/work", dk.make_tar(entries, uid=AGENT_UID, gid=AGENT_UID), archive=True)
    started = time.time()
    dk.start(name)
    exit_code = dk.wait(name, timeout=ctx.limit_seconds + 120)
    host_timeout = exit_code is None
    if host_timeout:
        dk.kill(name)
        exit_code = dk.wait(name, timeout=60)
    host_elapsed = time.time() - started
    tar_path = os.path.join(run_dir, "out.tar")
    dk.cp_out_file(name, "/work/out", tar_path)
    if os.path.getsize(tar_path) > MAX_OUT_ARCHIVE:
        raise BenchError("agent output archive too large")
    written = dk.extract_members(
        tar_path,
        {"transcript.jsonl": "transcript.jsonl", "stderr.log": "stderr.log",
         "exit_code": "exit_code", "wall_seconds": "wall_seconds",
         "harness-files.sha256": "harness-files.sha256", "settings-in.sha256": "settings-in.sha256"},
        run_dir,
    )
    os.unlink(tar_path)
    wall = None
    wall_path = os.path.join(run_dir, "wall_seconds")
    if "wall_seconds" in written:
        with open(wall_path, "r", encoding="ascii", errors="replace") as handle:
            text = handle.read().strip()
        if text.isdigit():
            wall = float(text)
    if "transcript.jsonl" not in written:
        open(os.path.join(run_dir, "transcript.jsonl"), "a").close()
    return {
        "container": name,
        "exit_code": exit_code,
        "host_timeout": host_timeout,
        "wall_seconds": wall if wall is not None else host_elapsed,
        "harness_bytes": harness_bytes,
        "image": image,
        "image_id": dk.image_id(image),
    }


def _short(run_id):
    return run_id[-40:].replace(".", "-")
