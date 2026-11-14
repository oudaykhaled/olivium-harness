#!/usr/bin/env python3
"""Run setups once each against the MOCK meter with request capture, then compare shapes.

No model is called and no key is read: the meter runs in mock mode (it refuses a key
and refuses capture in live mode). Each setup is one real Claude Code session in the
task's agent image (Docker, internal network only), with the same prompt plus a
scripted mock plan that makes no tool call. The meter keeps each request body; this
script copies them out and runs shape.py.

  python3 bench/value/replay/shape_run.py --task pallets-click-3858 \\
      --setup none=none --setup none-again=none \\
      --setup fix=<bench-out>/value-v2-2026-11-10-fix/arms/pallets-click-3858/olivium \\
      --setup fix-lean=<bench-out>/value-v2-2026-11-10-fix/arms/pallets-click-3858/olivium+lean \\
      --prompt <bench-out>/value-v2-2026-11-10-fix/trials/pallets-click-3858.olivium.r1/prompt.txt \\
      --scenario shape --out DIR [shape.py check flags after --]

A setup is `none` (no harness: benchmark settings, bypassPermissions, as in v2) or an
arm directory (its files are installed into the repository as in v2; its
.claude/settings.json is also passed with --settings and permission mode is default).
Modifiers after the directory build a HAND VARIANT in OUT/variants/<name>, never the
generator's output, to check the mechanics before the generator emits them:
  +lean                    includeGitInstructions false and the 15 bare deny names
  +standard                the reverse: no includeGitInstructions key, none of the 15 deny names
  +env:ROLE=PROBE,...      a SessionStart environment check that mirrors the stage 1
                           contract (section 3) and lib/.../claude_code/hooks.ex, for
                           the listed roles and probe names
"""

import argparse
import json
import os
import shutil
import sys
import time
import types

HERE = os.path.dirname(os.path.abspath(__file__))
VALUE = os.path.dirname(HERE)
sys.path.insert(0, VALUE)
sys.path.insert(0, HERE)

from lib import dockerops as dk  # noqa: E402
from lib import meterctl, mockplans  # noqa: E402
from lib import session as ses  # noqa: E402
from lib.common import ARMS_DIR, out_tag  # noqa: E402

import shape as shape_mod  # noqa: E402

LEAN_DENY = ["CronCreate", "CronDelete", "CronList", "EnterWorktree", "ExitWorktree", "ListAgents", "Monitor",
             "NotebookEdit", "ReportFindings", "ScheduleWakeup", "SendMessage", "Skill", "Task", "TaskStop", "Workflow"]
ENV_SCRIPT = ".claude/hooks/olivium-env-check.sh"
ROLE_ORDER = ["test", "lint", "typecheck", "format", "interpreter"]
LABELS = {"test": "Testing", "lint": "Linting", "typecheck": "Type checking", "format": "Formatting"}
PROBE_OK = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-"
ENV_HEADER = """#!/bin/sh
# HAND VARIANT written by bench/value/replay/shape_run.py, mirroring the stage 1
# environment check. It only asks whether a name resolves; it runs nothing else.
d=${CLAUDE_PROJECT_DIR:-.}
resolves() {
  for n in "$@"; do
    command -v "$n" >/dev/null 2>&1 && return 0
    [ -x "$d/.venv/bin/$n" ] && return 0
    [ -x "$d/node_modules/.bin/$n" ] && return 0
  done
  return 1
}
"""


def script_command(script):
    return ('f="$CLAUDE_PROJECT_DIR/%s"; if [ -f "$f" ]; then /bin/sh "$f"; else echo "Olivium: %s is missing; '
            'this hook did not run." >&2; fi' % (script, script))


def env_lines(spec):
    """'test=pytest,typecheck=mypy' -> [(role, [probes])] in contract role order."""
    roles = {}
    for item in spec.split(","):
        role, _, probes = item.partition("=")
        names = [name for name in probes.split("/") if name]
        if role not in ROLE_ORDER or not names or any(not name or any(c not in PROBE_OK for c in name) for name in names):
            raise SystemExit("bad +env item: %s" % item)
        roles[role] = names
    return [(role, roles[role]) for role in ROLE_ORDER if role in roles]


def label(role, probe):
    if role == "interpreter":
        return "Python " + probe[len("python"):] if probe.startswith("python") else "The interpreter " + probe
    return LABELS[role]


def env_script(spec):
    text = ENV_HEADER
    for role, probes in env_lines(spec):
        line = "%s is not available here: %s is not installed. Skip it. Do not install it." % (label(role, probes[0]), probes[0])
        text += "resolves %s || printf '%%s\\n' '%s'\n" % (" ".join("'%s'" % p for p in probes), line)
    return text + "exit 0\n"


def build_setup(name, spec, variants_dir):
    """(arm_dirs, settings_bytes, permission_mode, description)."""
    if spec == "none":
        with open(os.path.join(ARMS_DIR, "benchmark-settings.json"), "rb") as handle:
            return [], handle.read(), "bypassPermissions", "no harness (v2 none arm)"
    parts = spec.split("+")
    source = os.path.realpath(os.path.expanduser(parts[0]))
    if not os.path.isfile(os.path.join(source, ".claude", "settings.json")):
        raise SystemExit("%s: no .claude/settings.json in %s" % (name, source))
    if len(parts) == 1:
        arm = source
        notes = "arm as exported"
    else:
        arm = os.path.join(variants_dir, name)
        shutil.copytree(source, arm, symlinks=False)
        settings_path = os.path.join(arm, ".claude", "settings.json")
        with open(settings_path, "r", encoding="utf-8") as handle:
            settings = json.load(handle)
        notes = ["HAND VARIANT of the arm"]
        for modifier in parts[1:]:
            if modifier == "lean":
                settings["includeGitInstructions"] = False
                permissions = settings.setdefault("permissions", {})
                permissions["deny"] = sorted(set(permissions.get("deny") or []) | set(LEAN_DENY))
                notes.append("lean")
            elif modifier == "standard":
                # The standard context profile of a lean export: git instructions and the 15 tools back.
                settings.pop("includeGitInstructions", None)
                permissions = settings.setdefault("permissions", {})
                permissions["deny"] = [rule for rule in permissions.get("deny") or [] if rule not in LEAN_DENY]
                notes.append("standard")
            elif modifier.startswith("env:"):
                os.makedirs(os.path.join(arm, ".claude", "hooks"), exist_ok=True)
                with open(os.path.join(arm, ENV_SCRIPT), "w", encoding="utf-8") as handle:
                    handle.write(env_script(modifier[4:]))
                settings.setdefault("hooks", {})["SessionStart"] = [
                    {"hooks": [{"type": "command", "command": script_command(ENV_SCRIPT), "timeout": 5}]}]
                notes.append("environment check " + modifier[4:])
            else:
                raise SystemExit("unknown modifier: %s" % modifier)
        with open(settings_path, "w", encoding="utf-8") as handle:
            json.dump(settings, handle, indent=2, sort_keys=True)
            handle.write("\n")
        notes = ", ".join(notes)
    with open(os.path.join(arm, ".claude", "settings.json"), "rb") as handle:
        return [arm], handle.read(), "default", notes


def main(argv):
    if "--" in argv:
        index = argv.index("--")
        argv, check_args = argv[:index], argv[index + 1:]
    else:
        check_args = []
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--task", required=True)
    parser.add_argument("--setup", action="append", required=True, help="NAME=none | NAME=ARM_DIR[+lean][+env:ROLE=PROBE,...]")
    parser.add_argument("--prompt", required=True, help="the task prompt (for example a recorded trial's prompt.txt)")
    parser.add_argument("--scenario", choices=list(mockplans.CAPTURE_SCENARIOS), default="shape")
    parser.add_argument("--out", required=True, help="fresh directory")
    parser.add_argument("--limit-seconds", type=int, default=300)
    args = parser.parse_args(argv)
    out = os.path.realpath(args.out)
    if os.path.exists(out):
        raise SystemExit("--out must not exist: %s" % out)
    image = "olivium-bench-agent-%s:v1" % args.task
    dk.image_id(image)
    os.makedirs(os.path.join(out, "variants"))
    with open(args.prompt, "r", encoding="utf-8") as handle:
        prompt = handle.read().rstrip("\n") + "\n"
    plan = mockplans.scenario_plan(args.scenario, {"task_id": args.task}, "")
    prompt = (prompt + "\n" + mockplans.plan_marker(plan) + "\n").encode("utf-8")
    setups = []
    for item in args.setup:
        name, _, spec = item.partition("=")
        if not name or not spec or not all(c.isalnum() or c in "-_" for c in name):
            raise SystemExit("bad --setup: %s" % item)
        setups.append((name,) + build_setup(name, spec, os.path.join(out, "variants")))
    tag = out_tag(out)
    meter = meterctl.Meter(out, tag, False, 5.0, 50.0, refuse_web_tools=True, capture=True)
    ctx = types.SimpleNamespace(tag=tag, limit_turns=3, limit_seconds=args.limit_seconds, protocol=2,
                                agent_image=lambda task: image, meter=meter, paid=False)
    runs = {}
    meter.up()
    try:
        for name, arm_dirs, settings_bytes, mode, notes in setups:
            run_id = "%s.%s.shape" % (args.task, name)
            run_dir = os.path.join(out, "runs", run_id)
            os.makedirs(run_dir)
            started = time.time()
            result = ses.run_session(ctx, run_id, {"task_id": args.task}, prompt, arm_dirs, settings_bytes, mode, run_dir)
            dk.remove(result["container"])
            names = meter.copy_capture(run_id, os.path.join(out, "capture", name))
            runs[name] = {"run_id": run_id, "notes": notes, "permission_mode": mode, "exit_code": result["exit_code"],
                          "seconds": round(time.time() - started, 1), "requests_captured": len(names)}
            print("%-14s exit=%s requests=%d  (%s)" % (name, result["exit_code"], len(names), notes), flush=True)
    finally:
        meter.down()
    with open(os.path.join(out, "runs.json"), "w", encoding="utf-8") as handle:
        json.dump({"task": args.task, "image": image, "scenario": args.scenario, "runs": runs}, handle, indent=2, sort_keys=True)
        handle.write("\n")
    shape_args = []
    for name, *_rest in setups:
        shape_args += ["--setup", "%s=%s" % (name, os.path.join(out, "capture", name))]
    return shape_mod.main(shape_args + check_args + ["--out", os.path.join(out, "shape.json")])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
