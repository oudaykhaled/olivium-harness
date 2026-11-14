#!/usr/bin/env python3
"""Runner for the value benchmark. See PROTOCOL.md (authoritative).

  python3 bench/value/run.py prepare|run|status [--dry-run | --paid --cap-usd N
      --run-cap-usd M --key-file PATH] --out DIR [--tasks a,b] [--repeats 3]
      [--seed 20261108] [--material DIR] [--protocol 1|2|3] [--manifest PATH]
      [--clones DIR] [--arms none,generic,olivium] [--total-reserve-usd R]
      [--pilot] [--no-image-build] [--meter-image TAG]
  python3 bench/value/run.py trim --protocol 3 --out DIR [--tasks a,b] [--arms ...]

--protocol 1 is the pilot and is unchanged; --protocol 2 is PROTOCOL-v2.md: the
olivium arm is the new generator, run exactly as exported. Protocol 2 also accepts
the information arm none-lean (arms/none_lean.py), only when named with --arms, and
the v5 development arm olivium-x (arms/olivium_x.py), likewise; `--arms
none-lean,olivium-x` runs in seeded blocks of both arms (lib/protocol3.block_schedule).
Protocol 2 also accepts the v2r arm olivium-nn (PROTOCOL-v2r.md), only when named: the
olivium export of the same snapshot with --native none, run as exported like olivium.
--max-infra-errors N stops starting runs once more than N infra_error rows of the
selection are recorded (PROTOCOL-v2r.md, stop rule 2).

--protocol 3 is benchmark v3 (PROTOCOL-v3.md): the protocol-2 code path, with the
manifest corpus/manifest-v3.json, Claude Code pinned (each image is asked its version
before any session; a trial on another version stops the run), and setups interleaved
in seeded blocks (one block per task and repeat, every setup once per block). A scored
run with a single setup is refused. --pilot runs the none arm only, into an OUT of its
own, labelled pilot (rows carry "pilot": true). `trim` measures each task's first
request in the none and olivium setups at $0 (mock meter, request capture) and writes
OUT/trim.json; a paid scored run refuses to start without a trim that matches OUT's
olivium exports. See lib/protocol3.py for the trim file format.

--dry-run is the default and uses the mock meter: it never contacts a model API.
Everything is resumable: completed work is never redone, and a run interrupted
half way through is recorded as infra_error and repeated under a new run id.
Host subprocesses are limited to docker, git and the mix launcher.
"""

import argparse
import json
import math
import os
import queue
import random
import re
import sys
import threading
import time

from lib.common import (
    ARMS,
    ARMS_DIR,
    NONE_LEAN,
    OPTIONAL_ARMS,
    V4_OPTIONAL_ARMS,
    OLIVIUM_X,
    V5_OPTIONAL_ARMS,
    OLIVIUM_NN,
    V2R_OPTIONAL_ARMS,
    CLAUDE_CODE_VERSION,
    CONCURRENCY,
    DEFAULT_REPEATS,
    DEFAULT_SEED,
    DOCKER_DIR,
    MAX_ATTEMPTS,
    MAX_TURNS,
    TIMEOUT_S,
    BenchError,
    SetupFailed,
    MANIFEST_PATH,
    MANIFEST_V2_PATH,
    MANIFEST_V3_PATH,
    load_manifest,
    out_tag,
    read_json,
    read_jsonl,
    run_id_for,
    select_tasks,
    write_json_atomic,
)
from lib import dockerops as dk
from lib import meterctl
from lib import mockplans
from lib import protocol3 as p3
from lib import trials as trial_ops
from arms import generic as generic_arm
from arms import none_lean as none_lean_arm
from arms import olivium as olivium_arm
from arms import olivium_ai as olivium_ai_arm
from arms import olivium_v2 as olivium_v2_arm
from arms import olivium_x as olivium_x_arm

DRY_RUN_CAP_USD = 500.0
DRY_RUN_RUN_CAP_USD = 5.0
METER_TAG_RE = re.compile(r"^olivium-bench-meter-[a-z0-9][a-z0-9._-]{0,40}:[A-Za-z0-9][A-Za-z0-9._-]{0,40}$")


class Ctx:
    def __init__(self, args):
        self.args = args
        self.out = os.path.realpath(args.out)
        os.makedirs(self.out, exist_ok=True)
        self.tag = out_tag(self.out)
        self.paid = bool(args.paid)
        self.seed = args.seed
        self.repeats = args.repeats
        # Protocol 3 runs the protocol-2 code path: every `protocol == 2` branch applies to
        # it. protocol_version says which protocol this is; lib/protocol3.py holds what 3 adds.
        self.protocol_version = args.protocol
        self.protocol = 2 if args.protocol == 3 else args.protocol
        self.pilot = bool(getattr(args, "pilot", False))
        default_manifest = {2: MANIFEST_V2_PATH, 3: MANIFEST_V3_PATH}.get(args.protocol, MANIFEST_PATH)
        self.manifest = load_manifest(os.path.realpath(args.manifest) if args.manifest else default_manifest)
        self.tasks = select_tasks(self.manifest, args.tasks)
        self.tasks_by_id = {task["task_id"]: task for task in self.tasks}
        self.arms = p3.pilot_arms(args.arms) if self.pilot else select_arms(args.arms, self.protocol, args.protocol)
        self.material = os.path.realpath(args.material or os.path.join(self.out, "material"))
        self.clones_dir = os.path.realpath(args.clones or os.path.join(self.material, ".clones"))
        self.limit_turns = args.limit_turns if args.limit_turns is not None else MAX_TURNS
        self.limit_seconds = args.limit_seconds if args.limit_seconds is not None else TIMEOUT_S
        self.scenario = args.mock_scenario or "gold"
        self.key_file = os.path.realpath(args.key_file) if args.key_file else None
        if getattr(args, "meter_image", None):
            # Dry run only (parse_args): the meter is built and run under this tag instead.
            meterctl.METER_IMAGE = args.meter_image
        self.meter = None
        self.trials_path = os.path.join(self.out, "trials.jsonl")
        self.attempts_path = os.path.join(self.out, "attempts.jsonl")
        self._settings = None

    def settings_bytes(self):
        if self._settings is None:
            with open(os.path.join(ARMS_DIR, "benchmark-settings.json"), "rb") as handle:
                self._settings = handle.read()
        return self._settings

    def olivium_exported_settings(self, task_id, arm="olivium"):
        """Protocol v2: the exported settings file, byte for byte (olivium, or v2r olivium-nn)."""
        with open(os.path.join(self.arm_dir(task_id, arm), ".claude", "settings.json"), "rb") as handle:
            return handle.read()

    def arm_run_config(self, task_id, arm):
        """(settings_bytes, permission_mode) for a scored trial of this arm."""
        if self.protocol == 2 and arm == "olivium":
            return self.olivium_exported_settings(task_id), "default"
        if self.protocol_version == 2 and arm == OLIVIUM_NN:
            # v2r: the --native none export, as exported, in olivium's permission mode.
            return self.olivium_exported_settings(task_id, OLIVIUM_NN), "default"
        if self.protocol == 2 and arm == NONE_LEAN:
            # The none arm's settings plus only the lean trim, same permission mode as none.
            return none_lean_arm.settings_bytes(self, task_id), "bypassPermissions"
        if self.protocol_version == 2 and arm in V4_OPTIONAL_ARMS:
            # v4 dev arms run their lean-ai export as exported, like olivium.
            return olivium_ai_arm.exported_settings(self, task_id, arm), "default"
        if self.protocol_version == 2 and arm in V5_OPTIONAL_ARMS:
            # v5: none-lean's settings plus the lean-x hooks and style, in none-lean's permission mode.
            return olivium_x_arm.settings_bytes(self, task_id), "bypassPermissions"
        return self.settings_bytes(), "bypassPermissions"

    def agent_image(self, task):
        return "olivium-bench-agent-%s:v1" % task["task_id"]

    def material_dir(self, task_id):
        return os.path.join(self.material, task_id)

    def arm_dir(self, task_id, arm):
        return os.path.join(self.out, "arms", task_id, arm)

    def exported_dir(self, task_id):
        return os.path.join(self.out, "arms", task_id, "olivium.exported")

    def setup_path(self, task_id, arm):
        return os.path.join(self.out, "arms", task_id, "%s.setup.json" % arm)

    def trial_dir(self, run_id):
        return os.path.join(self.out, "trials", run_id)

    def check_material(self):
        problems = []
        for task in self.tasks:
            base = self.material_dir(task["task_id"])
            for name in (".complete", "issue.md", "test.patch", "gold.patch", "repo"):
                if not os.path.exists(os.path.join(base, name)):
                    problems.append(os.path.join(base, name))
        if problems:
            raise BenchError(
                "task material is missing under %s (%d paths, first %s). Build it with: "
                "python3 bench/value/corpus/materialize.py --out %s"
                % (self.material, len(problems), problems[0], self.material)
            )


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["prepare", "run", "status", "trim"])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="mock meter (the default)")
    mode.add_argument("--paid", action="store_true", help="real model calls through the live meter")
    parser.add_argument("--cap-usd", type=float)
    parser.add_argument("--run-cap-usd", type=float)
    parser.add_argument("--key-file")
    parser.add_argument("--out", required=True)
    parser.add_argument("--material", help="materialized task directory (default OUT/material)")
    parser.add_argument("--protocol", type=int, choices=[1, 2, 3], default=1, help="1: the 2026-11-09 pilot; 2: PROTOCOL-v2.md; 3: PROTOCOL-v3.md (benchmark v3)")
    parser.add_argument("--manifest", help="manifest path (default: the protocol's manifest under corpus/)")
    parser.add_argument("--clones", help="protocol 2: bare clones directory for the generator input (default MATERIAL/.clones)")
    parser.add_argument("--tasks", help="comma-separated task ids (default: all)")
    parser.add_argument("--arms", help="comma-separated arms to prepare and run (default: none,generic,olivium); a re-run of one arm is compared against a scored run's other arms separately. Protocol 2 also accepts none-lean, only when named; a selection with none-lean keeps its own schedule file, so it can run into the same OUT after the other arms")
    parser.add_argument("--total-reserve-usd", type=float,
                        help="held per in-flight request against --cap-usd (default: the meter's own, 1.00 paid and 0 dry-run); "
                             "with a cap of a few dollars and 2 runs at a time the default stops the run near cap - 2.00")
    parser.add_argument("--max-infra-errors", type=int,
                        help="run: start no further trial once more than N infra_error rows of the selected tasks and arms "
                             "are recorded in OUT (PROTOCOL-v2r.md, stop rule 2); default: no such limit")
    parser.add_argument("--repeats", type=int, default=DEFAULT_REPEATS)
    parser.add_argument("--sessions", type=int, choices=[1, CONCURRENCY], default=CONCURRENCY,
                        help="run: agent sessions at a time (default %d, the protocol constant); 1 keeps a run and its "
                             "meter at 2 containers on a Docker host shared with other work" % CONCURRENCY)
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--retry-failed", action="store_true", help="prepare: rerun failed setup steps")
    parser.add_argument("--no-as-exported", action="store_true", help="run: skip the as-exported settings run")
    parser.add_argument("--rebuild-images", action="store_true", help="prepare: rebuild agent images")
    parser.add_argument("--no-image-build", action="store_true",
                        help="prepare: never build or rebuild an agent image; a missing or stale one is an error "
                             "(for a window in which another invocation must find the images unchanged)")
    parser.add_argument("--pilot", action="store_true",
                        help="protocol 3: no-harness pilot runs (none arm only) into an OUT of their own, labelled pilot")
    parser.add_argument("--learn-model", choices=["claude-haiku-5-5", "claude-sonnet-5-5"],
                        help="v4 olivium-ai only: the learner model (default claude-haiku-5-5)")
    parser.add_argument("--learn-cap-usd", type=float,
                        help="v4 olivium-ai only: the meter's per-run cap for one learning run (default 0.10 Haiku, 0.50 Sonnet)")
    parser.add_argument("--meter-image",
                        help="dry-run only: build and use the meter under this tag (olivium-bench-meter-*:*) instead of "
                             "%s, so a $0 run never rebuilds the tag a paid run is using" % meterctl.METER_IMAGE)
    # Rehearsal-only dials. Refused with --paid.
    parser.add_argument("--limit-turns", type=int, help="dry-run only: override the 60-turn limit")
    parser.add_argument("--limit-seconds", type=int, help="dry-run only: override the 20-minute limit")
    parser.add_argument("--mock-scenario", choices=["gold", "noop", "weaken", "loop", "sleep", "permcheck", "hookfail", "shape", "envcheck", "native"],
                        help="dry-run only; shape, envcheck and native also keep each request body under OUT/meter/capture/<run_id>/; "
                             "native calls the arm's first generated skill and subagent, then applies the gold patch")
    args = parser.parse_args(argv)
    if args.paid:
        missing = [name for name, value in (("--cap-usd", args.cap_usd), ("--run-cap-usd", args.run_cap_usd), ("--key-file", args.key_file)) if value is None]
        if missing:
            parser.error("--paid requires %s" % ", ".join(missing))
        for name, value in (("--limit-turns", args.limit_turns), ("--limit-seconds", args.limit_seconds), ("--mock-scenario", args.mock_scenario)):
            if value is not None:
                parser.error("%s is dry-run only" % name)
        key_path = os.path.expanduser(args.key_file)
        if not os.path.isfile(key_path) or not os.access(key_path, os.R_OK) or os.path.getsize(key_path) == 0:
            parser.error("--key-file does not point to a readable, non-empty file: %s" % args.key_file)
        args.key_file = key_path
    else:
        if args.key_file:
            parser.error("--key-file requires --paid")
        args.dry_run = True
    for name, value in (("--cap-usd", args.cap_usd), ("--run-cap-usd", args.run_cap_usd), ("--total-reserve-usd", args.total_reserve_usd),
                        ("--learn-cap-usd", args.learn_cap_usd)):
        if value is not None and not (math.isfinite(value) and value > 0):
            parser.error("%s must be a positive number of dollars" % name)
    if args.repeats < 1:
        parser.error("--repeats must be at least 1")
    if args.max_infra_errors is not None and args.max_infra_errors < 0:
        parser.error("--max-infra-errors must be 0 or more")
    if args.pilot and args.protocol != 3:
        parser.error("--pilot is protocol 3 only")
    if args.pilot:
        try:
            p3.pilot_arms(args.arms)
        except BenchError as exc:
            parser.error(str(exc))
    if args.command == "trim":
        if args.protocol != 3:
            parser.error("trim is protocol 3 only")
        if args.paid:
            parser.error("trim is free: it uses the mock meter only")
        if args.pilot:
            parser.error("trim belongs to a scored OUT, not a pilot")
        if args.mock_scenario not in (None, "shape"):
            parser.error("trim uses the shape scenario only")
    if args.rebuild_images and args.no_image_build:
        parser.error("--rebuild-images and --no-image-build exclude each other")
    if args.meter_image is not None:
        if args.paid:
            parser.error("--meter-image is dry-run only")
        if not METER_TAG_RE.match(args.meter_image):
            parser.error("--meter-image must look like olivium-bench-meter-NAME:TAG")
    return args


# --------------------------------------------------------------------- common
def reap_leftovers(ctx):
    for name in dk.leftover_names(ctx.tag, ["agent", "extract", "grade"]):
        dk.remove(name)


def docker_available():
    dk.docker("version", "--format", "{{.Server.Version}}", timeout=60)


def start_meter(ctx, reserve_usd=0.0):
    cap = ctx.args.cap_usd if ctx.paid else (ctx.args.cap_usd or DRY_RUN_CAP_USD)
    run_cap = ctx.args.run_cap_usd if ctx.paid else (ctx.args.run_cap_usd or DRY_RUN_RUN_CAP_USD)
    if ctx.paid:
        cap = cap - proposal_spend(ctx) - reserve_usd
        if cap <= 0:
            raise BenchError("no budget left for the meter after proposal spending and reserves")
    ctx.meter = meterctl.Meter(ctx.out, ctx.tag, ctx.paid, run_cap, cap, key_file=ctx.key_file,
                               refuse_web_tools=(ctx.protocol == 2), capture=capture_requests(ctx),
                               total_reserve_usd=ctx.args.total_reserve_usd)
    ctx.meter.up()


def capture_requests(ctx):
    """Request bodies are kept only in dry-run mode, and only for the capture scenarios."""
    return (not ctx.paid) and ctx.scenario in mockplans.CAPTURE_SCENARIOS


def copy_capture(ctx, run_id):
    if capture_requests(ctx):
        names = ctx.meter.copy_capture(run_id, os.path.join(ctx.out, "meter", "capture", run_id))
        print("captured %d request(s) of %s" % (len(names), run_id), flush=True)


def proposal_spend(ctx):
    total = 0.0
    for task in ctx.manifest["tasks"]:
        path = ctx.setup_path(task["task_id"], "olivium")
        if os.path.exists(path):
            total += float(read_json(path).get("cost_upper_bound_usd") or 0.0)
    return total


# -------------------------------------------------------------------- prepare
def agent_script_is_current(ctx, image):
    """Protocol v2 needs the hook-event and web-tool flags, so an image built before them is stale."""
    name = "olivium-bench-script-check-%s" % ctx.tag
    dk.remove(name)
    done = dk.docker(
        "run", "--rm", "--name", name, "--label", dk.LABEL, "--network", "none",
        "--entrypoint", "/bin/cat", image, "/usr/local/bin/olivium-agent-run", check=False, timeout=120,
    )
    if done.returncode != 0:
        return False
    with open(os.path.join(DOCKER_DIR, "agent-run.sh"), "rb") as handle:
        return done.stdout == handle.read()


def build_agent_images(ctx):
    records = {}
    for task in ctx.tasks:
        task_id = task["task_id"]
        image = ctx.agent_image(task)
        if dk.image_id(task["deps_image"]) is None:
            raise BenchError("deps image %s is missing" % task["deps_image"])
        stale = ctx.protocol == 2 and dk.image_id(image) is not None and not agent_script_is_current(ctx, image)
        if getattr(ctx.args, "no_image_build", False) and (stale or dk.image_id(image) is None):
            raise BenchError("%s is %s and --no-image-build forbids building it" % (image, "stale" if stale else "missing"))
        if ctx.args.rebuild_images or stale or dk.image_id(image) is None:
            print("building %s" % image, flush=True)
            done = dk.sh(
                [
                    "docker", "build", "-f", os.path.join(DOCKER_DIR, "agent.Dockerfile"),
                    "--build-arg", "DEPS_IMAGE=%s" % task["deps_image"],
                    "--label", "olivium-bench=1", "-t", image, DOCKER_DIR,
                ],
                timeout=1800,
            )
            if done.returncode != 0:
                raise BenchError("agent image build failed for %s: %s" % (task_id, done.stderr.decode("utf-8", "replace")[-600:]))
        records[task_id] = {"agent_image": image, "agent_image_id": dk.image_id(image), "deps_image_id": dk.image_id(task["deps_image"])}
    write_json_atomic(os.path.join(ctx.out, "images.json"), records)
    return records


def carry_prior_spend(ctx, task_id, arm, setup):
    """Money spent by an earlier failed attempt stays on the books after --retry-failed."""
    path = ctx.setup_path(task_id, arm)
    previous = read_json(path) if os.path.exists(path) else {}
    prior = float(previous.get("cost_upper_bound_usd") or previous.get("cost_usd") or 0.0)
    if prior > 0:
        setup["cost_usd"] = float(setup.get("cost_usd") or 0.0) + float(previous.get("cost_usd") or 0.0)
        setup["cost_upper_bound_usd"] = float(setup.get("cost_upper_bound_usd") or setup.get("cost_usd") or 0.0) + prior
        setup["prior_attempts_cost_usd"] = prior
    return setup


def setup_done(ctx, task_id, arm):
    path = ctx.setup_path(task_id, arm)
    return os.path.exists(path) and read_json(path).get("status") == "ok"


def needs_setup(ctx, task_id, arm):
    """Failed paid setup is not repeated unless --retry-failed: it may already have cost money."""
    path = ctx.setup_path(task_id, arm)
    if not os.path.exists(path):
        return True
    status = read_json(path).get("status")
    if status == "ok":
        return False
    return ctx.args.retry_failed or not ctx.paid


def cmd_prepare(ctx):
    ctx.check_material()
    if ctx.protocol_version == 3:
        p3.ensure_out_record(ctx)
    docker_available()
    reap_leftovers(ctx)
    images = build_agent_images(ctx)
    print("agent images ready: %d" % len(images), flush=True)
    if ctx.protocol_version == 3:
        # /init is a session too: it runs on the pinned Claude Code like every trial.
        p3.pin_claude_code(ctx)
        print("claude code %s in every agent image" % CLAUDE_CODE_VERSION, flush=True)
    for task in ctx.tasks:
        os.makedirs(ctx.arm_dir(task["task_id"], "none"), exist_ok=True)
        write_json_atomic(ctx.setup_path(task["task_id"], "none"), {"status": "ok", "arm": "none", "task_id": task["task_id"], "cost_usd": 0.0, "harness_bytes": 0})
    need_generic = [task for task in ctx.tasks if "generic" in ctx.arms and needs_setup(ctx, task["task_id"], "generic")]
    need_olivium = [task for task in ctx.tasks if "olivium" in ctx.arms and needs_setup(ctx, task["task_id"], "olivium")]
    failures = []
    if need_generic:
        reserve = olivium_arm.PROPOSAL_TASK_LIMIT_USD * len(need_olivium) if ctx.paid and ctx.protocol == 1 else 0.0
        start_meter(ctx, reserve_usd=reserve)
        try:
            for task in need_generic:
                task_id = task["task_id"]
                print("generic arm: %s" % task_id, flush=True)
                try:
                    setup = generic_arm.build(ctx, task, ctx.material_dir(task_id))
                except BenchError as exc:
                    # The meter has the rows, so a failed /init still reports what it spent.
                    usage = generic_arm.usage_so_far(ctx, task_id)
                    setup = {"status": "failed", "arm": "generic", "task_id": task_id, "error": str(exc),
                             "tokens": usage["tokens"], "cost_usd": usage["cost_usd"], "requests": usage["requests"]}
                    failures.append(("generic", task_id, str(exc)))
                write_json_atomic(ctx.setup_path(task_id, "generic"), setup)
        finally:
            ctx.meter.down()
            ctx.meter = None
    for task in need_olivium:
        task_id = task["task_id"]
        print("olivium arm: %s" % task_id, flush=True)
        try:
            builder = olivium_v2_arm if ctx.protocol == 2 else olivium_arm
            setup = builder.build(ctx, task, ctx.material_dir(task_id))
        except (BenchError, OSError) as exc:
            setup = {"status": "failed", "arm": "olivium", "task_id": task_id, "error": str(exc)}
            if isinstance(exc, SetupFailed):
                setup.update(exc.fields)
            failures.append(("olivium", task_id, str(exc)))
        write_json_atomic(ctx.setup_path(task_id, "olivium"), carry_prior_spend(ctx, task_id, "olivium", setup))
    # v2r olivium-nn (protocol 2 only): the same generator, snapshot and checks as olivium, with
    # --native none, at $0. A finished setup is never rebuilt inside an existing OUT, like olivium.
    if ctx.protocol_version == 2 and OLIVIUM_NN in ctx.arms:
        for task in [task for task in ctx.tasks if needs_setup(ctx, task["task_id"], OLIVIUM_NN)]:
            task_id = task["task_id"]
            print("%s arm: %s" % (OLIVIUM_NN, task_id), flush=True)
            try:
                setup = olivium_v2_arm.build(ctx, task, ctx.material_dir(task_id), arm=OLIVIUM_NN, extra_args=("--native", "none"))
            except (BenchError, OSError) as exc:
                setup = {"status": "failed", "arm": OLIVIUM_NN, "task_id": task_id, "error": str(exc), "cost_usd": 0.0}
                failures.append((OLIVIUM_NN, task_id, str(exc)))
            write_json_atomic(ctx.setup_path(task_id, OLIVIUM_NN), setup)
    # v4 dev arms (protocol 2 only): learning once per task base, then generate --context lean-ai.
    # The only paid prepare step they add is olivium-ai learning, on the runner's meter.
    v4_arms = [arm for arm in ctx.arms if arm in V4_OPTIONAL_ARMS] if ctx.protocol_version == 2 else []
    if v4_arms:
        total_cap = ctx.args.cap_usd - proposal_spend(ctx) if ctx.paid else (ctx.args.cap_usd or DRY_RUN_CAP_USD)
        failures.extend(olivium_ai_arm.prepare(ctx, v4_arms, needs_setup, total_cap))
    # none-lean is derived from the olivium export at $0, so it is rebuilt every time, after olivium.
    for task in (ctx.tasks if NONE_LEAN in ctx.arms else []):
        task_id = task["task_id"]
        print("none-lean arm: %s" % task_id, flush=True)
        try:
            setup = none_lean_arm.build(ctx, task)
        except (BenchError, OSError, ValueError) as exc:
            setup = {"status": "failed", "arm": NONE_LEAN, "task_id": task_id, "error": str(exc), "cost_usd": 0.0}
            failures.append((NONE_LEAN, task_id, str(exc)))
        write_json_atomic(ctx.setup_path(task_id, NONE_LEAN), setup)
    # v5 olivium-x (protocol 2 only): its lean-x export at $0, then none-lean's settings plus
    # the export's hooks and style, so it is built after none-lean.
    if ctx.protocol_version == 2 and OLIVIUM_X in ctx.arms:
        failures.extend(olivium_x_arm.prepare(ctx, needs_setup))
    cleanup(ctx)
    if failures:
        for arm, task_id, error in failures:
            print("FAILED %s %s: %s" % (arm, task_id, error), file=sys.stderr)
        return 2
    print("prepare complete", flush=True)
    return 0


# ------------------------------------------------------------------------ run
def select_arms(text, protocol=1, protocol_version=None):
    if not text:
        return ARMS
    names = [name.strip() for name in text.split(",") if name.strip()]
    known = ARMS + (OPTIONAL_ARMS if protocol == 2 else ())
    if (protocol_version if protocol_version is not None else protocol) == 2:
        # v4 development arms: protocol 2 only (protocol 3 maps to the protocol-2 code path, not to these).
        known = known + V4_OPTIONAL_ARMS
        # v5 development arm: protocol 2 only, like the v4 arms.
        known = known + V5_OPTIONAL_ARMS
        # v2r arm (PROTOCOL-v2r.md): protocol 2 only, like the v4 and v5 arms.
        known = known + V2R_OPTIONAL_ARMS
    unknown = [name for name in names if name not in known]
    if unknown or not names:
        raise BenchError("unknown arm(s): %s (arms: %s)" % (", ".join(unknown) or "none given", ", ".join(known)))
    return tuple(arm for arm in known if arm in names)


def schedule_path(ctx):
    """schedule.json for the default arms, as before; a selection with an optional arm keeps its own file."""
    if all(arm in ARMS for arm in ctx.arms):
        name = "schedule.json"
    else:
        name = "schedule.%s.json" % "+".join(ctx.arms)
    if ctx.protocol_version == 3:
        name = p3.schedule_name(ctx, name)
    return os.path.join(ctx.out, name)


def schedule_for(ctx):
    if ctx.protocol_version == 2 and tuple(ctx.arms) == (NONE_LEAN, OLIVIUM_X):
        # v5 dev test (v5 contract.md, lane C, item 5): the protocol 3 block schedule, one block per
        # (task, repeat) holding both arms once, blocks and in-block order shuffled with --seed.
        return p3.block_schedule([task["task_id"] for task in ctx.tasks], ctx.arms, ctx.repeats, ctx.seed)
    if ctx.protocol_version == 3:
        return p3.block_schedule([task["task_id"] for task in ctx.tasks], ctx.arms, ctx.repeats, ctx.seed,
                                 None if ctx.pilot else p3.SECONDARY_REPEATS)
    specs = []
    for task in ctx.tasks:
        for arm in ctx.arms:
            for repeat in range(1, ctx.repeats + 1):
                specs.append((task["task_id"], arm, repeat))
    rng = random.Random(ctx.seed)
    rng.shuffle(specs)
    return specs


def ensure_schedule(ctx):
    specs = schedule_for(ctx)
    path = schedule_path(ctx)
    payload = {"seed": ctx.seed, "tasks": [task["task_id"] for task in ctx.tasks], "repeats": ctx.repeats, "order": specs}
    if path != os.path.join(ctx.out, "schedule.json"):
        payload["arms"] = list(ctx.arms)
    if ctx.protocol_version == 3:
        payload.update(p3.schedule_extra(ctx))
    if os.path.exists(path):
        existing = read_json(path)
        if existing.get("order") != json.loads(json.dumps(specs)):
            raise BenchError("this output directory was scheduled with different tasks, repeats or seed: %s" % path)
    else:
        write_json_atomic(path, payload)
    return specs


def pending_trials(ctx, specs):
    rows = read_jsonl(ctx.trials_path)
    by_key = {}
    for row in rows:
        by_key.setdefault((row["task_id"], row["arm"], row["repeat"]), []).append(row)
    pending = []
    exhausted = []
    for task_id, arm, repeat in specs:
        prior = by_key.get((task_id, arm, repeat), [])
        if any(row["status"] != "infra_error" for row in prior):
            continue
        attempt = len(prior) + 1
        if attempt > MAX_ATTEMPTS:
            exhausted.append((task_id, arm, repeat))
            continue
        pending.append({"task_id": task_id, "arm": arm, "repeat": repeat, "attempt": attempt, "run_id": run_id_for(task_id, arm, repeat, attempt)})
    return pending, exhausted


def check_arms_ready(ctx):
    problems = []
    for task in ctx.tasks:
        for arm in ctx.arms:
            if not setup_done(ctx, task["task_id"], arm):
                problems.append("%s/%s" % (task["task_id"], arm))
            elif arm == NONE_LEAN:
                problems.extend(none_lean_arm.check_ready(ctx, task["task_id"]))
            elif arm in V4_OPTIONAL_ARMS:
                problems.extend(olivium_ai_arm.check_ready(ctx, task["task_id"], arm))
            elif arm in V5_OPTIONAL_ARMS:
                problems.extend(olivium_x_arm.check_ready(ctx, task["task_id"]))
            elif arm == OLIVIUM_NN and not os.path.isfile(os.path.join(ctx.arm_dir(task["task_id"], arm), ".claude", "settings.json")):
                problems.append("%s/%s settings" % (task["task_id"], arm))
        if dk.image_id(ctx.agent_image(task)) is None:
            problems.append("image %s" % ctx.agent_image(task))
    if problems:
        raise BenchError("not ready (run prepare first): %s" % ", ".join(problems))


def cmd_run(ctx):
    ctx.check_material()
    if ctx.protocol_version == 3:
        p3.check_scored_selection(ctx)
        p3.ensure_out_record(ctx)
    check_arms_ready(ctx)
    docker_available()
    reap_leftovers(ctx)
    if ctx.protocol_version == 3:
        busy = p3.selection_busy() if ctx.paid else []
        if busy:
            raise BenchError("the v3 selection is using Docker (%s); stop the walk first (touch V3/STOP and wait for it "
                             "to exit) so grading runs with nothing else on Docker" % ", ".join(busy[:3]))
        p3.pin_claude_code(ctx)
        problems = p3.trim_problems(ctx) if not ctx.pilot else []
        if problems and ctx.paid:
            raise BenchError("no trim recorded for this scored run: %s" % "; ".join(problems))
        for problem in problems:
            print("warning (dry run): %s; a paid run would refuse to start" % problem, flush=True)
    specs = ensure_schedule(ctx)
    start_meter(ctx)
    try:
        finalized = trial_ops.finalize_interrupted(ctx, ctx.tasks_by_id)
        if finalized:
            print("recorded %d interrupted run(s) as infra_error: %s" % (len(finalized), ", ".join(finalized)), flush=True)
        pending, exhausted = pending_trials(ctx, specs)
        print("trials: %d scheduled, %d pending, %d out of attempts" % (len(specs), len(pending), len(exhausted)), flush=True)
        work = queue.Queue()
        for spec in pending:
            work.put(spec)
        stop = threading.Event()
        if ctx.meter.total_cap_reached():
            print("total cap already reached; no trial will start", flush=True)
            stop.set()
        if infra_limit_passed(ctx, specs):
            print("more than %d infra_error rows already recorded; no trial will start" % ctx.args.max_infra_errors, flush=True)
            stop.set()

        def worker():
            while not stop.is_set():
                if not ctx.meter.running():
                    # Without this every remaining trial would burn its attempts on a dead meter.
                    print("meter is not running; no further trial will start (re-run to resume)", flush=True)
                    stop.set()
                    return
                try:
                    spec = work.get_nowait()
                except queue.Empty:
                    return
                task = ctx.tasks_by_id[spec["task_id"]]
                print("start %s" % spec["run_id"], flush=True)
                try:
                    row = trial_ops.execute_trial(ctx, spec, task, ctx.material_dir(spec["task_id"]))
                    copy_capture(ctx, spec["run_id"])
                    print("done  %s status=%s solved=%s cost=%s" % (spec["run_id"], row["status"], row["solved"], row["cost_usd"]), flush=True)
                    if row["status"] == "infra_error" and trial_ops.web_guard_failed(ctx, spec["run_id"]):
                        # Systematic, not transient: every further run would fail the same way and still cost money.
                        print("web guard failed in %s; no further trial will start (PROTOCOL-v2.md, change log)" % spec["run_id"], flush=True)
                        stop.set()
                    if row["status"] == "infra_error" and trial_ops.version_pin_failed(ctx, spec["run_id"]):
                        print("%s ran another Claude Code than the pinned %s; no further trial will start" % (spec["run_id"], CLAUDE_CODE_VERSION), flush=True)
                        stop.set()
                    if row["status"] == "infra_error" and infra_limit_passed(ctx, specs):
                        if not stop.is_set():
                            print("more than %d infra_error rows recorded; no further trial will start (PROTOCOL-v2r.md, stop rule 2)"
                                  % ctx.args.max_infra_errors, flush=True)
                        stop.set()
                    if ctx.meter.hit_total_cap(spec["run_id"]) or ctx.meter.total_cap_reached():
                        if not stop.is_set():
                            print("total cap reached; no further trial will start", flush=True)
                        stop.set()
                except Exception as exc:  # any unexpected failure: keep the run going
                    print("error %s: %s: %s" % (spec["run_id"], type(exc).__name__, exc), file=sys.stderr, flush=True)

        sessions = getattr(ctx.args, "sessions", None) or CONCURRENCY
        print("sessions at a time: %d" % sessions, flush=True)
        threads = [threading.Thread(target=worker, name="trial-%d" % index) for index in range(sessions)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        pending_after, exhausted = pending_trials(ctx, specs)
        # Protocol 2 scores the harness as exported, so that one-off run has no purpose.
        code = run_as_exported(ctx) if ctx.protocol == 1 and not ctx.args.no_as_exported and not pending_after else 0
        print("run finished: %d pending, %d out of attempts" % (len(pending_after), len(exhausted)), flush=True)
    finally:
        ctx.meter.down()
        cleanup(ctx)
    return 0 if not pending_after and not code else 1


def infra_limit_passed(ctx, specs):
    """--max-infra-errors: more than N infra_error rows recorded for the scheduled (task, arm) pairs."""
    limit = getattr(ctx.args, "max_infra_errors", None)
    if limit is None:
        return False
    pairs = {(task_id, arm) for task_id, arm, _repeat in specs}
    count = sum(1 for row in read_jsonl(ctx.trials_path)
                if row.get("status") == "infra_error" and (row.get("task_id"), row.get("arm")) in pairs)
    return count > limit


def run_as_exported(ctx):
    """One run with the settings exactly as exported. Reported separately, never scored."""
    task = ctx.tasks[0]
    task_id = task["task_id"]
    base = os.path.join(ctx.out, "as_exported", task_id)
    result_path = os.path.join(base, "result.json")
    if os.path.exists(result_path):
        return 0
    os.makedirs(base, exist_ok=True)
    spec = {"task_id": task_id, "arm": "olivium", "repeat": 1, "attempt": 1, "run_id": "as-exported.%s" % task_id}
    arm_dirs = [ctx.arm_dir(task_id, "olivium"), ctx.exported_dir(task_id)]
    print("as-exported settings run: %s" % task_id, flush=True)
    row, details = trial_ops.run_and_grade(
        ctx, spec, task, ctx.material_dir(task_id), arm_dirs, None, "default", base,
    )
    write_json_atomic(result_path, {"as_exported": True, "row": row, "details": details, "note": "Not part of the analysis (PROTOCOL.md, Arms)."})
    print("as-exported: status=%s tool_calls=%s" % (row["status"], row["tool_calls"]), flush=True)
    return 0


def cleanup(ctx):
    reap_leftovers(ctx)
    for name in dk.leftover_names(ctx.tag, ["meter"]):
        dk.remove(name)
    for name in ("olivium-bench-int-%s" % ctx.tag, "olivium-bench-egress-%s" % ctx.tag):
        dk.network_remove(name)


# --------------------------------------------------------------------- status
def cmd_status(ctx):
    report = {"out": ctx.out, "tag": ctx.tag, "tasks": {}}
    for task in ctx.tasks:
        arms = {}
        for arm in ARMS + tuple(arm for arm in ctx.arms if arm not in ARMS):
            path = ctx.setup_path(task["task_id"], arm)
            if os.path.exists(path):
                setup = read_json(path)
                arms[arm] = {key: setup.get(key) for key in ("status", "error", "cost_usd", "harness_bytes", "rehearsal_fixture", "claims_approved", "digest", "learning") if setup.get(key) is not None}
            else:
                arms[arm] = {"status": "missing"}
        report["tasks"][task["task_id"]] = arms
    rows = read_jsonl(ctx.trials_path)
    specs = schedule_for(ctx)
    pending, exhausted = pending_trials(ctx, specs)
    by_status = {}
    for row in rows:
        by_status[row["status"]] = by_status.get(row["status"], 0) + 1
    report["trials"] = {
        "scheduled": len(specs), "recorded_rows": len(rows), "pending": len(pending),
        "out_of_attempts": len(exhausted), "by_status": by_status,
        "cost_usd": round(sum(float(row.get("cost_usd") or 0) for row in rows), 6),
        "solved": sum(1 for row in rows if row.get("solved")),
    }
    log = os.path.join(ctx.out, "meter", "requests.jsonl")
    if os.path.exists(log):
        meter_rows = read_jsonl(log)
        report["meter"] = {"requests": len(meter_rows), "cost_usd": round(sum(int(r.get("cost_nanousd") or 0) for r in meter_rows) / 1e9, 6)}
    if ctx.protocol_version == 3:
        report["protocol3"] = {
            "record": p3.read_out_record(ctx),
            "schedule_file": os.path.basename(schedule_path(ctx)),
            "longest_single_setup_stretch": p3.longest_stretch(specs),
            "trim": p3.trim_summary(ctx) if not ctx.pilot else None,
        }
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


# ----------------------------------------------------------------------- trim
def cmd_trim(ctx):
    """$0: each task's first request in the none and olivium setups -> OUT/trim.json."""
    ctx.check_material()
    p3.ensure_out_record(ctx)
    arms = p3.trim_arms(ctx)
    problems = []
    for task in ctx.tasks:
        for arm in arms:
            if not setup_done(ctx, task["task_id"], arm):
                problems.append("%s/%s" % (task["task_id"], arm))
            elif arm == NONE_LEAN:
                problems.extend(none_lean_arm.check_ready(ctx, task["task_id"]))
    if problems:
        raise BenchError("not ready (run prepare first): %s" % ", ".join(problems))
    docker_available()
    p3.pin_claude_code(ctx)
    payload = p3.measure_trim(ctx, DRY_RUN_RUN_CAP_USD, DRY_RUN_CAP_USD)
    print("trim recorded for %d task(s) in %s" % (len(payload["tasks"]), os.path.join(ctx.out, p3.TRIM_FILE)), flush=True)
    return 0


def main(argv):
    args = parse_args(argv)
    ctx = Ctx(args)
    try:
        if args.command == "prepare":
            return cmd_prepare(ctx)
        if args.command == "run":
            return cmd_run(ctx)
        if args.command == "trim":
            return cmd_trim(ctx)
        return cmd_status(ctx)
    except BenchError as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 3
    except KeyboardInterrupt:
        print("interrupted; re-run the same command to resume", file=sys.stderr)
        cleanup(ctx)
        return 130


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
