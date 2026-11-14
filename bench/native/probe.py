#!/usr/bin/env python3
"""Real Claude Code against a mock model: are the generated skills and subagents loaded and usable? ($0)

    python3 -I bench/native/probe.py --export-all DIR --export-none DIR --export-three DIR --out FRESH_DIR [--work FRESH_DIR]

Real Claude Code (the version baked into the agent image, 2.1.311 for the default) runs headless in an
olivium-bench agent image. Its only network peer is bench/value/meter/meter.py in mock mode with --capture-dir and
--plan-any-tools, on an internal Docker network: there is no API key anywhere and no request leaves the host. The
mock follows a scripted plan, so the "model" calls the tools the plan names; a plan nested in an Agent prompt drives
the subagent.

The arm is a generated export (CLAUDE.md, .claude/**, .olivium/**) laid over the image's repository, exactly as
bench/value/arms/entry.sh installs every arm, in permission mode default. --export-all is the export with the
generated skills and subagents (bench/native/fixture.sh, `generate`), --export-none the same repository with
`--native none`, --export-three the export of the same repository written with AREAS=3 (three area skills).
Probe-only hooks that record the hook input are passed with --settings from /work/in, so the arm
stays the export byte for byte.

Runs (containers olivium-bench-native-<tag>-*, network olivium-bench-native-<tag>-net, meter
olivium-bench-native-<tag>-meter; all removed at the end):
  first-none   the --native none export, one turn: the first request
  first-all    the --native all export, one turn: the first request
  invoke       the all export: Skill <area skill>, Agent olivium-locator (Read, Grep, then a Bash call that must not
               exist), Agent olivium-test-runner (the generated test command on a paired test)
  guard        the all export: Agent olivium-test-runner running `ls tests`, which the guard must refuse, then
               Agent Explore, which the export's Agent(Explore) deny rule must refuse
  maxturns     the all export: Agent olivium-test-runner with a plan of more Bash steps than its maxTurns
  three        the three-skill export: Skill for each of its three area skills

Checks, written to OUT/native-probe.json (exit 0 only when all pass):
  E-N1 first-all lists each generated skill and subagent exactly as the export describes them, offers Skill and
       Agent, not Workflow, lists no bundled skill, lists Claude Code's built-in agents (Explore, general-purpose,
       statusline-setup) exactly when the export does not deny them by name (Agent(<name>)), and carries no skill
       or agent body; first-none offers neither Skill nor Agent; with the deny rules, the guard run's Agent
       Explore call is refused by the Agent(Explore) rule
  E-N2 first-request bytes, all minus none, converted to tokens (tools and system 2.78 B/token, messages
       2.46 B/token), within 20 % of the export's est_tokens_per_request
  E-N3 the Skill call loads the skill body into the next request
  E-N4 locator requests offer exactly Glob, Grep, Read; its Bash call gets "No such tool available"; its
       final text is handed back to the main session
  E-N5 the guard refuses `ls tests` from the test runner, lets the generated test command through, and the hook
       input carries agent_type olivium-test-runner
  E-N6 the invoke run ends with result success, permission_denials [] and exit 0
  E-N7 the test runner stops at its maxTurns: the maxturns run's plan has more steps than maxTurns, the runner
       sends exactly maxTurns requests and never reaches its final text, the hand-back says it "stopped at its
       <maxTurns>-turn limit", and the main session ends with result success
  E-N8 the three-skill export allows exactly one Skill(<name>) rule per area skill (three), never the bare Skill
       tool, and each Skill call launches its skill with no permission denial (result success, permission_denials [])

Docker: only olivium-bench-native-* resources are created or removed. Nothing runs on the host but docker and git.
Repository code runs only inside the agent container, on the internal network (no route out).
"""

import argparse
import base64
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.path.dirname(HERE)
METER_PY = os.path.join(BENCH, "value", "meter", "meter.py")
ENTRY_SH = os.path.join(BENCH, "value", "arms", "entry.sh")
AGENT_UID = 1001
MODEL = "claude-sonnet-5-5"
# Token conversion of the design probe (stage-0 calibration): tools and system 2.78 B/token, messages 2.46 B/token.
TOOLS_BPT = 2.78
MESSAGES_BPT = 2.46
TOLERANCE = 0.20
BUNDLED_SKILLS = ["update-config", "keybindings-help", "code-review", "simplify", "fewer-permission-prompts", "loop",
                  "claude-api", "workflow-authoring", "security-review", "init"]
BUILTIN_AGENTS = ["general-purpose", "Explore", "statusline-setup"]
PROMPT = ("A synthetic task for the probe: in src/acme/http/h11.py a header without a value crashes the parser. "
          "Find the cause, fix it and run the paired tests.\n")
# Workspace trust, as a person grants it once in the trust dialog (the export's workspace_trust_required caveat):
# Claude Code 2.1.311 ignores a project's permissions.allow entries in an untrusted workspace (its stderr says so).
TRUST_SH = b"""#!/bin/bash
# Probe entry: marks /work/repo trusted in the agent user's Claude Code state, then runs the shared arm entry.
node -e 'const fs = require("fs"), p = process.env.HOME + "/.claude.json"; let d = {};
  try { d = JSON.parse(fs.readFileSync(p, "utf8")); } catch (e) {}
  d.projects = d.projects || {}; d.projects["/work/repo"] = Object.assign(d.projects["/work/repo"] || {}, {hasTrustDialogAccepted: true});
  fs.writeFileSync(p, JSON.stringify(d));' || exit 2
exec /bin/bash /work/in/entry.sh
"""
DUMP_SH = b"""#!/bin/sh
# Probe hook: records the hook input; prints nothing, so it decides nothing.
d=/work/out/hooks
mkdir -p "$d"
cat > "$d/$(date +%s%N)-$1.json"
exit 0
"""


def docker(*args, data=None, timeout=300, check=True):
    done = subprocess.run(["docker", *args], input=data, capture_output=True, timeout=timeout)
    if check and done.returncode != 0:
        raise RuntimeError("docker %s failed: %s" % (" ".join(args[:3]), done.stderr.decode("utf-8", "replace")[-600:]))
    return done


def read(path):
    with open(path, "rb") as handle:
        return handle.read()


def arm_files(export):
    """The export's model-facing files: CLAUDE.md, .claude/**, .olivium/** (what entry.sh installs)."""
    files = {}
    for base, dirs, names in os.walk(export):
        dirs.sort()
        for name in sorted(names):
            path = os.path.join(base, name)
            rel = os.path.relpath(path, export).replace(os.sep, "/")
            if rel == "CLAUDE.md" or rel.startswith(".claude/") or rel.startswith(".olivium/"):
                files[rel] = (read(path), 0o755 if os.access(path, os.X_OK) else 0o644)
    return files


def make_tar(entries):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        seen = set()
        for name, data, mode in entries:
            parts = name.split("/")[:-1]
            for i in range(1, len(parts) + 1):
                d = "/".join(parts[:i])
                if d not in seen:
                    seen.add(d)
                    info = tarfile.TarInfo(d)
                    info.type, info.mode, info.uid, info.gid, info.mtime = tarfile.DIRTYPE, 0o755, AGENT_UID, AGENT_UID, 0
                    tar.addfile(info)
            info = tarfile.TarInfo(name)
            info.size, info.mode, info.uid, info.gid, info.mtime = len(data), mode, AGENT_UID, AGENT_UID, 0
            tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()


def untar(blob, target, strip=1):
    os.makedirs(target, exist_ok=True)
    count = 0
    with tarfile.open(fileobj=io.BytesIO(blob)) as tar:
        for member in tar.getmembers():
            if not member.isfile():
                continue
            parts = member.name.split("/")[strip:]
            if not parts or any(p in ("", ".", "..") for p in parts):
                continue
            path = os.path.join(target, *parts)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as handle:
                handle.write(tar.extractfile(member).read())
            count += 1
    return count


def nested(plan):
    return "OLIVIUM_MOCK_PLAN_B64=" + base64.b64encode(json.dumps(plan).encode()).decode()


def plan_prompt(plan):
    return (PROMPT + nested(plan) + "\n").encode()


def frontmatter(text):
    match = re.match(r"^---\n(.*?)\n---\n\n(.*)$", text, re.S)
    front = {}
    for line in match.group(1).split("\n"):
        key, _, value = line.partition(": ")
        front[key] = value
    return front, match.group(2)


def describe_export(export):
    """Names, descriptions, tools and bodies of the generated items, read from the export itself."""
    items = []
    for kind, folder in (("skill", ".claude/skills"), ("agent", ".claude/agents")):
        root = os.path.join(export, folder)
        if not os.path.isdir(root):
            continue
        for base, dirs, names in os.walk(root):
            dirs.sort()
            for name in sorted(names):
                if not name.endswith(".md"):
                    continue
                front, body = frontmatter(read(os.path.join(base, name)).decode())
                items.append({"kind": kind, "name": json.loads(front["name"]), "description": json.loads(front["description"]),
                              "tools": front.get("tools"), "max_turns": int(front["maxTurns"]) if "maxTurns" in front else None,
                              "body": body.rstrip("\n")})
    provenance = os.path.join(export, ".olivium", "native-provenance.json")
    prov = json.loads(read(provenance)) if os.path.exists(provenance) else None
    return items, prov


def export_settings(export):
    path = os.path.join(export, ".claude", "settings.json")
    return json.loads(read(path)) if os.path.exists(path) else {}


def export_builtin_denied(export):
    """Whether the export's project settings deny every Claude Code built-in agent by name (Agent(<name>))."""
    deny = (export_settings(export).get("permissions") or {}).get("deny") or []
    return all("Agent(%s)" % name in deny for name in BUILTIN_AGENTS)


class Probe:
    def __init__(self, args):
        self.args = args
        self.tag = "%d" % os.getpid()
        self.net = "olivium-bench-native-%s-net" % self.tag
        self.meter = "olivium-bench-native-%s-meter" % self.tag
        self.work = os.path.abspath(args.work)
        self.created = []

    # Infrastructure ---------------------------------------------------------
    def up(self):
        docker("network", "create", "--internal", "--label", "olivium-bench=1", self.net)
        self.created.append(("network", self.net))
        docker("create", "--name", self.meter, "--label", "olivium-bench=1", "--network", self.net, "--network-alias", "meter",
               "--cap-drop=ALL", "--security-opt=no-new-privileges", "--memory", "256m", "--pids-limit", "128",
               "--entrypoint", "python3", self.args.meter_image, "-I", "/app/meter.py", "--mode", "mock",
               "--run-cap-usd", "1000", "--total-cap-usd", "100000", "--capture-dir", "/data/capture",
               "--plan-any-tools", "--log", "/data/requests.jsonl")
        self.created.append(("container", self.meter))
        # The image's meter is replaced by this repository's, which has --plan-any-tools.
        docker("cp", METER_PY, "%s:/app/meter.py" % self.meter)
        docker("start", self.meter)
        probe = "import urllib.request as u; u.urlopen('http://127.0.0.1:8080/healthz', timeout=2)"
        for _ in range(60):
            if docker("exec", self.meter, "python3", "-I", "-c", probe, check=False).returncode == 0:
                return
            time.sleep(1)
        raise RuntimeError("the mock meter did not become healthy")

    def down(self):
        removed = []
        for kind, name in reversed(self.created):
            if not name.startswith("olivium-bench-native-"):
                continue
            if kind == "container":
                docker("rm", "-f", name, check=False)
            else:
                docker("network", "rm", name, check=False)
            removed.append(name)
        names = docker("ps", "-a", "--format", "{{.Names}}", check=False).stdout.decode().split()
        nets = docker("network", "ls", "--format", "{{.Name}}", check=False).stdout.decode().split()
        left = [n for n in names + nets if n.startswith("olivium-bench-native-%s-" % self.tag)]
        return {"removed": removed, "left_after_teardown": left}

    # One Claude Code session ------------------------------------------------
    def run(self, name, export, prompt, max_turns, hooks, trusted=True, flag_settings=None):
        out = os.path.join(self.work, name)
        os.makedirs(out)
        run_id = "native-%s-%s" % (self.tag, name)
        container = "olivium-bench-native-%s-%s" % (self.tag, name)
        env = {"ANTHROPIC_BASE_URL": "http://meter:8080/run/%s" % run_id, "ANTHROPIC_API_KEY": "olivium-bench-dummy-key",
               "BENCH_MODEL": MODEL, "BENCH_MAX_TURNS": str(max_turns), "BENCH_TIMEOUT_S": "400",
               "BENCH_PERMISSION_MODE": "default", "BENCH_INCLUDE_HOOK_EVENTS": "1", "BENCH_DISALLOW_WEB": "1",
               "UV_NO_SYNC": "1"}
        args = ["create", "--name", container, "--label", "olivium-bench=1", "--network", self.net, "--cap-drop=ALL",
                "--security-opt=no-new-privileges", "--memory", "1500m", "--memory-swap", "1500m", "--cpus", "2",
                "--pids-limit", "512"]
        for key, value in sorted(env.items()):
            args += ["--env", "%s=%s" % (key, value)]
        docker(*args, self.args.image, "/bin/bash", "/work/in/%s" % ("probe-entry.sh" if trusted else "entry.sh"))
        self.created.append(("container", container))
        entries = [("in/prompt.txt", prompt, 0o644), ("in/entry.sh", read(ENTRY_SH), 0o755), ("in/probe-entry.sh", TRUST_SH, 0o755)]
        if flag_settings is not None:
            entries.append(("in/settings.json", (json.dumps(flag_settings, indent=2) + "\n").encode(), 0o644))
        if hooks:
            settings = {"hooks": {event: [dict({"hooks": [{"type": "command", "timeout": 30,
                                                           "command": "/bin/sh /work/in/probe-dump.sh %s" % event}]},
                                               **({"matcher": "*"} if event == "PreToolUse" else {}))]
                                  for event in ("PreToolUse", "SubagentStart", "SubagentStop")}}
            entries += [("in/settings.json", (json.dumps(settings, indent=2) + "\n").encode(), 0o644),
                        ("in/probe-dump.sh", DUMP_SH, 0o755)]
        for rel, (data, mode) in sorted(arm_files(export).items()):
            entries.append(("in/arm/" + rel, data, mode))
        docker("cp", "-a", "-", "%s:/work" % container, data=make_tar(entries))
        started = time.time()
        docker("start", container)
        waited = docker("wait", container, timeout=600, check=False).stdout.decode().strip()
        wall = round(time.time() - started, 1)
        untar(docker("cp", "%s:/work/out" % container, "-", timeout=300).stdout, os.path.join(out, "out"))
        cap = docker("cp", "%s:/data/capture/%s" % (self.meter, run_id), "-", check=False, timeout=300)
        captured = untar(cap.stdout, os.path.join(out, "capture")) if cap.returncode == 0 else 0
        docker("rm", "-f", container, check=False)
        return {"name": name, "docker_wait": waited, "wall_s": wall, "captured": captured, "dir": out, "trusted": trusted}


# Reading the captures ----------------------------------------------------------
def jlen(obj):
    return len(json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))


def texts(obj):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for value in obj.values():
            yield from texts(value)
    elif isinstance(obj, list):
        for value in obj:
            yield from texts(value)


def bodies(run):
    folder = os.path.join(run["dir"], "capture")
    out = []
    if os.path.isdir(folder):
        for name in sorted(os.listdir(folder)):
            if name.endswith(".json"):
                out.append(json.loads(read(os.path.join(folder, name)))["body"])
    return out


def tool_names(body):
    return sorted(t.get("name") for t in body.get("tools") or [] if isinstance(t, dict))


def is_main(body):
    return {"Read", "Edit"} <= set(tool_names(body))


def first_main(run):
    return next((b for b in bodies(run) if is_main(b)), None)


def message_text(body):
    return "\n".join(texts(body.get("messages") or []))


def all_text(body):
    return "\n".join(texts(body))


def first_user(body):
    for message in body.get("messages") or []:
        if message.get("role") == "user":
            return "\n".join(texts(message.get("content")))
    return ""


def tool_results(body):
    """Text of every tool_result in the request, in order."""
    out = []
    for message in body.get("messages") or []:
        content = message.get("content")
        if isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    out.append("\n".join(texts(block.get("content"))))
    return out


def result_event(run):
    path = os.path.join(run["dir"], "out", "transcript.jsonl")
    if not os.path.exists(path):
        return None
    final = None
    with open(path, errors="replace") as handle:
        for line in handle:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if event.get("type") == "result":
                final = {k: event.get(k) for k in ("subtype", "is_error", "num_turns", "permission_denials", "result")}
    return final


def exit_code(run):
    path = os.path.join(run["dir"], "out", "exit_code")
    return read(path).decode().strip() if os.path.exists(path) else None


def hook_inputs(run):
    folder = os.path.join(run["dir"], "out", "hooks")
    rows = []
    if os.path.isdir(folder):
        for name in sorted(os.listdir(folder)):
            try:
                data = json.loads(read(os.path.join(folder, name)))
            except ValueError:
                continue
            rows.append({"event": data.get("hook_event_name"), "tool": data.get("tool_name"), "agent_type": data.get("agent_type"),
                         "agent_id": bool(data.get("agent_id")), "command": (data.get("tool_input") or {}).get("command")})
    return rows


def size_parts(body):
    return {"body": jlen(body), "tools": jlen(body.get("tools") or []), "system": jlen(body.get("system") or ""),
            "messages": jlen(body.get("messages") or [])}


# Checks ------------------------------------------------------------------------
def check(results, cid, ok, detail):
    results.append({"id": cid, "pass": bool(ok), "detail": detail})


def evaluate(runs, items, prov, runner_command, plan_names, builtin_denied, three):
    results = []
    skills = [i for i in items if i["kind"] == "skill"]
    agents = [i for i in items if i["kind"] == "agent"]
    first_all, first_none = first_main(runs["first-all"]), first_main(runs["first-none"])

    # E-N1 listing
    errors = []
    if first_all is None or first_none is None:
        errors.append("no main request captured (all: %s, none: %s)" % (first_all is not None, first_none is not None))
    else:
        names, text = tool_names(first_all), message_text(first_all)
        for tool in ("Skill", "Agent"):
            if tool not in names:
                errors.append("first-all does not offer %s" % tool)
        if "Workflow" in names:
            errors.append("first-all offers Workflow")
        for tool in ("Skill", "Agent", "Task"):
            if tool in tool_names(first_none):
                errors.append("first-none offers %s" % tool)
        for item in skills:
            line = "- %s: %s" % (item["name"], item["description"])
            if line not in text:
                errors.append("skill listing line missing: %s" % line[:120])
        for item in agents:
            line = "- %s: %s (Tools: %s)" % (item["name"], item["description"], item["tools"])
            if line not in all_text(first_all):
                errors.append("agent listing line missing: %s" % line[:120])
        for name in BUNDLED_SKILLS:
            if "- %s:" % name in text:
                errors.append("bundled skill listed: %s" % name)
        # A lean export that keeps Task denies Claude Code's built-in agents by name, which takes them off the
        # listing (the env switch has no effect from project settings on 2.1.311); check both ways.
        builtin_listed = [name for name in BUILTIN_AGENTS if "- %s:" % name in all_text(first_all)]
        if builtin_denied and builtin_listed:
            errors.append("export denies the built-in agents but these are listed: %s" % ", ".join(builtin_listed))
        if not builtin_denied and not builtin_listed:
            errors.append("built-in agents are not listed although the export does not deny them")
        whole = all_text(first_all)
        for item in items:
            marker = max(item["body"].split("\n"), key=len)
            if marker in whole:
                errors.append("body of %s is in the first request" % item["name"])
    guard_main = [r for b in bodies(runs["guard"]) if is_main(b) for r in tool_results(b)]
    explore_refused = any("Agent(Explore)" in r and "denied" in r for r in guard_main)
    if builtin_denied and not explore_refused:
        errors.append("the Agent Explore call was not refused by the Agent(Explore) rule")
    check(results, "E-N1", not errors, {"errors": errors, "builtin_denied_in_export": builtin_denied,
                                         "explore_call_refused": explore_refused,
                                         "explore_tool_result": next((r[:240] for r in guard_main if "Explore" in r), None),
                                         "builtin_agents_listed": builtin_listed if first_all is not None and first_none is not None else None,
                                         "tools_all": tool_names(first_all) if first_all else None,
                                         "tools_none": tool_names(first_none) if first_none else None})

    # E-N2 first-request bytes versus the estimate
    detail = {}
    ok = False
    if first_all is not None and first_none is not None:
        a, n = size_parts(first_all), size_parts(first_none)
        tokens = ((a["tools"] - n["tools"]) + (a["system"] - n["system"])) / TOOLS_BPT + (a["messages"] - n["messages"]) / MESSAGES_BPT
        estimate = (prov or {}).get("cost", {}).get("est_tokens_per_request")
        ratio = tokens / estimate if estimate else None
        ok = ratio is not None and abs(ratio - 1) <= TOLERANCE
        detail = {"all": a, "none": n, "delta_bytes": a["body"] - n["body"], "delta_tokens": round(tokens),
                  "delta_tokens_flat_2_78": round((a["body"] - n["body"]) / TOOLS_BPT), "est_tokens_per_request": estimate,
                  "ratio": round(ratio, 3) if ratio else None, "tolerance": TOLERANCE,
                  # Not independent: base.json's fixed costs were calibrated on captures of the same kind (design
                  # probe sa-c2 and sa-e, same image and meter), so this checks consistency, not an outside value.
                  "estimate_calibrated_on": "design-probe captures sa-c2 and sa-e (same probe kind)"}
    check(results, "E-N2", ok, detail)

    invoke = bodies(runs["invoke"])
    skill = plan_names["skill"]
    # E-N3 skill body on use
    body_line = next((i["body"].split("\n")[2] for i in skills if i["name"] == skill), None)
    loaded = [b for b in invoke if is_main(b) and body_line and body_line in message_text(b)]
    launching = any(("Launching skill: %s" % skill) in message_text(b) for b in invoke)
    check(results, "E-N3", bool(loaded) and launching,
          {"skill": skill, "body_line": body_line, "requests_with_body": len(loaded), "launching_skill_seen": launching})

    # E-N4 locator: tools, Bash refused as missing, hand-back
    locator = [b for b in invoke if not is_main(b) and tool_names(b) == ["Glob", "Grep", "Read"]]
    no_bash = any("No such tool available" in r and "Bash" in r for b in locator for r in tool_results(b))
    locator_body = next((i["body"].split("\n")[0] for i in agents if i["name"] == "olivium-locator"), "")
    system_ok = bool(locator_body) and any(locator_body in "\n".join(texts(b.get("system") or "")) for b in locator)
    handed = any("NATIVEPROBE_LOCATOR_FINAL" in "\n".join(tool_results(b)) for b in invoke if is_main(b))
    check(results, "E-N4", bool(locator) and no_bash and handed and system_ok,
          {"locator_requests": len(locator), "tool_sets": sorted({",".join(tool_names(b)) for b in invoke if not is_main(b) and b.get("tools")}),
           "bash_no_such_tool": no_bash, "body_is_system_prompt": system_ok, "hand_back_in_main": handed})

    # E-N5 guard on the test runner
    runner_reqs = [b for b in invoke if not is_main(b) and tool_names(b) == ["Bash", "Read"]]
    runner_results = [r for b in runner_reqs for r in tool_results(b)]
    passed_guard = bool(runner_results) and not any("Olivium guard" in r for r in runner_results)
    guard_bodies = bodies(runs["guard"])
    guard_results = [r for b in guard_bodies if not is_main(b) for r in tool_results(b)]
    refused = any("Olivium guard: the test runner runs only: " in r for r in guard_results)
    hooks = hook_inputs(runs["invoke"]) + hook_inputs(runs["guard"])
    typed = [h for h in hooks if h["event"] == "PreToolUse" and h["tool"] == "Bash" and h["agent_type"] == "olivium-test-runner" and h["agent_id"]]
    check(results, "E-N5", passed_guard and refused and len(typed) >= 2,
          {"runner_requests": len(runner_reqs), "test_command": runner_command, "test_command_passed_guard": passed_guard,
           "runner_tool_results": [r[:200] for r in runner_results], "ls_tests_refused": refused,
           "guard_tool_results": [r[:240] for r in guard_results], "pretool_bash_inputs_with_agent_type": [h["command"] for h in typed],
           "hook_events": sorted({h["event"] for h in hooks if h["event"]})})

    # E-N6 the invoke run as a whole
    final = result_event(runs["invoke"])
    code = exit_code(runs["invoke"])
    ok = bool(final) and final["subtype"] == "success" and final["permission_denials"] == [] and code == "0"
    check(results, "E-N6", ok, {"result": final, "exit_code": code, "guard_run": {"result": result_event(runs["guard"]), "exit_code": exit_code(runs["guard"])}})

    # E-N7 the test runner's maxTurns
    max_turns = next((i["max_turns"] for i in agents if i["name"] == "olivium-test-runner"), None)
    capped = bodies(runs["maxturns"])
    runner_turns = [b for b in capped if not is_main(b) and tool_names(b) == ["Bash", "Read"]]
    main_results = [r for b in capped if is_main(b) for r in tool_results(b)]
    reached_final = any("NATIVEPROBE_MAXTURNS_FINAL" in r for r in main_results)
    final = result_event(runs["maxturns"])
    steps = plan_names["maxturns_steps"]
    limit_note = max_turns is not None and any(("stopped at its %d-turn limit" % max_turns) in r for r in main_results)
    ok = (max_turns is not None and steps > max_turns and len(runner_turns) == max_turns and not reached_final
          and limit_note and bool(final) and final["subtype"] == "success")
    check(results, "E-N7", ok, {"max_turns": max_turns, "plan_steps": steps, "runner_requests": len(runner_turns),
                                "runner_reached_final_text": reached_final, "limit_note_in_hand_back": limit_note, "result": final, "exit_code": exit_code(runs["maxturns"]),
                                "agent_tool_result": next((r[:300] for r in main_results if r), None)})

    # E-N8 three skills, three Skill(<name>) rules, each one launched
    names = sorted(i["name"] for i in three["items"] if i["kind"] == "skill")
    allow = (three["settings"].get("permissions") or {}).get("allow") or []
    rules = sorted(r for r in allow if r.startswith("Skill"))
    texts_three = "\n".join(message_text(b) for b in bodies(runs["three"]) if is_main(b))
    launched = [n for n in names if ("Launching skill: %s" % n) in texts_three]
    final = result_event(runs["three"])
    ok = (len(names) == 3 and rules == ["Skill(%s)" % n for n in names] and launched == names and bool(final)
          and final["subtype"] == "success" and final["permission_denials"] == [] and exit_code(runs["three"]) == "0")
    check(results, "E-N8", ok, {"skills": names, "skill_rules": rules, "launched": launched, "result": final,
                                "exit_code": exit_code(runs["three"])})
    return results


def notes(runs):
    """Not checks: what the same export gives in a workspace nobody trusted (Claude Code's own stderr says why)."""
    out = {}
    for key, name in (("untrusted_workspace", "first-all-untrusted"), ("builtin_agents_switch_as_flag_settings", "first-all-env-flag"),
                      ("trusted_project_settings", "first-all")):
        body = first_main(runs[name])
        stderr = os.path.join(runs[name]["dir"], "out", "stderr.log")
        listed = [agent for agent in BUILTIN_AGENTS if body and ("- %s:" % agent) in all_text(body)]
        out[key] = {"run": name, "builtin_agents_listed": listed, "body_bytes": jlen(body) if body else None,
                    "stderr": read(stderr).decode("utf-8", "replace")[:400] if os.path.exists(stderr) else None}
    return out


def claude_version(image, tag):
    name = "olivium-bench-native-%s-version" % tag
    done = docker("run", "--rm", "--name", name, "--label", "olivium-bench=1", "--network", "none", "--entrypoint", "claude",
                  image, "--version", check=False, timeout=120)
    return done.stdout.decode().strip() or None


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--export-all", required=True)
    parser.add_argument("--export-none", required=True)
    parser.add_argument("--export-three", required=True, help="export of the AREAS=3 fixture (three area skills)")
    parser.add_argument("--out", required=True, help="directory for native-probe.json (which must not exist yet)")
    parser.add_argument("--work", help="fresh directory for captures and transcripts (default OUT/runs)")
    parser.add_argument("--image", default=os.environ.get("NATIVE_PROBE_IMAGE", "olivium-bench-agent-pallets-click-3858:v1"))
    parser.add_argument("--meter-image", default=os.environ.get("NATIVE_PROBE_METER_IMAGE", "olivium-bench-meter:v1"))
    args = parser.parse_args(argv)
    args.work = args.work or os.path.join(args.out, "runs")
    if os.path.exists(os.path.join(args.out, "native-probe.json")):
        parser.error("%s already holds native-probe.json" % args.out)
    if os.path.exists(args.work) and os.listdir(args.work):
        parser.error("%s must be fresh" % args.work)
    os.makedirs(args.out, exist_ok=True)
    os.makedirs(args.work, exist_ok=True)
    report = {"schema": "olivium-native-probe/1", "image": args.image, "meter_image": args.meter_image, "model_calls": "mock",
              "permission_mode": "default", "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    items, prov = describe_export(args.export_all)
    none_items, _ = describe_export(args.export_none)
    report["export_all"] = {"items": [i["name"] for i in items], "provenance_cost": (prov or {}).get("cost"),
                            "test_runner_commands": (prov or {}).get("test_runner_commands")}
    report["export_none_items"] = [i["name"] for i in none_items]
    three_items, _ = describe_export(args.export_three)
    three = {"items": three_items, "settings": export_settings(args.export_three)}
    report["export_three_items"] = [i["name"] for i in three_items]
    problems = []
    skills = [i["name"] for i in items if i["kind"] == "skill"]
    if not skills or not any(i["name"] == "olivium-locator" for i in items) or not any(i["name"] == "olivium-test-runner" for i in items):
        problems.append("the all export lacks an area skill, the locator or the test runner")
    if none_items:
        problems.append("the none export has generated items")
    if len([i for i in three_items if i["kind"] == "skill"]) != 3:
        problems.append("the three-skill export does not have three area skills")
    if shutil.which("docker") is None or docker("info", check=False, timeout=60).returncode != 0:
        problems.append("docker unavailable")
    else:
        for image in (args.image, args.meter_image):
            if docker("image", "inspect", image, check=False).returncode != 0:
                problems.append("image missing: %s" % image)
    if problems:
        report.update(status="unavailable", problems=problems, passed=False)
        write(args.out, report)
        print("native probe unavailable: %s" % "; ".join(problems), file=sys.stderr)
        return 2
    report["claude_version"] = claude_version(args.image, os.getpid())
    runner = (prov.get("test_runner_commands") or ["pytest"])[0]
    skill = skills[0]
    locator_plan = {"steps": [{"name": "Grep", "input": {"pattern": "def ", "path": "/work/repo/src"}},
                              {"name": "Bash", "input": {"command": "echo NATIVEPROBE_LOCATOR_BASH", "description": "probe"}},
                              {"name": "Read", "input": {"file_path": "/work/repo/README.md", "limit": 5}}],
                    "final_text": "NATIVEPROBE_LOCATOR_FINAL src/acme/http/h11.py:1-20 - header parsing"}
    runner_plan = {"steps": [{"name": "Bash", "input": {"command": "%s tests/test_http.py 2>&1 | tail -n 40" % runner,
                                                        "description": "probe paired test"}}],
                   "final_text": "NATIVEPROBE_RUNNER_FINAL"}
    guard_plan = {"steps": [{"name": "Bash", "input": {"command": "ls tests", "description": "probe guard"}}],
                  "final_text": "NATIVEPROBE_GUARD_FINAL"}
    invoke = {"steps": [
        {"name": "Skill", "input": {"skill": skill}},
        {"name": "Agent", "input": {"description": "locate the parser", "subagent_type": "olivium-locator", "run_in_background": False,
                                    "prompt": "Find where headers are parsed. " + nested(locator_plan)}},
        {"name": "Agent", "input": {"description": "run the paired tests", "subagent_type": "olivium-test-runner", "run_in_background": False,
                                    "prompt": "Run tests/test_http.py. " + nested(runner_plan)}}],
        "final_text": "NATIVEPROBE_MAIN_FINAL"}
    guard = {"steps": [{"name": "Agent", "input": {"description": "list tests", "subagent_type": "olivium-test-runner", "run_in_background": False,
                                                   "prompt": "List the tests. " + nested(guard_plan)}},
                       {"name": "Agent", "input": {"description": "explore", "subagent_type": "Explore", "run_in_background": False,
                                                   "prompt": "Find the parser."}}],
             "final_text": "NATIVEPROBE_MAIN_FINAL"}
    # More runner steps than any maxTurns the export gives; each is the generated one-file command the guard allows.
    maxturns_steps = 20
    capped_plan = {"steps": [{"name": "Bash", "input": {"command": "%s tests/test_http.py 2>&1 | tail -n 5" % runner,
                                                        "description": "probe turn %d" % (n + 1)}} for n in range(maxturns_steps)],
                   "final_text": "NATIVEPROBE_MAXTURNS_FINAL"}
    maxturns = {"steps": [{"name": "Agent", "input": {"description": "run tests", "subagent_type": "olivium-test-runner", "run_in_background": False,
                                                      "prompt": "Run tests/test_http.py repeatedly. " + nested(capped_plan)}}],
                "final_text": "NATIVEPROBE_MAIN_FINAL"}
    three_skills = [i["name"] for i in three_items if i["kind"] == "skill"]
    three_plan = {"steps": [{"name": "Skill", "input": {"skill": name}} for name in three_skills], "final_text": "NATIVEPROBE_MAIN_FINAL"}
    probe = Probe(args)
    runs = {}
    try:
        probe.up()
        # The last two runs are diagnostics, not checks: the same export in a workspace nobody trusted, and with the
        # export's built-in-agents switch also passed as --settings (flag settings) instead of only the project file.
        flag = {"env": {"CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS": "1"}}
        for name, export, prompt, turns, hooks, trusted, flag_settings in (
                ("first-none", args.export_none, PROMPT.encode(), 1, False, True, None),
                ("first-all", args.export_all, PROMPT.encode(), 1, False, True, None),
                ("invoke", args.export_all, plan_prompt(invoke), 10, True, True, None),
                ("guard", args.export_all, plan_prompt(guard), 6, True, True, None),
                ("maxturns", args.export_all, plan_prompt(maxturns), 4, False, True, None),
                ("three", args.export_three, plan_prompt(three_plan), 6, False, True, None),
                ("first-all-untrusted", args.export_all, PROMPT.encode(), 1, False, False, None),
                ("first-all-env-flag", args.export_all, PROMPT.encode(), 1, False, True, flag)):
            runs[name] = probe.run(name, export, prompt, turns, hooks, trusted, flag_settings)
            print("%-19s exit=%s wall=%ss captured=%d" % (name, runs[name]["docker_wait"], runs[name]["wall_s"], runs[name]["captured"]), flush=True)
    except (RuntimeError, subprocess.TimeoutExpired) as exc:
        report["error"] = str(exc)[:600]
    finally:
        report["teardown"] = probe.down()
    report["runs"] = {name: {k: v for k, v in run.items() if k != "dir"} | {"dir": os.path.relpath(run["dir"], args.out)}
                      for name, run in runs.items()}
    if len(runs) == 8:
        report["checks"] = evaluate(runs, items, prov, runner, {"skill": skill, "maxturns_steps": maxturns_steps},
                                    export_builtin_denied(args.export_all), three)
        report["notes"] = notes(runs)
        report["passed"] = all(c["pass"] for c in report["checks"]) and not report["teardown"]["left_after_teardown"]
        report["status"] = "ran"
    else:
        report.update(status="failed", passed=False)
    report["ended_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    write(args.out, report)
    for row in report.get("checks", []):
        print("%s %s %s" % (row["id"], "PASS" if row["pass"] else "FAIL", json.dumps(row["detail"])[:400]), flush=True)
    print("native probe: %s" % ("PASS" if report["passed"] else "FAIL"), flush=True)
    return 0 if report["passed"] else 1


def write(out, report):
    with open(os.path.join(out, "native-probe.json"), "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, sort_keys=True)
        handle.write("\n")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
