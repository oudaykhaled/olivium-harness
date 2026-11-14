#!/usr/bin/env python3
"""Checks of the olivium-x arm and its runner wiring. Synthetic exports and manifests only; no
container, model, network or task repository is used.

    python3 -I bench/value/test_olivium_x.py
    python3 -B -m unittest bench/value/test_olivium_x.py
"""

import hashlib
import json
import os
import random
import shutil
import sys
import tempfile
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import run as runner  # noqa: E402
from arms import none_lean  # noqa: E402
from arms import olivium_x  # noqa: E402
from lib import protocol3 as p3  # noqa: E402
from lib.common import ARMS_DIR, NONE_LEAN, OLIVIUM_X, BenchError, read_json, sha256_bytes  # noqa: E402

# v5 contract.md: arms/none_lean.py stays byte-identical to the v4 arm.
NONE_LEAN_SHA256 = "12fb529db831bd0b82bc0a41ebed5125ae70358652cecf736a8edc1ac01eac28"
DENY = ["CronCreate", "CronDelete", "CronList", "EnterWorktree", "ExitWorktree", "ListAgents", "Monitor", "NotebookEdit",
        "ReportFindings", "ScheduleWakeup", "SendMessage", "Skill", "Task", "TaskStop", "Workflow"]
STYLE_TEXT = (
    "---\nname: olivium\ndescription: Olivium Harness - fewer requests\nkeep-coding-instructions: true\n---\n"
    "Work in as few requests as you can.\n"
    "- Put independent searches and file reads in one Bash call, joined with `;`, and read exact line ranges.\n"
    "- After an edit, run the narrowest relevant test in the same Bash call.\n"
    "- Run tests in the foreground and wait for them; do not poll with sleep.\n"
).encode("utf-8")
TASK = "example-repo-1"


def hook(path, matcher, timeout=10):
    command = 'PATH=/usr/bin:/bin; f="$CLAUDE_PROJECT_DIR/%s"; s=$(cat "$f"); /bin/sh -c "$s" synthetic' % path
    return {"matcher": matcher, "hooks": [{"type": "command", "command": command, "timeout": timeout}]}


def export_settings(**overrides):
    settings = {
        "$schema": "https://json.schemastore.org/claude-code-settings.json",
        "disableSkillShellExecution": True,
        "hooks": {"PreToolUse": [hook(olivium_x.GUARD, "Bash|Read|Edit|Write"), hook(olivium_x.SHAPER, "Bash", 5)]},
        "includeGitInstructions": False,
        "outputStyle": "olivium",
        "permissions": {"allow": ["Bash(ls:*)", "Read"], "ask": [], "defaultMode": "default",
                        "deny": sorted(["Bash(curl:*)", "Edit(.env)"] + DENY)},
    }
    settings.update(overrides)
    return settings


def export_spec(profile="lean-x", deny=DENY, include_git=False):
    return {"spec": {"context": {"profile": profile, "include_git_instructions": include_git, "auto_memory": True,
                                 "deny_tools": list(deny)}}}


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as handle:
        handle.write(data if isinstance(data, bytes) else (json.dumps(data, sort_keys=True) + "\n").encode("utf-8"))


class Ctx(object):
    def __init__(self, out, task_ids=(TASK,), arms=(NONE_LEAN, OLIVIUM_X), protocol_version=2, repeats=1, seed=20261112):
        self.out = out
        self.paid = False
        self.tasks = [{"task_id": task_id} for task_id in task_ids]
        self.arms = tuple(arms)
        self.protocol = 2 if protocol_version == 3 else protocol_version
        self.protocol_version = protocol_version
        self.repeats = repeats
        self.seed = seed

    def arm_dir(self, task_id, arm):
        return os.path.join(self.out, "arms", task_id, arm)

    def setup_path(self, task_id, arm):
        return os.path.join(self.out, "arms", task_id, "%s.setup.json" % arm)


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="olivium-x-test-", dir=os.environ.get("TMPDIR"))
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.ctx = Ctx(os.path.join(self.dir, "out"))
        with open(os.path.join(ARMS_DIR, "benchmark-settings.json"), "rb") as handle:
            self.none_lean_bytes = none_lean.settings_for(handle.read(), False, DENY)
        write(none_lean.settings_path(self.ctx, TASK), self.none_lean_bytes)
        self.make_export()

    def make_export(self, settings=None, spec=None, style=STYLE_TEXT):
        export = olivium_x.export_dir(self.ctx, TASK)
        shutil.rmtree(export, ignore_errors=True)
        write(os.path.join(export, ".claude", "settings.json"), settings or export_settings())
        write(os.path.join(export, ".olivium", "spec.json"), spec or export_spec())
        write(os.path.join(export, ".olivium", "manifest.json"), {"files": []})
        write(os.path.join(export, olivium_x.GUARD), b"#!/bin/sh\n# synthetic guard\n")
        write(os.path.join(export, olivium_x.SHAPER), b"#!/bin/sh\n# synthetic shaper\n")
        write(os.path.join(export, olivium_x.STYLE), style)
        return export

    def ready(self):
        """Install, derive and record as build() does after generating the export."""
        olivium_x.install(self.ctx, TASK)
        data, facts = olivium_x.derive(self.ctx, TASK)
        olivium_x._write_settings(self.ctx, TASK, data)
        setup = olivium_x._record(self.ctx, TASK, {}, facts)
        write(self.ctx.setup_path(TASK, OLIVIUM_X), setup)
        return data, setup


class Settings(Base):
    def test_settings_are_none_lean_plus_hooks_and_style(self):
        data, facts = olivium_x.derive(self.ctx, TASK)
        settings = json.loads(data.decode("utf-8"))
        base = json.loads(self.none_lean_bytes.decode("utf-8"))
        self.assertEqual(list(settings), list(base) + ["hooks", "outputStyle"])
        self.assertEqual(settings["hooks"], export_settings()["hooks"])
        self.assertEqual(settings["outputStyle"], "olivium")
        # The none-lean part is byte for byte none-lean's: drop the two keys and re-serialise.
        rest = {key: value for key, value in settings.items() if key not in ("hooks", "outputStyle")}
        self.assertEqual((json.dumps(rest, indent=2, ensure_ascii=False) + "\n").encode("utf-8"), self.none_lean_bytes)
        self.assertEqual(settings["permissions"], {"defaultMode": "bypassPermissions", "deny": DENY})
        self.assertEqual(facts["trim"], {"includeGitInstructions": False, "permissions.deny": DENY})
        self.assertEqual(facts["hook_files"], sorted([olivium_x.GUARD, olivium_x.SHAPER]))
        self.assertEqual(facts["style_bytes"], 385)
        self.assertEqual(facts["settings_sha256"], sha256_bytes(data))
        self.assertEqual(olivium_x.derive(self.ctx, TASK)[0], data)

    def test_exactly_the_three_files_are_installed(self):
        arm_dir = olivium_x.install(self.ctx, TASK)
        installed = sorted(os.path.relpath(os.path.join(root, name), arm_dir)
                           for root, _dirs, names in os.walk(arm_dir) for name in names)
        self.assertEqual(installed, sorted(olivium_x.INSTALLED))
        with open(os.path.join(arm_dir, olivium_x.STYLE), "rb") as handle:
            self.assertEqual(handle.read(), STYLE_TEXT)

    def test_refusals(self):
        cases = {
            "an extra settings key": dict(settings=export_settings(env={"BASH_MAX_OUTPUT_LENGTH": "4000"})),
            "no outputStyle": dict(settings={k: v for k, v in export_settings().items() if k != "outputStyle"}),
            "another style": dict(settings=export_settings(outputStyle="concise")),
            "a Stop hook": dict(settings=export_settings(hooks={"PreToolUse": export_settings()["hooks"]["PreToolUse"],
                                                                "Stop": [hook(olivium_x.SHAPER, None)]})),
            "a SessionStart hook only": dict(settings=export_settings(hooks={"SessionStart": [hook(olivium_x.SHAPER, None)]})),
            "a file the arm does not install": dict(settings=export_settings(hooks={"PreToolUse": [
                hook(olivium_x.GUARD, "Bash"), hook(olivium_x.SHAPER, "Bash"), hook(".claude/hooks/olivium-rewrite.sh", "Bash")]})),
            "no shaper": dict(settings=export_settings(hooks={"PreToolUse": [hook(olivium_x.GUARD, "Bash")]})),
            "a style over 495 bytes": dict(style=STYLE_TEXT + b"x" * (496 - len(STYLE_TEXT))),
            "a style of another name": dict(style=STYLE_TEXT.replace(b"name: olivium", b"name: elsewise")),
            "the lean profile": dict(spec=export_spec(profile="lean")),
            "a deny name none-lean lacks": dict(spec=export_spec(deny=DENY[:-1]),
                                                settings=export_settings(permissions={"deny": DENY[:-1]})),
            "git instructions on": dict(spec=export_spec(include_git=True),
                                        settings=export_settings(includeGitInstructions=True)),
        }
        for name, kwargs in sorted(cases.items()):
            with self.subTest(name):
                self.make_export(**kwargs)
                with self.assertRaises(BenchError):
                    olivium_x.derive(self.ctx, TASK)

    def test_style_at_the_bound_is_accepted(self):
        self.make_export(style=STYLE_TEXT + b"x" * (495 - len(STYLE_TEXT)))
        self.assertEqual(olivium_x.derive(self.ctx, TASK)[1]["style_bytes"], 495)

    def test_none_lean_settings_are_needed_and_never_written(self):
        os.unlink(none_lean.settings_path(self.ctx, TASK))
        with self.assertRaises(BenchError) as raised:
            olivium_x.derive(self.ctx, TASK)
        self.assertIn("prepare none-lean first", str(raised.exception))
        with self.assertRaises(BenchError):
            olivium_x.build(self.ctx, {"task_id": TASK})

    def test_none_lean_with_a_carried_key_is_refused(self):
        with self.assertRaises(BenchError):
            olivium_x.settings_for(self.none_lean_bytes.replace(b'"includeGitInstructions"', b'"outputStyle": "x",\n  "includeGitInstructions"'),
                                   {"PreToolUse": []}, "olivium")


class Readiness(Base):
    def test_ready_after_prepare(self):
        data, setup = self.ready()
        self.assertEqual(olivium_x.check_ready(self.ctx, TASK), [])
        self.assertEqual(olivium_x.settings_bytes(self.ctx, TASK), data)
        self.assertEqual(setup["permission_mode"], "bypassPermissions")
        self.assertEqual(setup["harness_files"], sorted(olivium_x.INSTALLED))
        self.assertEqual(setup["cost_usd"], 0.0)
        self.assertEqual(setup["setup_model_calls"], 0)

    def test_changed_none_lean_settings_are_caught(self):
        self.ready()
        with open(os.path.join(ARMS_DIR, "benchmark-settings.json"), "rb") as handle:
            write(none_lean.settings_path(self.ctx, TASK), none_lean.settings_for(handle.read(), False, DENY[1:]))
        problems = olivium_x.check_ready(self.ctx, TASK)
        self.assertTrue(problems and "differs from none-lean's" in problems[0], problems)

    def test_changed_installed_file_is_caught(self):
        self.ready()
        write(os.path.join(self.ctx.arm_dir(TASK, OLIVIUM_X), olivium_x.SHAPER), b"#!/bin/sh\nexit 0\n")
        self.assertIn("installed files changed", " ".join(olivium_x.check_ready(self.ctx, TASK)))

    def test_changed_settings_file_is_caught(self):
        self.ready()
        write(olivium_x.settings_path(self.ctx, TASK), b"{}\n")
        problems = " ".join(olivium_x.check_ready(self.ctx, TASK))
        self.assertIn("no longer match", problems)
        self.assertIn("changed after prepare", problems)

    def test_prepare_refreshes_an_ok_setup_without_generating(self):
        data, setup = self.ready()
        failures = olivium_x.prepare(self.ctx, lambda *_args: self.fail("an ok setup is not built again"))
        self.assertEqual(failures, [])
        again = read_json(self.ctx.setup_path(TASK, OLIVIUM_X))
        self.assertEqual(again["settings_sha256"], setup["settings_sha256"])
        self.assertEqual(olivium_x.settings_bytes(self.ctx, TASK), data)

    def test_prepare_records_a_failure_visibly(self):
        self.ready()
        write(os.path.join(olivium_x.export_dir(self.ctx, TASK), olivium_x.STYLE), STYLE_TEXT + b"\n")
        failures = olivium_x.prepare(self.ctx, lambda *_args: False)
        self.assertEqual([(arm, task) for arm, task, _error in failures], [(OLIVIUM_X, TASK)])
        self.assertEqual(read_json(self.ctx.setup_path(TASK, OLIVIUM_X))["status"], "failed")


class Runner(Base):
    def test_olivium_x_is_protocol_2_only_and_only_when_named(self):
        self.assertEqual(runner.select_arms("none-lean,olivium-x", 2, 2), (NONE_LEAN, OLIVIUM_X))
        self.assertEqual(runner.select_arms("olivium-x,none-lean,olivium", 2, 2), ("olivium", NONE_LEAN, OLIVIUM_X))
        self.assertNotIn(OLIVIUM_X, runner.select_arms(None, 2, 2))
        for protocol, version in ((1, 1), (2, 3)):
            with self.assertRaises(BenchError):
                runner.select_arms("none-lean,olivium-x", protocol, version)

    def test_run_config_is_bypass_with_the_derived_settings(self):
        data, _setup = self.ready()
        ctx = types.SimpleNamespace(protocol=2, protocol_version=2, out=self.ctx.out)
        self.assertEqual(runner.Ctx.arm_run_config(ctx, TASK, OLIVIUM_X), (data, "bypassPermissions"))
        self.assertEqual(runner.Ctx.arm_run_config(ctx, TASK, NONE_LEAN), (self.none_lean_bytes, "bypassPermissions"))

    def test_block_schedule_for_none_lean_and_olivium_x(self):
        tasks = ("t1", "t2", "t3")
        ctx = Ctx(self.ctx.out, task_ids=tasks, repeats=3, seed=20261112)
        order = runner.schedule_for(ctx)
        self.assertEqual(order, p3.block_schedule(list(tasks), (NONE_LEAN, OLIVIUM_X), 3, 20261112))
        self.assertEqual(len(order), 18)
        blocks = [order[index:index + 2] for index in range(0, len(order), 2)]
        for block in blocks:
            self.assertEqual({spec[1] for spec in block}, {NONE_LEAN, OLIVIUM_X})
            self.assertEqual(len({(spec[0], spec[2]) for spec in block}), 1)
        self.assertEqual(sorted((b[0][0], b[0][2]) for b in blocks), sorted((t, r) for t in tasks for r in (1, 2, 3)))
        # Seeded: the same seed gives the same order, another seed another.
        self.assertEqual(runner.schedule_for(ctx), order)
        self.assertNotEqual(runner.schedule_for(Ctx(self.ctx.out, task_ids=tasks, repeats=3, seed=1)), order)

    def test_other_selections_keep_the_shuffle(self):
        ctx = Ctx(self.ctx.out, task_ids=("t1", "t2"), arms=(NONE_LEAN,), repeats=2, seed=7)
        specs = [(t, NONE_LEAN, r) for t in ("t1", "t2") for r in (1, 2)]
        random.Random(7).shuffle(specs)
        self.assertEqual(runner.schedule_for(ctx), specs)

    def test_schedule_file_name_and_order_triples(self):
        ctx = Ctx(self.ctx.out, task_ids=("t1", "t2"), repeats=2)
        os.makedirs(ctx.out, exist_ok=True)
        specs = runner.ensure_schedule(ctx)
        path = os.path.join(ctx.out, "schedule.none-lean+olivium-x.json")
        self.assertEqual(runner.schedule_path(ctx), path)
        saved = read_json(path)
        self.assertEqual(saved["order"], [list(spec) for spec in specs])
        self.assertEqual(saved["arms"], [NONE_LEAN, OLIVIUM_X])
        self.assertTrue(all(len(spec) == 3 for spec in saved["order"]))

    def test_none_lean_arm_is_unchanged(self):
        with open(os.path.join(HERE, "arms", "none_lean.py"), "rb") as handle:
            self.assertEqual(hashlib.sha256(handle.read()).hexdigest(), NONE_LEAN_SHA256)


if __name__ == "__main__":
    unittest.main()
