"""Scripted model plans for --dry-run rehearsals against the mock meter.

A plan is base64 JSON placed in the prompt as OLIVIUM_MOCK_PLAN_B64=<...>; the
mock meter replays it as tool calls. Plans exist only in dry-run mode and are
derived from the task's gold patch, so a rehearsal can exercise real edits and
real grading. They are never used with --paid.
"""

import base64
import os
import json
import re

REPO = "/work/repo"
HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def parse_patch(text):
    """Parse a unified diff into [{path, new_file, hunks:[(old, new)]}]."""
    files = []
    current = None
    lines = text.splitlines(keepends=True)
    index = 0
    while index < len(lines):
        line = lines[index]
        if line.startswith("diff --git"):
            current = {"path": None, "new_file": False, "deleted": False, "hunks": []}
            files.append(current)
            index += 1
            continue
        if current is None:
            index += 1
            continue
        if line.startswith("new file mode"):
            current["new_file"] = True
        elif line.startswith("deleted file mode"):
            current["deleted"] = True
        elif line.startswith("+++ "):
            target = line[4:].strip()
            if target.startswith("b/"):
                current["path"] = target[2:]
        elif line.startswith("--- "):
            source = line[4:].strip()
            if source.startswith("a/") and current["path"] is None:
                current["path"] = source[2:]
        elif HUNK_RE.match(line):
            old, new = [], []
            index += 1
            while index < len(lines):
                body = lines[index]
                if body.startswith("diff --git") or HUNK_RE.match(body):
                    break
                if body.startswith("\\"):
                    index += 1
                    continue
                if body.startswith(" "):
                    old.append(body[1:])
                    new.append(body[1:])
                elif body.startswith("-"):
                    old.append(body[1:])
                elif body.startswith("+"):
                    new.append(body[1:])
                index += 1
            current["hunks"].append(("".join(old), "".join(new)))
            continue
        index += 1
    return [item for item in files if item["path"]]


def gold_steps(gold_patch):
    """Read/Edit/Write steps that reproduce the gold patch."""
    steps = []
    for item in parse_patch(gold_patch):
        path = "%s/%s" % (REPO, item["path"])
        if item["new_file"]:
            content = "".join(new for _old, new in item["hunks"])
            steps.append({"name": "Write", "input": {"file_path": path, "content": content}})
            continue
        if item["deleted"]:
            continue
        steps.append({"name": "Read", "input": {"file_path": path}})
        for old, new in item["hunks"]:
            if not old:
                continue
            steps.append({
                "name": "Edit",
                "input": {
                    "file_path": path,
                    "old_string": old.rstrip("\n"),
                    "new_string": new.rstrip("\n"),
                },
            })
    return steps


WEAKEN_CONFTEST = (
    "import pytest\n\n"
    "@pytest.hookimpl(hookwrapper=True)\n"
    "def pytest_runtest_makereport(item, call):\n"
    "    outcome = yield\n"
    "    report = outcome.get_result()\n"
    "    report.outcome = 'passed'\n"
    "    report.longrepr = None\n"
)


# A test that always fails: the Stop hook's test command should block once.
HOOK_FAIL_TEST = (
    "def test_mock_failure_for_stop_hook():\n"
    "    assert False, 'REHEARSAL: deliberately failing test'\n"
)


# Scenarios whose only purpose is the first request: no tool call, so every setup sends
# the same prompt and the meter's request capture shows what each setup adds to it.
CAPTURE_SCENARIOS = ("shape", "envcheck", "native")


def native_names(arm_dirs):
    """(skills, agents) an arm installs: .claude/skills/<name>/SKILL.md and .claude/agents/<name>.md."""
    skills, agents = set(), set()
    for arm_dir in arm_dirs or []:
        skill_root = os.path.join(arm_dir, ".claude", "skills")
        if os.path.isdir(skill_root):
            skills.update(name for name in os.listdir(skill_root) if os.path.isfile(os.path.join(skill_root, name, "SKILL.md")))
        agent_root = os.path.join(arm_dir, ".claude", "agents")
        if os.path.isdir(agent_root):
            agents.update(name[:-3] for name in os.listdir(agent_root) if name.endswith(".md"))
    return sorted(skills), sorted(agents)


def scenario_plan(scenario, task, gold_patch, native=None):
    if scenario == "native":
        # PROTOCOL-v2r.md rehearsal: the arm's first generated skill and subagent are called through
        # Claude Code (Skill, Agent), then the gold patch. Arms without them run gold only. Captured.
        skills, agents = native or ([], [])
        steps = []
        if skills:
            steps.append({"name": "Skill", "input": {"skill": skills[0]}})
        if agents:
            steps.append({"name": "Agent", "input": {"description": "rehearsal check", "subagent_type": agents[0],
                                                     "run_in_background": False,
                                                     "prompt": "Rehearsal: answer in one line."}})
        return {"steps": steps + gold_steps(gold_patch), "final_text": "Mock: native check finished."}
    if scenario == "shape":
        # Request shape: system prompt, tool definitions and first messages per setup.
        return {"steps": [], "final_text": "Mock: request shape captured."}
    if scenario == "envcheck":
        # Session-start environment check: its output must be in the first request.
        return {"steps": [], "final_text": "Mock: environment check captured."}
    if scenario == "permcheck":
        # Rehearsal: what the exported permissions actually do with default mode.
        # mkdir is on the allow list, rm is on the deny list, curl is neither.
        steps = [
            {"name": "Read", "input": {"file_path": "/work/repo/README.md"}},
            {"name": "Bash", "input": {"command": "mkdir -p .mock-allow-proof", "description": "allowed by exported rules"}},
            {"name": "Bash", "input": {"command": "rm -rf .mock-allow-proof", "description": "denied by exported rules"}},
            {"name": "Bash", "input": {"command": "curl -s http://meter:8080/healthz", "description": "neither allowed nor denied"}},
        ] + gold_steps(gold_patch)
        return {"steps": steps, "final_text": "Mock: permission check finished."}
    if scenario == "hookfail":
        # A passing fix would make the Stop hook pass; a failing test proves it blocks.
        path = "/work/repo/tests/test_zz_rehearsal_hook.py"
        if (task.get("language") or "").lower() != "python":
            path = "/work/repo/test/zz_rehearsal_hook.js"
        return {"steps": [{"name": "Write", "input": {"file_path": path, "content": HOOK_FAIL_TEST}}],
                "final_text": "Mock: wrote a failing test."}
    if scenario == "gold":
        return {"steps": gold_steps(gold_patch), "final_text": "Mock: gold patch applied."}
    if scenario == "noop":
        return {"steps": [{"name": "Read", "input": {"file_path": "/work/repo/README.md"}}],
                "final_text": "Mock: nothing changed."}
    if scenario == "weaken":
        # Weakens the test harness instead of fixing the bug.
        return {"steps": [
            {"name": "Write", "input": {"file_path": "/work/repo/conftest.py", "content": WEAKEN_CONFTEST}},
        ], "final_text": "Mock: weakened the tests."}
    if scenario == "loop":
        step = {"name": "Read", "input": {"file_path": "/work/repo/README.md"}}
        return {"steps": [step] * 200, "final_text": "Mock: done."}
    if scenario == "sleep":
        return {"steps": [{"name": "Bash", "input": {"command": "node -e 'setTimeout(function(){}, 3600000)'"}}], "final_text": "Mock: done."}
    raise ValueError("unknown mock scenario: %s" % scenario)


def plan_marker(plan):
    encoded = base64.b64encode(json.dumps(plan).encode("utf-8")).decode("ascii")
    return "OLIVIUM_MOCK_PLAN_B64=%s" % encoded


def init_plan():
    """Mock stand-in for what /init would do: write CLAUDE.md."""
    content = "# CLAUDE.md\n\nREHEARSAL FIXTURE: mock /init output, not model output.\n"
    return {"steps": [{"name": "Write", "input": {"file_path": "/work/repo/CLAUDE.md", "content": content}}],
            "final_text": "Mock: wrote CLAUDE.md."}


# ------------------------------------------------------------------ v4 learner
# The scripted learner of a --dry-run olivium-ai prepare (contract-v4.md, G4). The mock
# meter replays this plan inside the learner container: one Write of the raw file that
# `bin/harnessforge learn` then validates, checks against the history and verifies in
# Docker exactly as it would a model's output. It is built from the truncated
# repository's own history before the base (host git, in arms/olivium_ai.py), never from
# the task's issue, gold patch or tests. No third-party text is stored in the repository:
# the plan lives in OUT. A bundle made from it says learner.status = mock.
LEARNER_RAW_PATH = "/work/out/learned.raw.json"
LEARNER_PITFALL_PATTERNS = ("DeprecationWarning", "deprecated")
_TERM_RE = re.compile(r"[a-z][a-z0-9_]{3,38}")
_STOP_TERMS = {"with", "from", "that", "this", "when", "into", "fix", "fixes", "fixed", "add", "adds", "added",
               "update", "updated", "remove", "removed", "support", "use", "using", "make", "allow", "more",
               "docs", "test", "tests", "release", "version", "merge", "branch", "pull", "request", "main"}
_CODE_SUFFIXES = (".py", ".js", ".ts", ".mjs", ".cjs", ".tsx", ".jsx")


def _is_test_path(path):
    parts = path.split("/")
    base = parts[-1]
    return (any(p in ("tests", "test", "__tests__", "testing") for p in parts[:-1]) or base.startswith("test_")
            or base.endswith("_test.py") or base == "conftest.py" or re.search(r"\.(test|spec)\.[cm]?[jt]sx?$", base) is not None)


def _subject_terms(subject):
    return sorted({t for t in _TERM_RE.findall(subject.lower()) if t not in _STOP_TERMS})


def learner_raw(facts, task):
    """A deterministic raw learner output from history facts (commits, pitfall commits, paths).

    Concepts: up to 3 code files changed by 2 or more recent commits whose subjects share
    a term. Pitfalls: a deprecation pattern seen in 3 or more past diffs. Commands and
    rewrites: candidates for the task's test runner, left to Docker verification.
    """
    commits = facts["commits"]
    paths = facts["paths"]
    by_file = {}
    for commit in commits:
        for path in commit["files"]:
            if path in paths and path.endswith(_CODE_SUFFIXES) and not _is_test_path(path):
                by_file.setdefault(path, []).append(commit)
    concepts = []
    for path in sorted(by_file, key=lambda p: (-len(by_file[p]), p)):
        touching = by_file[path]
        if len(touching) < 2:
            break
        counts = {}
        for commit in touching:
            for term in _subject_terms(commit["subject"]):
                counts.setdefault(term, []).append(commit["hash"])
        shared = sorted((term for term, hashes in counts.items() if len(hashes) >= 2), key=lambda t: (-len(counts[t]), t))
        if not shared:
            continue
        term = shared[0]
        concepts.append({"id": "c%d" % (len(concepts) + 1), "terms": [term], "paths": [path], "symbols": [],
                         "tests": [], "evidence": counts[term][:3]})
        if len(concepts) == 3:
            break
    pitfalls = []
    for pattern in LEARNER_PITFALL_PATTERNS:
        hashes = facts["pitfall_commits"].get(pattern) or []
        if len(hashes) >= 3:
            pitfalls.append({
                "id": "p1", "scope": "global", "concept": None, "kind": "deprecation",
                "text": "When changing public behaviour, keep the old form working and emit a deprecation warning first.",
                "trigger_terms": [], "evidence": hashes[:3],
                "check": {"pattern": pattern, "min_commits": 2},
            })
            break
    command = task.get("test_command") or ""
    if "pytest" in command:
        commands = [{"role": "test_file", "argv": ["python", "-m", "pytest", "-q", "{file}"]},
                    {"role": "lint", "argv": ["ruff", "check", "--no-cache"]}]
        rewrites = [
            {"kind": "missing_tool", "match": {"argv_prefix": ["uv", "run", "mypy"]}, "replace": {"message_id": "tool_missing", "tool": "mypy"}},
            {"kind": "quiet_flags", "match": {"argv_prefix": ["python", "-m", "pytest"]},
             "replace": {"argv_prefix": ["python", "-m", "pytest", "-q", "--no-header"]}},
        ]
    elif "vitest" in command:
        # The first argv word must be a known runner (lane L's rule), so npx, never a node_modules path.
        commands = [{"role": "test_file", "argv": ["npx", "vitest", "run", "{file}"]}]
        rewrites = [{"kind": "wrong_runner", "match": {"argv_prefix": ["npx", "jest"]}, "replace": {"argv_prefix": ["npx", "vitest", "run"]}}]
    elif "bin/mocha.js" in command:
        commands = [{"role": "test_file", "argv": ["node", "bin/mocha.js", "{file}"]}]
        rewrites = []
    else:
        commands = [{"role": "test_file", "argv": ["npx", "mocha", "{file}"]}]
        rewrites = []
    return {"concepts": concepts, "pitfalls": pitfalls, "commands": commands, "rewrites": rewrites}


def learner_plan(raw):
    """The mock meter's plan: one Write of the raw learner output, then a final message."""
    content = json.dumps(raw, indent=2, sort_keys=True) + "\n"
    return {"steps": [{"name": "Write", "input": {"file_path": LEARNER_RAW_PATH, "content": content}}],
            "final_text": "Mock: learner wrote learned.raw.json (REHEARSAL, scripted, not model output)."}
