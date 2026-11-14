"""Checks of what protocol 3 adds to the runner, with Docker faked (no container runs).

  cd bench/value && python3 -B -m unittest lib.test_protocol3

Everything here is synthetic: a two-task manifest written by the test, placeholder
arms, and request bodies built in code. No model, network or task repository is used.
"""

import contextlib
import io
import json
import os
import shutil
import tempfile
import types
import unittest

import run as runner
from lib import protocol3 as p3
from lib import trials as trial_ops
from lib.common import BenchError, CLAUDE_CODE_VERSION, manifest_checksum, sha256_bytes, tree_digest


def synthetic_manifest(path, task_ids=("alpha-repo-1", "beta-repo-2")):
    tasks = [{"task_id": task_id, "repo": "example/%s" % task_id, "base_sha": "0" * 40, "fix_sha": "1" * 40,
              "pr_url": "https://example.invalid/pull/1", "deps_image": "olivium-bench-deps-%s:v1" % task_id,
              "f2p": ["t::a"], "p2p": [], "gold_files": ["src/a.py"], "language": "python"} for task_id in task_ids]
    manifest = {"selection": {"rule": "synthetic test manifest"}, "tasks": tasks}
    manifest["checksum"] = manifest_checksum(manifest)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle)
    return path


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="p3-test-", dir=os.environ.get("TMPDIR"))
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.manifest = synthetic_manifest(os.path.join(self.dir, "manifest-test.json"))
        self.out = os.path.join(self.dir, "out")

    def ctx(self, *extra, command="run"):
        argv = [command, "--protocol", "3", "--manifest", self.manifest, "--out", self.out] + list(extra)
        return runner.Ctx(runner.parse_args(argv))

    def parse_error(self, argv):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                runner.parse_args(argv)


class ParseAndSelection(Base):
    def test_protocol_3_is_the_protocol_2_code_path(self):
        ctx = self.ctx()
        self.assertEqual((ctx.protocol, ctx.protocol_version, ctx.pilot), (2, 3, False))
        self.assertEqual(ctx.arms, ("none", "generic", "olivium"))
        self.assertEqual(self.ctx("--arms", "none,olivium,none-lean").arms, ("none", "olivium", "none-lean"))

    def test_refusals_at_parse_time(self):
        base = ["--out", self.out, "--manifest", self.manifest]
        self.parse_error(["run", "--pilot"] + base)
        self.parse_error(["run", "--protocol", "2", "--pilot"] + base)
        self.parse_error(["trim", "--protocol", "2"] + base)
        self.parse_error(["trim", "--protocol", "3", "--pilot"] + base)
        self.parse_error(["trim", "--protocol", "3", "--mock-scenario", "gold"] + base)
        self.parse_error(["run", "--protocol", "3", "--meter-image", "olivium-bench-meter:v1"] + base)
        self.parse_error(["run", "--protocol", "3", "--meter-image", "other:v1"] + base)
        self.parse_error(["prepare", "--protocol", "3", "--rebuild-images", "--no-image-build"] + base)
        key = os.path.join(self.dir, "dummy.key")
        with open(key, "w") as handle:
            handle.write("dummy\n")
        self.parse_error(["trim", "--protocol", "3", "--paid", "--cap-usd", "1", "--run-cap-usd", "1", "--key-file", key] + base)
        self.parse_error(["run", "--protocol", "3", "--paid", "--cap-usd", "1", "--run-cap-usd", "1", "--key-file", key,
                          "--meter-image", "olivium-bench-meter-a2:v1"] + base)

    def test_pilot_runs_none_only(self):
        self.assertEqual(self.ctx("--pilot").arms, ("none",))
        self.assertEqual(self.ctx("--pilot", "--arms", "none").arms, ("none",))
        base = ["run", "--protocol", "3", "--manifest", self.manifest, "--out", self.out, "--pilot"]
        for arms in ("generic", "none,olivium", "none-lean"):
            # A usage error (exit 2), like the other refusals of a flag combination.
            self.parse_error(base + ["--arms", arms])
            with self.assertRaises(BenchError):
                p3.pilot_arms(arms)

    def test_a_scored_run_with_a_single_setup_is_refused(self):
        for arms in ("none", "olivium", "generic", "none-lean"):
            with self.assertRaisesRegex(BenchError, "single setup"):
                p3.check_scored_selection(self.ctx("--arms", arms))
        p3.check_scored_selection(self.ctx("--arms", "none,olivium"))
        p3.check_scored_selection(self.ctx())
        p3.check_scored_selection(self.ctx("--pilot"))

    def test_meter_image_is_swapped_for_a_dry_run_only(self):
        from lib import meterctl
        original = meterctl.METER_IMAGE
        self.addCleanup(setattr, meterctl, "METER_IMAGE", original)
        self.ctx("--meter-image", "olivium-bench-meter-a2:v1")
        self.assertEqual(meterctl.METER_IMAGE, "olivium-bench-meter-a2:v1")


class Schedule(Base):
    def test_blocks_interleave_every_setup(self):
        tasks = ["t%02d" % n for n in range(16)]
        arms = ("none", "generic", "olivium")
        order = p3.block_schedule(tasks, arms, 3, 20261108)
        self.assertEqual(len(order), 144)
        self.assertEqual(len(set(order)), 144)
        self.assertEqual(sorted(order), sorted((t, a, r) for t in tasks for a in arms for r in (1, 2, 3)))
        for start in range(0, 144, 3):
            block = order[start:start + 3]
            self.assertEqual(sorted(arm for _t, arm, _r in block), sorted(arms))
            self.assertEqual(len({(t, r) for t, _a, r in block}), 1)
        self.assertLessEqual(p3.longest_stretch(order), 2)
        self.assertEqual(order, p3.block_schedule(tasks, arms, 3, 20261108))
        self.assertNotEqual(order, p3.block_schedule(tasks, arms, 3, 20261109))

    def test_none_lean_runs_once_per_task_in_the_blocks_of_repeat_1(self):
        tasks = ["t%02d" % n for n in range(16)]
        arms = ("none", "generic", "olivium")
        plain = p3.block_schedule(tasks, arms, 3, 20261108, p3.SECONDARY_REPEATS)
        self.assertEqual(plain, p3.block_schedule(tasks, arms, 3, 20261108))
        order = p3.block_schedule(tasks, arms + ("none-lean",), 3, 20261108, p3.SECONDARY_REPEATS)
        self.assertEqual(len(order), 144 + 16)
        lean = [(t, r) for t, a, r in order if a == "none-lean"]
        self.assertEqual(sorted(lean), [(t, 1) for t in tasks])
        scored = [spec for spec in order if spec[1] != "none-lean"]
        self.assertEqual(sorted(scored), sorted((t, a, r) for t in tasks for a in arms for r in (1, 2, 3)))
        self.assertLessEqual(p3.longest_stretch(order), 2)
        ctx = self.ctx("--arms", "none,generic,olivium,none-lean")
        specs = runner.schedule_for(ctx)
        self.assertEqual(sorted(spec for spec in specs if spec[1] == "none-lean"),
                         [("alpha-repo-1", "none-lean", 1), ("beta-repo-2", "none-lean", 1)])
        self.assertEqual(len(specs), 2 * 3 * 3 + 2)

    def test_schedule_file_records_the_design(self):
        ctx = self.ctx("--repeats", "2")
        os.makedirs(ctx.out, exist_ok=True)
        specs = runner.ensure_schedule(ctx)
        with open(os.path.join(ctx.out, "schedule.json")) as handle:
            payload = json.load(handle)
        self.assertEqual((payload["protocol"], payload["mode"], payload["arms"]), (3, "scored", ["none", "generic", "olivium"]))
        self.assertEqual(payload["order"], [list(spec) for spec in specs])
        self.assertEqual(len(specs), 2 * 3 * 2)

    def test_pilot_stage_2_adds_repeats_in_the_same_out(self):
        stage1 = self.ctx("--pilot", "--repeats", "1")
        os.makedirs(stage1.out, exist_ok=True)
        runner.ensure_schedule(stage1)
        for task_id in ("alpha-repo-1", "beta-repo-2"):
            trial_ops.append_jsonl(stage1.trials_path, {"run_id": "%s.none.r1" % task_id, "task_id": task_id, "arm": "none",
                                                        "repeat": 1, "status": "completed"})
        stage2 = self.ctx("--pilot", "--tasks", "beta-repo-2", "--repeats", "3")
        specs = runner.ensure_schedule(stage2)
        pending, _ = runner.pending_trials(stage2, specs)
        self.assertEqual(sorted(item["run_id"] for item in pending), ["beta-repo-2.none.r2", "beta-repo-2.none.r3"])
        names = sorted(name for name in os.listdir(stage1.out) if name.startswith("schedule"))
        self.assertEqual(len(names), 2)
        self.assertTrue(all(name.startswith("schedule.pilot.") for name in names))


class OutRecord(Base):
    def test_one_out_one_purpose(self):
        pilot = self.ctx("--pilot")
        os.makedirs(pilot.out, exist_ok=True)
        record = p3.ensure_out_record(pilot)
        self.assertEqual((record["mode"], record["pilot"], record["claude_code_version"]), ("pilot", True, CLAUDE_CODE_VERSION))
        p3.ensure_out_record(self.ctx("--pilot"))
        with self.assertRaisesRegex(BenchError, "needs its own OUT"):
            p3.ensure_out_record(self.ctx())
        other = synthetic_manifest(os.path.join(self.dir, "other.json"), ("alpha-repo-1",))
        ctx = runner.Ctx(runner.parse_args(["run", "--protocol", "3", "--pilot", "--manifest", other, "--out", self.out]))
        with self.assertRaisesRegex(BenchError, "another manifest"):
            p3.ensure_out_record(ctx)

    def test_an_out_with_trials_of_another_protocol_is_refused(self):
        os.makedirs(self.out)
        with open(os.path.join(self.out, "trials.jsonl"), "w") as handle:
            handle.write("{}\n")
        with self.assertRaisesRegex(BenchError, "fresh OUT"):
            p3.ensure_out_record(self.ctx())

    def test_rows_are_labelled_for_protocol_3_only(self):
        self.assertEqual(trial_ops.label_row(self.ctx("--pilot"), {}), {"protocol": 3, "pilot": True})
        self.assertEqual(trial_ops.label_row(self.ctx(), {}), {"protocol": 3, "pilot": False})
        ctx2 = runner.Ctx(runner.parse_args(["run", "--protocol", "2", "--manifest", self.manifest, "--out", self.out]))
        self.assertEqual(trial_ops.label_row(ctx2, {"a": 1}), {"a": 1})


class FakeDocker:
    def __init__(self, versions):
        self.versions = versions
        self.runs = []

    def image_id(self, image):
        return "sha256:%s" % image

    def remove(self, name):
        pass

    def docker(self, *args, check=True, timeout=None):
        self.runs.append(args)
        image = args[args.index("--entrypoint") + 2]
        version = self.versions.get(image, CLAUDE_CODE_VERSION)
        return types.SimpleNamespace(returncode=0, stdout=("%s (Claude Code)\n" % version).encode(), stderr=b"")

    LABEL = "olivium-bench=1"


class Pin(Base):
    def run_pin(self, versions):
        fake = FakeDocker(versions)
        real = p3.dk
        p3.dk = fake
        self.addCleanup(setattr, p3, "dk", real)
        ctx = self.ctx()
        os.makedirs(ctx.out, exist_ok=True)
        p3.pin_claude_code(ctx)
        return fake

    def test_each_image_is_asked_once(self):
        fake = self.run_pin({})
        self.assertEqual(len(fake.runs), 2)
        self.assertIn("--network", fake.runs[0])
        self.assertEqual(fake.runs[0][fake.runs[0].index("--network") + 1], "none")
        again = self.run_pin({})
        self.assertEqual(again.runs, [])

    def test_another_version_is_refused(self):
        with self.assertRaisesRegex(BenchError, "not the pinned"):
            self.run_pin({"olivium-bench-agent-beta-repo-2:v1": "2.1.312"})


def body(tools, system="You are Claude Code.", messages=("hello",)):
    return {
        "model": "m", "metadata": {"user_id": "x"},
        "system": [{"type": "text", "text": system}],
        "tools": [{"name": name, "description": "d" * size, "input_schema": {}} for name, size in tools],
        "messages": [{"role": "user", "content": [{"type": "text", "text": text}]} for text in messages],
    }


class Trim(Base):
    def test_request_shape_is_exact_bytes_and_the_calibrated_estimate(self):
        b = body([("Read", 10), ("Edit", 5)], system="sys é", messages=("abc", "de"))
        shape = p3.request_shape(b)
        tools_json = json.dumps(b["tools"], ensure_ascii=False, separators=(",", ":"))
        self.assertEqual(shape["system_bytes"], len("sys é".encode("utf-8")))
        self.assertEqual(shape["tools_bytes"], len(tools_json.encode("utf-8")))
        self.assertEqual(shape["messages_bytes"], 5)
        self.assertEqual(shape["est_tokens"], round((shape["system_bytes"] + shape["tools_bytes"]) / 2.78 + 5 / 2.46))
        self.assertEqual(shape["tool_names"], ["Edit", "Read"])

    def test_the_first_request_offering_read_and_edit_is_the_main_one(self):
        capture = os.path.join(self.dir, "capture")
        os.makedirs(capture)
        for seq, tools in ((1, [("Bash", 1)]), (2, [("Read", 1), ("Edit", 1)]), (3, [("Read", 1), ("Edit", 1), ("Bash", 1)])):
            with open(os.path.join(capture, "req-%04d.json" % seq), "w") as handle:
                json.dump({"run_id": "r", "seq": seq, "body": body(tools)}, handle)
        name, found = p3.first_main_request(capture)
        self.assertEqual(name, "req-0002.json")
        self.assertEqual([tool["name"] for tool in found["tools"]], ["Read", "Edit"])
        self.assertIsNone(p3.first_main_request(os.path.join(self.dir, "missing")))

    def test_task_trim_is_none_minus_olivium(self):
        none = p3.request_shape(body([("Read", 900), ("Edit", 900), ("Agent", 30000)]))
        olivium = p3.request_shape(body([("Read", 900), ("Edit", 900)], messages=("hello", "x" * 400)))
        lean = p3.request_shape(body([("Read", 900), ("Edit", 900)]))
        entry = p3.task_trim({"none": none, "olivium": olivium, "none-lean": lean})
        self.assertEqual(entry["trim_tokens"], none["est_tokens"] - olivium["est_tokens"])
        self.assertEqual(entry["trim_lean_tokens"], none["est_tokens"] - lean["est_tokens"])
        self.assertGreater(entry["trim_system_tools_tokens"], 10000)
        self.assertEqual(entry["trim_messages_tokens"], round(-400 / 2.46))
        self.assertLessEqual(abs(entry["trim_tokens"] - entry["trim_system_tools_tokens"] - entry["trim_messages_tokens"]), 1)

    def test_a_scored_run_checks_the_trim_against_the_arms_in_out(self):
        ctx = self.ctx("--arms", "none,olivium")
        self.assertIn("missing", " ".join(p3.trim_problems(ctx)))
        tasks = {}
        for task in ctx.tasks:
            arm = ctx.arm_dir(task["task_id"], "olivium")
            os.makedirs(os.path.join(arm, ".claude"))
            with open(os.path.join(arm, ".claude", "settings.json"), "w") as handle:
                handle.write('{"x": 1}\n')
            arms = {}
            for name in ("none", "olivium"):
                settings, _mode = ctx.arm_run_config(task["task_id"], name)
                arms[name] = {"settings_sha256": sha256_bytes(settings),
                              "arm_sha256": [] if name == "none" else [tree_digest(arm)]}
            tasks[task["task_id"]] = {"trim_tokens": 11000, "arms": arms}
        payload = {"format": p3.TRIM_FORMAT, "claude_code_version": CLAUDE_CODE_VERSION, "tasks": tasks}
        with open(os.path.join(ctx.out, "trim.json"), "w") as handle:
            json.dump(payload, handle)
        self.assertEqual(p3.trim_problems(ctx), [])
        self.assertEqual(p3.trim_problems(self.ctx("--arms", "none,generic")), [])
        # The export changed after the trim was measured.
        with open(os.path.join(ctx.arm_dir("beta-repo-2", "olivium"), "CLAUDE.md"), "w") as handle:
            handle.write("changed\n")
        self.assertEqual(p3.trim_problems(ctx), ["trim of beta-repo-2 was measured on another olivium arm"])


class GradingLimitAndQuietDocker(Base):
    """PROTOCOL-v3.md change log of 2026-11-11 (grading time limit); review 2, M5."""

    def fake_grade(self, **kwargs):
        from grade import grader
        captured = {}
        names = ("remove", "create", "cp_in", "make_tar", "start", "wait", "kill")
        real = {name: getattr(grader.dk, name) for name in names}
        for name in names:
            self.addCleanup(setattr, grader.dk, name, real[name])
        grader.dk.remove = grader.dk.create = grader.dk.cp_in = grader.dk.start = grader.dk.kill = lambda *a, **k: None
        grader.dk.make_tar = lambda entries: captured.setdefault("entries", {path: data for path, data, _mode in entries})
        grader.dk.wait = lambda name, timeout: captured.setdefault("wait", timeout) and None
        material = os.path.join(self.dir, "material")
        os.makedirs(material, exist_ok=True)
        for name in ("test.patch", "agent.patch"):
            open(os.path.join(material, name), "w").close()
        task = {"test_files": ["tests/test_a.py"], "test_command": "true", "deps_image": "olivium-bench-deps-x:v1",
                "f2p": ["t::a"], "p2p": []}
        ctx = types.SimpleNamespace(tag="t", paid=False)
        result = grader.grade(ctx, task, os.path.join(material, "agent.patch"), material, os.path.join(self.dir, "run"), **kwargs)
        return captured, result

    def test_protocol_3_grades_with_600_s_and_protocol_2_is_unchanged(self):
        captured, result = self.fake_grade(test_timeout_s=600)
        self.assertEqual(captured["entries"]["grade-in/test_timeout_seconds.txt"], b"600\n")
        self.assertEqual(captured["wait"], 1200)
        self.assertEqual(result["status"], "infra_error")
        captured, _result = self.fake_grade()
        self.assertNotIn("grade-in/test_timeout_seconds.txt", captured["entries"])
        self.assertEqual(captured["wait"], 900)

    def test_trials_pass_the_limit_for_protocol_3_only(self):
        from lib.common import GRADE_TEST_TIMEOUT_V3_S
        self.assertEqual(GRADE_TEST_TIMEOUT_V3_S, 600)
        self.assertTrue(trial_ops.protocol_v3(self.ctx()))
        with open(trial_ops.__file__, encoding="utf-8") as handle:
            source = handle.read()
        self.assertIn("test_timeout_s=GRADE_TEST_TIMEOUT_V3_S if protocol_v3(ctx) else None", source)

    def test_grade_sh_reads_the_limit_and_defaults_to_300(self):
        from lib.common import GRADE_DIR
        with open(os.path.join(GRADE_DIR, "grade.sh"), encoding="utf-8") as handle:
            text = handle.read()
        self.assertIn("test_limit=300", text)
        self.assertIn('timeout --signal=KILL "$test_limit" bash -c "$test_cmd"', text)
        self.assertIn("timeout --signal=KILL 300 bash -c \"$lint_cmd\"", text)

    def test_a_paid_run_refuses_to_start_beside_the_selection(self):
        real = p3.dk.docker
        self.addCleanup(setattr, p3.dk, "docker", real)
        listing = b"other_x\nolivium-bench-v3val-acme-widget-12-base-1\nolivium-bench-agent-abc\n"
        p3.dk.docker = lambda *args, **kwargs: types.SimpleNamespace(stdout=listing, returncode=0)
        self.assertEqual(p3.selection_busy(), ["olivium-bench-v3val-acme-widget-12-base-1"])
        p3.dk.docker = lambda *args, **kwargs: types.SimpleNamespace(stdout=b"olivium-bench-agent-abc\n", returncode=0)
        self.assertEqual(p3.selection_busy(), [])


class VersionPinInTrial(Base):
    def test_a_trial_on_another_claude_code_is_an_infra_error_that_stops_the_run(self):
        ctx = self.ctx("--arms", "none,olivium", "--repeats", "1")
        task = ctx.tasks[0]
        material = ctx.material_dir(task["task_id"])
        os.makedirs(material)
        for name, text in (("issue.md", "Synthetic issue.\n"), ("gold.patch", "")):
            with open(os.path.join(material, name), "w") as handle:
                handle.write(text)
        settings, mode = ctx.arm_run_config(task["task_id"], "none")
        spec = {"task_id": task["task_id"], "arm": "none", "repeat": 1, "attempt": 1, "run_id": "%s.none.r1" % task["task_id"]}

        def fake_session(_ctx, run_id, _task, _prompt, _arm_dirs, settings_bytes, _mode, run_dir):
            with open(os.path.join(run_dir, "transcript.jsonl"), "w") as handle:
                handle.write(json.dumps({"type": "system", "subtype": "init", "claude_code_version": "9.9.9"}) + "\n")
            with open(os.path.join(run_dir, "settings-in.sha256"), "w") as handle:
                handle.write(sha256_bytes(settings_bytes) + "  /work/in/settings.json\n")
            open(os.path.join(run_dir, "harness-files.sha256"), "w").close()
            return {"container": "olivium-bench-agent-test", "exit_code": 0, "host_timeout": False, "wall_seconds": 1.0,
                    "harness_bytes": 0, "image": "img", "image_id": "sha256:img"}

        real_session, real_dk_remove = trial_ops.ses.run_session, trial_ops.dk.remove
        trial_ops.ses.run_session = fake_session
        trial_ops.dk.remove = lambda name: None
        self.addCleanup(setattr, trial_ops.ses, "run_session", real_session)
        self.addCleanup(setattr, trial_ops.dk, "remove", real_dk_remove)
        ctx.meter = types.SimpleNamespace(rows_for=lambda run_id: [])
        os.makedirs(ctx.trial_dir(spec["run_id"]))
        row = trial_ops.execute_trial(ctx, spec, task, material)
        self.assertEqual((row["status"], row["protocol"], row["pilot"]), ("infra_error", 3, False))
        self.assertTrue(trial_ops.version_pin_failed(ctx, spec["run_id"]))
        self.assertFalse(trial_ops.web_guard_failed(ctx, spec["run_id"]))


if __name__ == "__main__":
    unittest.main()
