#!/usr/bin/env python3
"""Unit checks for the v2r additions to run.py (PROTOCOL-v2r.md). Standard library only, no Docker.

  python3 -B -m unittest test_v2r      (from bench/value)
"""

import json
import os
import tempfile
import types
import unittest

import run
from lib import mockplans
from lib.common import OLIVIUM_NN, BenchError


class SelectArms(unittest.TestCase):
    def test_protocol_2_accepts_olivium_nn_only_when_named(self):
        self.assertEqual(run.select_arms(None, 2, 2), ("none", "generic", "olivium"))
        self.assertEqual(run.select_arms("none,generic,olivium,olivium-nn", 2, 2),
                         ("none", "generic", "olivium", OLIVIUM_NN))

    def test_protocols_1_and_3_refuse_olivium_nn(self):
        with self.assertRaises(BenchError):
            run.select_arms("olivium-nn", 1, 1)
        with self.assertRaises(BenchError):
            run.select_arms("olivium-nn", 2, 3)


class RunConfig(unittest.TestCase):
    def test_olivium_nn_runs_its_own_export_in_default_mode(self):
        with tempfile.TemporaryDirectory() as out:
            for arm, body in (("olivium", b'{"a":1}'), (OLIVIUM_NN, b'{"b":2}')):
                path = os.path.join(out, "arms", "t1", arm, ".claude")
                os.makedirs(path)
                with open(os.path.join(path, "settings.json"), "wb") as handle:
                    handle.write(body)
            ctx = types.SimpleNamespace(out=out, protocol=2, protocol_version=2)
            ctx.arm_dir = lambda task_id, arm: run.Ctx.arm_dir(ctx, task_id, arm)
            ctx.olivium_exported_settings = lambda task_id, arm="olivium": run.Ctx.olivium_exported_settings(ctx, task_id, arm)
            self.assertEqual(run.Ctx.arm_run_config(ctx, "t1", OLIVIUM_NN), (b'{"b":2}', "default"))
            self.assertEqual(run.Ctx.arm_run_config(ctx, "t1", "olivium"), (b'{"a":1}', "default"))


class InfraLimit(unittest.TestCase):
    def _ctx(self, out, limit):
        return types.SimpleNamespace(args=types.SimpleNamespace(max_infra_errors=limit),
                                     trials_path=os.path.join(out, "trials.jsonl"))

    def test_counts_only_scheduled_pairs_and_passes_above_the_limit(self):
        with tempfile.TemporaryDirectory() as out:
            rows = [{"task_id": "t1", "arm": "olivium", "status": "infra_error"},
                    {"task_id": "t1", "arm": "none", "status": "infra_error"},
                    {"task_id": "t2", "arm": "olivium-x", "status": "infra_error"},
                    {"task_id": "t1", "arm": "none", "status": "completed"}]
            with open(os.path.join(out, "trials.jsonl"), "w") as handle:
                handle.write("".join(json.dumps(row) + "\n" for row in rows))
            specs = [("t1", "olivium", 1), ("t1", "none", 1)]
            self.assertFalse(run.infra_limit_passed(self._ctx(out, 2), specs))
            self.assertTrue(run.infra_limit_passed(self._ctx(out, 1), specs))
            self.assertFalse(run.infra_limit_passed(self._ctx(out, None), specs))

    def test_parse_args_refuses_a_negative_limit(self):
        with self.assertRaises(SystemExit):
            run.parse_args(["run", "--out", "/nonexistent-v2r", "--max-infra-errors", "-1"])


class NativeScenario(unittest.TestCase):
    def test_plan_calls_first_skill_and_agent_then_gold(self):
        with tempfile.TemporaryDirectory() as arm:
            for name in ("olivium-area-b", "olivium-area-a"):
                os.makedirs(os.path.join(arm, ".claude", "skills", name))
                open(os.path.join(arm, ".claude", "skills", name, "SKILL.md"), "w").close()
            os.makedirs(os.path.join(arm, ".claude", "agents"))
            open(os.path.join(arm, ".claude", "agents", "olivium-test-runner.md"), "w").close()
            native = mockplans.native_names([arm])
        self.assertEqual(native, (["olivium-area-a", "olivium-area-b"], ["olivium-test-runner"]))
        plan = mockplans.scenario_plan("native", {}, "", native)
        self.assertEqual([step["name"] for step in plan["steps"]], ["Skill", "Agent"])
        self.assertEqual(plan["steps"][0]["input"], {"skill": "olivium-area-a"})
        self.assertEqual(plan["steps"][1]["input"]["subagent_type"], "olivium-test-runner")
        self.assertIn("native", mockplans.CAPTURE_SCENARIOS)

    def test_arm_without_native_runs_gold_only_and_other_scenarios_ignore_names(self):
        self.assertEqual(mockplans.scenario_plan("native", {}, "", ([], []))["steps"], [])
        self.assertEqual(mockplans.scenario_plan("gold", {}, "", (["s"], ["a"]))["steps"], [])


if __name__ == "__main__":
    unittest.main()
