"""What protocol 3 (benchmark v3) adds to the protocol-2 code path of the runner.

Protocol 3 runs exactly the protocol-2 code path for every session: the olivium arm
installed as exported with its own settings, the web tools removed in every arm and in
/init, hook events recorded, UV_NO_SYNC. On top of it:

- One OUT, one purpose. OUT/protocol.json records whether OUT holds a pilot (no-harness
  runs that set task difficulty, then discarded) or a scored run, and the manifest it
  was made for. A later invocation with the other mode or another manifest is refused.
- A pilot runs the none arm only. Its rows carry "pilot": true. Each selection of tasks
  and repeats keeps its own schedule file, so stage 2 of the difficulty filter can add
  repeats 2 and 3 for the remaining tasks in the same OUT.
- A scored run names at least two setups, and they are interleaved: the schedule is a
  seeded sequence of blocks, one block per (task, repeat), each holding every setup
  once in a seeded order. No setup runs in a stretch of its own.
- Claude Code is pinned to CLAUDE_CODE_VERSION: every agent image is asked
  `claude --version` (in a container without network) before a session starts, and
  every trial whose transcript reports another version is an infra_error that stops
  the run.
- The per-task trim: `run.py trim` measures, at $0 with the mock meter, each task's
  first model request in the none and olivium setups and writes OUT/trim.json (format
  below). A paid scored run refuses to start without a trim that matches OUT's olivium
  exports.

OUT/trim.json, format "olivium-bench-trim-v1":

  {"format": "olivium-bench-trim-v1", "protocol": 3, "method": "shape_capture",
   "claude_code_version": "2.1.311", "calibration": {...}, "baseline_arm": "none",
   "measured_arms": ["none", "olivium"],
   "tasks": {TASK: {"trim_tokens": int, "trim_bytes": int,
                    "trim_system_tools_tokens": int, "trim_messages_tokens": int,
                    ["trim_lean_tokens": int,]
                    "arms": {ARM: {"run_id", "settings_sha256", "arm_sha256",
                                   "permission_mode", "capture_file", "body_sha256",
                                   "system_bytes", "tools_bytes", "messages_bytes",
                                   "system_tools_bytes", "est_tokens", "tool_names",
                                   "claude_code_version"}}}}}

trim_tokens = arms.none.est_tokens - arms.olivium.est_tokens: the estimated tokens the
olivium setup sends less than none on every request. Bytes are exact; tokens are an
estimate with the stage 0 probe calibration: the system prompt plus the tools array at
2.78 bytes per token (the shared cached prefix of every live v2 run: 35,441 bytes, 12,754
tokens), message text at 2.46 bytes per token (least-squares slope over 24 live first
requests, R2 0.997). The slope has an intercept, so an absolute est_tokens runs 412 to 531
tokens above the live count on those 24 requests; a difference between two setups of one
task cancels it.

Host code is the standard library only; Docker is reached through lib.dockerops.
"""

import datetime
import hashlib
import json
import os
import random
import re
import shutil
import types

from lib.common import (
    ARMS,
    CLAUDE_CODE_VERSION,
    FILELESS_ARMS,
    NONE_LEAN,
    BenchError,
    manifest_checksum,
    out_tag,
    read_json,
    sha256_bytes,
    sha256_file,
    tree_digest,
    write_json_atomic,
)
from lib import dockerops as dk
from lib import meterctl
from lib import session as ses
from lib import transcript
from lib import trials as trial_ops

PROTOCOL = 3
RECORD_FILE = "protocol.json"
RECORD_FORMAT = "olivium-bench-out-v3"
VERSIONS_FILE = "claude-code-version.json"
TRIM_FILE = "trim.json"
TRIM_DIR = "trim"
TRIM_FORMAT = "olivium-bench-trim-v1"
TRIM_ARMS = ("none", "olivium", NONE_LEAN)
SYSTEM_TOOLS_BYTES_PER_TOKEN = 2.78
MESSAGES_BYTES_PER_TOKEN = 2.46
PILOT_ARMS = ("none",)
# The unscored control setup runs in the blocks of repeat 1 only (PROTOCOL-v3.md, change log
# of 2026-11-11, attribution): one none-lean run per task beside the scored setups.
SECONDARY_REPEATS = {NONE_LEAN: 1}
SCHEDULE_DESIGN = ("blocks: one per (task, repeat) in seeded order, each running every setup once in seeded order; "
                   "none-lean, unscored, only in the blocks of repeat 1")


def is_v3(ctx):
    return getattr(ctx, "protocol_version", None) == PROTOCOL


def now_iso():
    return datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"


# ----------------------------------------------------------------- selection
def pilot_arms(text):
    """The pilot runs the none arm only."""
    names = [name.strip() for name in (text or "none").split(",") if name.strip()]
    if names != ["none"]:
        raise BenchError("a pilot runs the none arm only (got --arms %s)" % (text or ""))
    return PILOT_ARMS


def check_scored_selection(ctx):
    """A scored run interleaves setups, so it never runs one setup on its own."""
    if ctx.pilot:
        return
    if len(ctx.arms) < 2:
        raise BenchError(
            "protocol 3 refuses a scored run with a single setup (%s): setups are always "
            "interleaved, so name at least two with --arms (default: %s), or pass --pilot "
            "for no-harness pilot runs" % (", ".join(ctx.arms), ",".join(ARMS))
        )


# ---------------------------------------------------------------- OUT record
def ensure_out_record(ctx):
    """OUT serves one purpose: a pilot or a scored run, for one manifest."""
    path = os.path.join(ctx.out, RECORD_FILE)
    mode = "pilot" if ctx.pilot else "scored"
    checksum = manifest_checksum(ctx.manifest)
    if os.path.exists(path):
        record = read_json(path)
        if record.get("protocol") != PROTOCOL:
            raise BenchError("%s was not written by protocol 3" % path)
        if record.get("mode") != mode:
            raise BenchError(
                "this OUT holds a %s run (%s); a %s run needs its own OUT"
                % (record.get("mode"), path, mode)
            )
        if record.get("manifest_checksum") != checksum:
            raise BenchError("this OUT was made for another manifest (%s)" % path)
        return record
    if os.path.exists(os.path.join(ctx.out, "trials.jsonl")):
        raise BenchError("OUT already holds trials of another protocol; protocol 3 needs a fresh OUT")
    record = {
        "format": RECORD_FORMAT,
        "protocol": PROTOCOL,
        "mode": mode,
        "pilot": ctx.pilot,
        "manifest_checksum": checksum,
        "claude_code_version": CLAUDE_CODE_VERSION,
        "created_at": now_iso(),
        "note": "pilot rows set task difficulty and are discarded; only a scored OUT is analysed",
    }
    write_json_atomic(path, record)
    return record


def read_out_record(ctx):
    path = os.path.join(ctx.out, RECORD_FILE)
    return read_json(path) if os.path.exists(path) else None


# ------------------------------------------------------------------ schedule
def block_schedule(task_ids, arms, repeats, seed, secondary_repeats=None):
    """Seeded blocks of (task, repeat), each holding every setup once in a seeded order.

    secondary_repeats limits a setup to the blocks of its first N repeats (none-lean: 1).
    Without it, or for a selection without such a setup, the order is unchanged.
    """
    limits = secondary_repeats or {}
    rng = random.Random(seed)
    blocks = [(task_id, repeat) for task_id in task_ids for repeat in range(1, repeats + 1)]
    rng.shuffle(blocks)
    order = []
    for task_id, repeat in blocks:
        names = [arm for arm in arms if repeat <= limits.get(arm, repeats)]
        rng.shuffle(names)
        order.extend((task_id, arm, repeat) for arm in names)
    return order


def schedule_name(ctx, default_name):
    """A pilot keeps one schedule per selection of tasks and repeats; a scored run as protocol 2."""
    if not ctx.pilot:
        return default_name
    key = json.dumps({"tasks": [task["task_id"] for task in ctx.tasks], "repeats": ctx.repeats, "seed": ctx.seed},
                     sort_keys=True, separators=(",", ":"))
    return "schedule.pilot.%s.json" % hashlib.sha256(key.encode("utf-8")).hexdigest()[:12]


def schedule_extra(ctx):
    return {"protocol": PROTOCOL, "mode": "pilot" if ctx.pilot else "scored", "arms": list(ctx.arms),
            "design": SCHEDULE_DESIGN}


def longest_stretch(order):
    """The longest run of consecutive scheduled trials of one setup."""
    best = run = 0
    previous = None
    for _task_id, arm, _repeat in order:
        run = run + 1 if arm == previous else 1
        previous = arm
        best = max(best, run)
    return best


# ------------------------------------------------- nothing else on Docker
# Containers of the v3 selection (corpus/v3lib.py): validation runs, lint, the pytest flag
# probe and gold grading. A paid run never starts beside them (PROTOCOL-v3.md, change log of
# 2026-11-11, grading time limit): load from the walk slowed grading by up to a third.
SELECTION_CONTAINER = re.compile(r"^olivium-bench-(?:v3val|v3lint|v3flag|grade-v3gold)-")


def selection_busy():
    """Names of running selection containers; a paid protocol 3 run refuses to start beside them."""
    done = dk.docker("ps", "--format", "{{.Names}}", timeout=60)
    names = done.stdout.decode("utf-8", "replace").split()
    return sorted(name for name in names if SELECTION_CONTAINER.match(name))


# ---------------------------------------------------------------- the pin
def pin_claude_code(ctx):
    """Every agent image runs the pinned Claude Code. Asked once per image id; refused otherwise."""
    path = os.path.join(ctx.out, VERSIONS_FILE)
    record = read_json(path) if os.path.exists(path) else {}
    images = dict(record.get("images") or {})
    problems = []
    for task in ctx.tasks:
        image = ctx.agent_image(task)
        image_id = dk.image_id(image)
        if image_id is None:
            problems.append("image %s is missing" % image)
            continue
        seen = images.get(image_id)
        if not seen or seen.get("version") != CLAUDE_CODE_VERSION:
            name = "olivium-bench-version-%s" % ctx.tag
            dk.remove(name)
            done = dk.docker(
                "run", "--rm", "--name", name, "--label", dk.LABEL, "--network", "none",
                "--entrypoint", "claude", image, "--version", check=False, timeout=300,
            )
            words = done.stdout.decode("utf-8", "replace").split() if done.returncode == 0 else []
            seen = {"image": image, "version": words[0] if words else None, "checked_at": now_iso()}
            images[image_id] = seen
        if seen.get("version") != CLAUDE_CODE_VERSION:
            problems.append("%s runs Claude Code %s, not the pinned %s" % (image, seen.get("version"), CLAUDE_CODE_VERSION))
    write_json_atomic(path, {"pinned": CLAUDE_CODE_VERSION, "images": images})
    if problems:
        raise BenchError("Claude Code pin: %s" % "; ".join(problems))


# --------------------------------------------------------------------- trim
def _utf8(text):
    return len(text.encode("utf-8"))


def _texts(content):
    if isinstance(content, str):
        return [content]
    out = []
    for block in content or []:
        if isinstance(block, dict) and isinstance(block.get("text"), str):
            out.append(block["text"])
        else:
            out.append(json.dumps(block, ensure_ascii=False))
    return out


def request_shape(body):
    """Exact byte counts of one Messages request body, as the probe calibration measured them."""
    system = body.get("system")
    if isinstance(system, str):
        system_bytes = _utf8(system)
    else:
        system_bytes = sum(_utf8(block.get("text", "")) for block in system or []
                           if isinstance(block, dict) and isinstance(block.get("text", ""), str))
    tools = body.get("tools") or []
    tools_bytes = _utf8(json.dumps(tools, ensure_ascii=False, separators=(",", ":")))
    messages_bytes = sum(_utf8(text) for message in body.get("messages") or [] if isinstance(message, dict)
                         for text in _texts(message.get("content")))
    system_tools = system_bytes + tools_bytes
    return {
        "system_bytes": system_bytes,
        "tools_bytes": tools_bytes,
        "messages_bytes": messages_bytes,
        "system_tools_bytes": system_tools,
        "est_tokens": int(round(system_tools / SYSTEM_TOOLS_BYTES_PER_TOKEN + messages_bytes / MESSAGES_BYTES_PER_TOKEN)),
        "tool_names": sorted(str(tool.get("name")) for tool in tools if isinstance(tool, dict)),
    }


def first_main_request(capture_dir):
    """(file name, body) of the first captured request that offers both Read and Edit."""
    if not os.path.isdir(capture_dir):
        return None
    for name in sorted(os.listdir(capture_dir)):
        if not (name.startswith("req-") and name.endswith(".json")):
            continue
        with open(os.path.join(capture_dir, name), "r", encoding="utf-8") as handle:
            body = (json.load(handle) or {}).get("body") or {}
        names = {tool.get("name") for tool in body.get("tools") or [] if isinstance(tool, dict)}
        if {"Read", "Edit"} <= names:
            return name, body
    return None


def trim_arms(ctx):
    arms = [arm for arm in ctx.arms if arm in TRIM_ARMS]
    if "none" not in arms or "olivium" not in arms:
        raise BenchError("trim compares none with olivium: --arms must name both (got %s)" % ",".join(ctx.arms))
    return arms


def _trim_session(ctx, tctx, task, arm, trim_out):
    task_id = task["task_id"]
    run_id = "trim.%s.%s" % (task_id, arm)
    run_dir = os.path.join(trim_out, "runs", run_id)
    capture_dir = os.path.join(trim_out, "capture", run_id)
    for path in (run_dir, capture_dir):
        shutil.rmtree(path, ignore_errors=True)
    os.makedirs(run_dir)
    arm_dirs = [] if arm in FILELESS_ARMS else [ctx.arm_dir(task_id, arm)]
    settings_bytes, permission_mode = ctx.arm_run_config(task_id, arm)
    prompt = trial_ops.scored_prompt(tctx, task, ctx.material_dir(task_id))
    session = None
    try:
        session = ses.run_session(tctx, run_id, task, prompt, arm_dirs, settings_bytes, permission_mode, run_dir)
        check = trial_ops.check_harness_files(arm_dirs, settings_bytes, run_dir)
        write_json_atomic(os.path.join(run_dir, "harness_check.json"), check)
        if not check["ok"]:
            raise BenchError("trim session %s: the harness did not reach the container as the arm has it" % run_id)
        tctx.meter.copy_capture(run_id, capture_dir)
    finally:
        if session is not None:
            dk.remove(session["container"])
    trace = transcript.analyze(os.path.join(run_dir, "transcript.jsonl"), [], None)
    version = trace.get("claude_code_version")
    if version != CLAUDE_CODE_VERSION:
        raise BenchError("trim session %s ran Claude Code %s, not the pinned %s" % (run_id, version, CLAUDE_CODE_VERSION))
    found = first_main_request(capture_dir)
    if found is None:
        raise BenchError("trim session %s: no captured request offers Read and Edit" % run_id)
    name, body = found
    capture_file = os.path.join(capture_dir, name)
    entry = {
        "run_id": run_id,
        "settings_sha256": sha256_bytes(settings_bytes) if settings_bytes is not None else None,
        "arm_sha256": [tree_digest(path) for path in arm_dirs],
        "permission_mode": permission_mode,
        "capture_file": os.path.relpath(capture_file, ctx.out),
        "body_sha256": sha256_file(capture_file),
        "claude_code_version": version,
    }
    entry.update(request_shape(body))
    return entry


def task_trim(arms):
    none = arms["none"]
    olivium = arms["olivium"]
    entry = {
        "trim_tokens": none["est_tokens"] - olivium["est_tokens"],
        "trim_bytes": (none["system_tools_bytes"] + none["messages_bytes"]) - (olivium["system_tools_bytes"] + olivium["messages_bytes"]),
        "trim_system_tools_tokens": int(round((none["system_tools_bytes"] - olivium["system_tools_bytes"]) / SYSTEM_TOOLS_BYTES_PER_TOKEN)),
        "trim_messages_tokens": int(round((none["messages_bytes"] - olivium["messages_bytes"]) / MESSAGES_BYTES_PER_TOKEN)),
        "arms": arms,
    }
    if NONE_LEAN in arms:
        entry["trim_lean_tokens"] = none["est_tokens"] - arms[NONE_LEAN]["est_tokens"]
    return entry


def measure_trim(ctx, run_cap_usd, total_cap_usd):
    """Mock meter, request capture, one shape session per task and setup; writes OUT/trim.json."""
    arms = trim_arms(ctx)
    trim_out = os.path.join(ctx.out, TRIM_DIR)
    os.makedirs(trim_out, exist_ok=True)
    tag = out_tag(trim_out)
    # A meter of its own (its own log under OUT/trim/meter), so mock rows never reach the
    # scored run's request log, its cap or its analysis.
    meter = meterctl.Meter(trim_out, tag, False, run_cap_usd, total_cap_usd, refuse_web_tools=True, capture=True)
    tctx = types.SimpleNamespace(
        tag=tag, limit_turns=ctx.limit_turns, limit_seconds=ctx.limit_seconds, protocol=2,
        agent_image=ctx.agent_image, meter=meter, paid=False, scenario="shape",
    )
    measured = {}
    for name in dk.leftover_names(tag, ["agent", "meter"]):
        dk.remove(name)
    meter.up()
    try:
        for task in ctx.tasks:
            per_arm = {}
            for arm in arms:
                print("trim: %s %s" % (task["task_id"], arm), flush=True)
                per_arm[arm] = _trim_session(ctx, tctx, task, arm, trim_out)
            measured[task["task_id"]] = task_trim(per_arm)
            print("trim: %s %d estimated tokens per request (none %d, olivium %d)" % (
                task["task_id"], measured[task["task_id"]]["trim_tokens"], per_arm["none"]["est_tokens"],
                per_arm["olivium"]["est_tokens"]), flush=True)
    finally:
        meter.down()
        for name in dk.leftover_names(tag, ["agent"]):
            dk.remove(name)
    path = os.path.join(ctx.out, TRIM_FILE)
    previous = read_json(path) if os.path.exists(path) else {}
    tasks = dict(previous.get("tasks") or {}) if previous.get("format") == TRIM_FORMAT else {}
    tasks.update(measured)
    payload = {
        "format": TRIM_FORMAT,
        "protocol": PROTOCOL,
        "method": "shape_capture",
        "claude_code_version": CLAUDE_CODE_VERSION,
        "calibration": {
            "system_tools_bytes_per_token": SYSTEM_TOOLS_BYTES_PER_TOKEN,
            "messages_bytes_per_token": MESSAGES_BYTES_PER_TOKEN,
            "source": "stage 0 probes: cached prefix 35,441 bytes = 12,754 live tokens; message slope over 24 live first requests, R2 0.997",
            "absolute_bias_tokens": [412, 531],
            "note": "est_tokens alone runs high by the slope's intercept; trim_* are differences of one task's setups, where it cancels",
        },
        "baseline_arm": "none",
        "measured_arms": sorted({arm for entry in tasks.values() for arm in entry["arms"]}, key=TRIM_ARMS.index),
        "measured_at": now_iso(),
        "tasks": dict(sorted(tasks.items())),
    }
    write_json_atomic(path, payload)
    return payload


def trim_problems(ctx):
    """Why OUT/trim.json does not cover this selection as it stands; [] when it does."""
    if "olivium" not in ctx.arms:
        return []
    path = os.path.join(ctx.out, TRIM_FILE)
    if not os.path.exists(path):
        return ["OUT/trim.json is missing (measure it at $0: run.py trim --protocol 3 --out OUT)"]
    data = read_json(path)
    if data.get("format") != TRIM_FORMAT or data.get("claude_code_version") != CLAUDE_CODE_VERSION:
        return ["OUT/trim.json is not %s for Claude Code %s" % (TRIM_FORMAT, CLAUDE_CODE_VERSION)]
    problems = []
    for task in ctx.tasks:
        task_id = task["task_id"]
        entry = (data.get("tasks") or {}).get(task_id)
        if not entry:
            problems.append("no trim for %s" % task_id)
            continue
        for arm in ("none", "olivium"):
            seen = (entry.get("arms") or {}).get(arm) or {}
            settings_bytes, _mode = ctx.arm_run_config(task_id, arm)
            arm_dirs = [] if arm in FILELESS_ARMS else [ctx.arm_dir(task_id, arm)]
            if seen.get("settings_sha256") != sha256_bytes(settings_bytes):
                problems.append("trim of %s was measured with other %s settings" % (task_id, arm))
            elif seen.get("arm_sha256") != [tree_digest(path) for path in arm_dirs]:
                problems.append("trim of %s was measured on another %s arm" % (task_id, arm))
    return problems


def trim_summary(ctx):
    path = os.path.join(ctx.out, TRIM_FILE)
    if not os.path.exists(path):
        return {"present": False}
    data = read_json(path)
    tasks = data.get("tasks") or {}
    return {
        "present": True,
        "tasks": len(tasks),
        "trim_tokens": {task_id: entry.get("trim_tokens") for task_id, entry in sorted(tasks.items())},
        "problems": trim_problems(ctx),
    }


__all__ = [
    "PROTOCOL", "TRIM_FILE", "TRIM_FORMAT", "block_schedule", "check_scored_selection", "ensure_out_record",
    "is_v3", "longest_stretch", "measure_trim", "pilot_arms", "pin_claude_code", "read_out_record",
    "request_shape", "first_main_request", "schedule_extra", "schedule_name", "trim_problems", "trim_summary",
]
