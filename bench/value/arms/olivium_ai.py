"""The olivium-ai and olivium-det arms (protocol 2 only, v4 development rehearsal).

olivium-ai: the `lean-ai` export of `bin/harnessforge generate`, built from the task's
repository at the base commit plus a learned bundle that `bin/harnessforge learn` made
once for that base, from that commit and its ancestors only. Installed unmodified and
run with its own settings in `default` permission mode, like the olivium arm.

olivium-det: the same export built from a bundle made without --allow-cloud. Its learner
status is `unavailable` (cloud_not_allowed), so it holds only the verified deterministic
commands and rewrites: the ablation that shows what the AI part adds.

Learning in the bench (contract-v4.md section 2.2): the learner container talks to the
runner's meter (`--meter-url http://meter:8080/run/learn-<repo>-<base12>` on the
runner's internal network), so every learning request is in OUT/meter/requests.jsonl
and counts against the same total cap. `--dry-run` passes a scripted plan
(`--mock-plan`, lib/mockplans.learner_plan): the bundle says `mock`, and a paid run
refuses a mock bundle. Nothing from the repository runs on the host: host code runs git
and this application; the learner and command verification run in Docker.
"""

import json
import os
import re
import shutil
import subprocess

from lib.common import (
    REPO_ROOT,
    BenchError,
    SetupFailed,
    read_json,
    sha256_bytes,
    sha256_file,
    tree_bytes,
    tree_digest,
    tree_files,
    write_json_atomic,
)
from lib import meterctl
from lib import mockplans
from arms import olivium as olivium_v1
from arms import olivium_v2

OLIVIUM_AI = "olivium-ai"
OLIVIUM_DET = "olivium-det"
V4_ARMS = (OLIVIUM_AI, OLIVIUM_DET)
LEARN_MODELS = {"claude-haiku-5-5": 0.10, "claude-sonnet-5-5": 0.50}
DEFAULT_LEARN_MODEL = "claude-haiku-5-5"
LEARN_MAX_TURNS = 15
LEARN_TIMEOUT_S = 2700
GENERATE_TIMEOUT_S = 900
LEARNER_STATUSES = ("ok", "mock", "failed", "unavailable")
SNAPSHOT_V4_ITEMS = ("lib", "config", "priv", "bin/harnessforge", "mix.exs", "mix.lock", "deps", "_build/dev")
SUMMARY_PREFIXES = ("AI learning:", "Kept:", "Dropped:", "Bundle:")
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")


# ---------------------------------------------------------------- snapshot
PINNED_APP_ENV = "OLIVIUM_BENCH_V4_APP"
# Dry run only: a learner image other than the CLI's default (for example one built from a frozen copy).
LEARNER_IMAGE_ENV = "OLIVIUM_BENCH_V4_LEARNER_IMAGE"


def snapshot_digests(root=REPO_ROOT):
    """What the v4 snapshot depends on: the whole of priv, so the learner prompt and schemas count."""
    return {
        "lib_sha256": tree_digest(os.path.join(root, "lib")),
        "config_sha256": tree_digest(os.path.join(root, "config")),
        "priv_sha256": tree_digest(os.path.join(root, "priv")),
        "bin_harnessforge_sha256": sha256_file(os.path.join(root, "bin", "harnessforge")),
        "mix_exs_sha256": sha256_file(os.path.join(root, "mix.exs")),
        "mix_lock_sha256": sha256_file(os.path.join(root, "mix.lock")),
    }


def ensure_snapshot(out_dir, paid=False):
    """OUT/app-snapshot-v4: the application the v4 arms run, re-taken when the source changes.

    Dry run only: OLIVIUM_BENCH_V4_APP=DIR runs an application directory as it is (for
    example a frozen copy while other lanes edit the tree). Its digests are recorded in
    every setup it serves; a paid run refuses it.
    """
    pinned = os.environ.get(PINNED_APP_ENV)
    if pinned:
        if paid:
            raise BenchError("%s is dry-run only; a paid run uses the snapshot of the tree" % PINNED_APP_ENV)
        pinned = os.path.realpath(pinned)
        if not os.path.isfile(os.path.join(pinned, "bin", "harnessforge")):
            raise BenchError("%s=%s has no bin/harnessforge" % (PINNED_APP_ENV, pinned))
        return pinned, dict(snapshot_digests(pinned), pinned_app=pinned)
    snapshot = os.path.join(out_dir, "app-snapshot-v4")
    marker = os.path.join(snapshot, ".complete")
    record_path = os.path.join(out_dir, "app-snapshot-v4.json")
    current = snapshot_digests()
    if os.path.exists(marker) and os.path.exists(record_path):
        recorded = read_json(record_path)
        if all(recorded.get(key) == value for key, value in current.items()):
            return snapshot, current
        print("v4 application snapshot is stale (source changed); re-taking it", flush=True)
    shutil.rmtree(snapshot, ignore_errors=True)
    os.makedirs(snapshot)
    for item in SNAPSHOT_V4_ITEMS:
        source = os.path.join(REPO_ROOT, item)
        target = os.path.join(snapshot, item)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        if os.path.isdir(source):
            shutil.copytree(source, target, symlinks=True, ignore=olivium_v1.SNAPSHOT_IGNORE)
        elif os.path.isfile(source):
            shutil.copy2(source, target)
    write_json_atomic(record_path, dict(current, note="Snapshot of the application used by the v4 arms (learn, generate --context lean-ai)."))
    with open(marker, "w", encoding="utf-8") as handle:
        handle.write("ok\n")
    return snapshot, current


# ---------------------------------------------------------------- helpers
def _git(repo, *args):
    done = subprocess.run(olivium_v2.GIT + ["-C", repo] + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          timeout=600, check=False)
    if done.returncode != 0:
        raise BenchError("git %s failed in %s: %s" % (args[0], repo, done.stderr.decode("utf-8", "replace")[:300]))
    return done.stdout.decode("utf-8", "replace")


def learn_run_id(task):
    """learn-<repo name>-<base12>: one learning run per task base (contract-v4.md section 2.2)."""
    name = re.sub(r"[^A-Za-z0-9._-]", "-", task["repo"].split("/", 1)[1])[:60]
    return "learn-%s-%s" % (name, task["base_sha"][:12])


def bundle_dir(ctx, task, arm):
    """One bundle per task base and arm kind; never overwritten (learn refuses a used directory)."""
    kind = "det" if arm == OLIVIUM_DET else ("mock" if not ctx.paid else "ai")
    return os.path.join(ctx.out, "learned", "%s-%s" % (task["task_id"], kind))


def read_bundle(directory):
    """(document, file sha256) after checking learned.sha256 against the file bytes."""
    path = os.path.join(directory, "learned.json")
    sums = os.path.join(directory, "learned.sha256")
    if not os.path.isfile(path) or not os.path.isfile(sums):
        raise BenchError("no complete bundle in %s" % directory)
    with open(path, "rb") as handle:
        data = handle.read()
    with open(sums, "r", encoding="ascii", errors="replace") as handle:
        recorded = handle.read().split()
    digest = sha256_bytes(data)
    if not recorded or recorded[0] != digest:
        raise BenchError("learned.sha256 does not match learned.json in %s" % directory)
    doc = json.loads(data.decode("utf-8"))
    if not isinstance(doc, dict) or doc.get("schema") != "olivium.learned/v1":
        raise BenchError("not an olivium.learned/v1 bundle: %s" % directory)
    if not HEX64.match(str(doc.get("sha256") or "")):
        raise BenchError("bundle has no sha256 field: %s" % directory)
    learner = doc.get("learner") or {}
    if learner.get("status") not in LEARNER_STATUSES:
        raise BenchError("bundle learner.status %r is not one of %s" % (learner.get("status"), ", ".join(LEARNER_STATUSES)))
    return doc, digest


def history_facts(repo, limit=200):
    """Host git only: recent first-parent commits with subjects and files, for the scripted plan."""
    text = _git(repo, "log", "--first-parent", "--no-merges", "-n", str(limit), "--name-only", "--format=%x01%H%x02%s")
    commits = []
    for record in text.split("\x01")[1:]:
        lines = [line for line in record.split("\n") if line.strip()]
        if not lines or "\x02" not in lines[0]:
            continue
        sha, subject = lines[0].split("\x02", 1)
        commits.append({"hash": sha.strip(), "subject": subject.strip(), "files": [line.strip() for line in lines[1:]]})
    patterns = {}
    for pattern in mockplans.LEARNER_PITFALL_PATTERNS:
        found = _git(repo, "log", "--first-parent", "--no-merges", "-n", "5", "--format=%H", "-G", re.escape(pattern))
        patterns[pattern] = [line.strip() for line in found.splitlines() if HEX40.match(line.strip())]
    return {"commits": commits, "pitfall_commits": patterns, "paths": set(_git(repo, "ls-files").splitlines())}


def _generator_env(workspace):
    return olivium_v2._generator_env(workspace)


def _run_cli(snapshot, argv, workspace, log_base, timeout):
    """Run bin/harnessforge from the snapshot; returns (exit code, parsed JSON report or None)."""
    stdout_path = log_base + ".stdout.log"
    stderr_path = log_base + ".stderr.log"
    with open(stdout_path, "wb") as out, open(stderr_path, "wb") as err:
        try:
            done = subprocess.run([os.path.join(snapshot, "bin", "harnessforge")] + argv, cwd=snapshot,
                                  env=_generator_env(workspace), stdout=out, stderr=err, timeout=timeout)
            code = done.returncode
        except subprocess.TimeoutExpired:
            code = None
    token = os.path.join(workspace, "access-token")
    if os.path.exists(token):
        os.unlink(token)
    with open(stdout_path, "rb") as handle:
        report = olivium_v2._parse_generator_output(handle.read())
    return code, report


# ---------------------------------------------------------------- learn
def learn(ctx, task, arm, repo, snapshot, work, meter):
    """Make the bundle for this task base, or reuse the one already made. Returns (doc, sha, record)."""
    target = bundle_dir(ctx, task, arm)
    if os.path.isdir(target) and os.listdir(target):
        doc, digest = read_bundle(target)
        print("%s: reusing bundle %s (%s)" % (task["task_id"], os.path.relpath(target, ctx.out), doc["learner"]["status"]), flush=True)
        return doc, digest, {"reused": True, "argv": None, "exit": 0}
    os.makedirs(os.path.dirname(target), exist_ok=True)
    workspace = os.path.join(work, "learn-workspace")
    os.makedirs(workspace, exist_ok=True)
    run_id = learn_run_id(task)
    model = ctx.args.learn_model or DEFAULT_LEARN_MODEL
    cap = ctx.args.learn_cap_usd or LEARN_MODELS[model]
    argv = ["learn", os.path.realpath(repo), "--out", target, "--verify-image", task["deps_image"],
            "--max-turns", str(LEARN_MAX_TURNS), "--json"]
    learner_image = os.environ.get(LEARNER_IMAGE_ENV)
    if learner_image:
        if ctx.paid:
            raise BenchError("%s is dry-run only; a paid run uses the CLI's learner image" % LEARNER_IMAGE_ENV)
        argv += ["--learner-image", learner_image]
    if arm == OLIVIUM_AI:
        argv += ["--meter-url", "http://meter:8080/run/%s" % run_id, "--network", meter.internal,
                 "--model", model, "--cap-usd", "%.2f" % cap]
        if ctx.paid:
            argv += ["--allow-cloud", "--key-file", ctx.key_file]
        else:
            plan_path = os.path.join(work, "learner-plan.json")
            plan = mockplans.learner_plan(mockplans.learner_raw(history_facts(repo), task))
            with open(plan_path, "w", encoding="utf-8") as handle:
                json.dump(plan, handle, indent=2, sort_keys=True)
            argv += ["--mock-plan", plan_path]
    # olivium-det: no --allow-cloud and no plan, so the learner does not run (unavailable/cloud_not_allowed).
    code, report = _run_cli(snapshot, argv, workspace, os.path.join(work, "learn"), LEARN_TIMEOUT_S)
    usage = meterctl.usage_summary(meter.rows_for(run_id)) if meter is not None else {
        "tokens": {"input": 0, "output": 0, "cache_creation": 0, "cache_read": 0}, "cost_usd": 0.0, "requests": 0}
    record = {"reused": False, "argv": [a if a != ctx.key_file else "<key-file>" for a in argv], "exit": code,
              "meter_run_id": run_id if arm == OLIVIUM_AI else None, "meter_usage": usage}
    with open(os.path.join(work, "learn.record.json"), "w", encoding="utf-8") as handle:
        json.dump(record, handle, indent=2, sort_keys=True)
    if code != 0:
        raise SetupFailed("learn failed for %s (exit %s); see %s" % (task["task_id"], code, os.path.join(work, "learn.stderr.log")),
                          {"cost_usd": usage["cost_usd"], "cost_upper_bound_usd": usage["cost_usd"], "tokens": usage["tokens"],
                           "setup_model_calls": usage["requests"]})
    doc, digest = read_bundle(target)
    return doc, digest, record


def locator_summary(locator):
    """The locator gate result from the export's spec, without the index rows (those stay in .olivium/spec.json)."""
    if not isinstance(locator, dict):
        return locator
    summary = {key: value for key, value in locator.items() if key not in ("index", "constants", "stem_stopwords")}
    index = locator.get("index") if isinstance(locator.get("index"), dict) else {}
    summary["index_rows"] = {key: len(value) for key, value in sorted(index.items()) if isinstance(value, list)}
    return summary


def _argv_value(argv, flag):
    """The value after flag in a recorded argv, or None (a reused bundle has no argv)."""
    if not isinstance(argv, list) or flag not in argv:
        return None
    index = argv.index(flag)
    return argv[index + 1] if index + 1 < len(argv) else None


def check_summary_lines(text):
    """The text summary prefixes of contract-v4.md section 2.2, as the CLI prints them."""
    return {prefix: any(line.startswith(prefix) for line in text.splitlines()) for prefix in SUMMARY_PREFIXES}


# ---------------------------------------------------------------- build
def build(ctx, task, material_dir, arm, meter):
    if arm not in V4_ARMS:
        raise BenchError("not a v4 arm: %s" % arm)
    task_id = task["task_id"]
    bare_clone = os.path.join(ctx.clones_dir, task["repo"].replace("/", "__") + ".git")
    work = os.path.join(ctx.out, "%s-work" % arm, task_id)
    shutil.rmtree(work, ignore_errors=True)
    repo = os.path.join(work, task["repo"].split("/", 1)[1])
    workspace = os.path.join(work, "workspace")
    export_dir = os.path.join(work, "export")
    empty = os.path.join(work, "empty")
    os.makedirs(workspace)
    os.makedirs(empty)
    olivium_v2.build_truncated_repo(bare_clone, task["base_sha"], repo)
    removed = olivium_v2.remove_instruction_files(repo)
    # Learning reads only the base and its ancestors: checked before the learner sees the repository.
    pre = olivium_v2.assert_no_post_base(task, repo, empty, bare_clone)
    if pre["failures"]:
        raise BenchError("post-base check failed before learning for %s: %s" % (task_id, "; ".join(pre["failures"])))
    snapshot, snapshot_record = ensure_snapshot(ctx.out, ctx.paid)
    doc, bundle_sha, learn_record = learn(ctx, task, arm, repo, snapshot, work, meter)
    learner = doc.get("learner") or {}
    if ctx.paid and learner.get("status") == "mock":
        raise BenchError("a paid run refuses a mock bundle (%s)" % bundle_dir(ctx, task, arm))
    if arm == OLIVIUM_DET and learner.get("status") != "unavailable":
        raise BenchError("olivium-det needs a bundle made without --allow-cloud (learner.status %r)" % learner.get("status"))
    wanted = "ok" if ctx.paid else "mock"
    if arm == OLIVIUM_AI and learner.get("status") != wanted:
        # Visible, never a quiet olivium-det: the bundle is set aside so --retry-failed learns again.
        target = bundle_dir(ctx, task, arm)
        attempt = 1
        while os.path.exists("%s.failed-%d" % (target, attempt)):
            attempt += 1
        os.rename(target, "%s.failed-%d" % (target, attempt))
        usage = learn_record.get("meter_usage") or {}
        raise SetupFailed("olivium-ai needs learner.status %s, the bundle says %s/%s (kept as %s.failed-%d)"
                          % (wanted, learner.get("status"), learner.get("status_reason"), os.path.basename(target), attempt),
                          {"cost_usd": float(usage.get("cost_usd") or 0.0), "cost_upper_bound_usd": float(usage.get("cost_usd") or 0.0),
                           "tokens": usage.get("tokens"), "setup_model_calls": int(usage.get("requests") or 0)})
    if (doc.get("repository") or {}).get("base_commit") != task["base_sha"]:
        raise BenchError("bundle base %r is not the task base %s" % ((doc.get("repository") or {}).get("base_commit"), task["base_sha"]))
    code, report = _run_cli(
        snapshot,
        ["generate", os.path.realpath(repo), "--runtime", "claude_code", "--export", os.path.realpath(export_dir),
         "--context", "lean-ai", "--learned", bundle_dir(ctx, task, arm), "--json"],
        workspace, os.path.join(work, "generate"), GENERATE_TIMEOUT_S,
    )
    if code != 0 or report is None or not report.get("ok"):
        message = (report or {}).get("error") if isinstance(report, dict) else None
        raise BenchError("generate --context lean-ai failed for %s (exit %s, %s); see %s"
                         % (task_id, code, message, os.path.join(work, "generate.stderr.log")))
    if not os.path.isdir(export_dir):
        raise BenchError("generate produced no export directory for %s" % task_id)
    post = olivium_v2.assert_no_post_base(task, repo, export_dir, bare_clone)
    bundle_scan = olivium_v2.assert_no_post_base(task, repo, bundle_dir(ctx, task, arm), bare_clone)
    failures = post["failures"] + ["bundle:" + item for item in bundle_scan["failures"]]
    if failures:
        raise BenchError("post-base check failed for %s: %s" % (task_id, "; ".join(failures)))
    arm_dir = ctx.arm_dir(task_id, arm)
    shutil.rmtree(arm_dir, ignore_errors=True)
    shutil.copytree(export_dir, arm_dir, symlinks=False)
    settings_path = os.path.join(arm_dir, ".claude", "settings.json")
    spec_path = os.path.join(arm_dir, ".olivium", "spec.json")
    copy_path = os.path.join(arm_dir, ".olivium", "learned.json")
    for path in (settings_path, spec_path, copy_path):
        if not os.path.isfile(path):
            raise BenchError("the lean-ai export of %s has no %s" % (task_id, os.path.relpath(path, arm_dir)))
    if sha256_file(copy_path) != bundle_sha:
        raise BenchError("the export's .olivium/learned.json is not a byte copy of the bundle for %s" % task_id)
    spec = (read_json(spec_path).get("spec") or {})
    if (spec.get("context") or {}).get("profile") != "lean-ai":
        raise BenchError("the export is not the lean-ai profile (spec.context.profile=%r)" % (spec.get("context") or {}).get("profile"))
    with open(os.path.join(work, "generate.report.json"), "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, sort_keys=True)
    result = report.get("result") or {}
    tokens = learner.get("tokens") or {}
    usage = learn_record.get("meter_usage") or {}
    learning = {
        "bundle_sha256": doc.get("sha256"),
        "bundle_file_sha256": bundle_sha,
        "bundle_dir": os.path.relpath(bundle_dir(ctx, task, arm), ctx.out),
        "reused": bool(learn_record.get("reused")),
        "status": learner.get("status"),
        "status_reason": learner.get("status_reason"),
        "model": learner.get("model"),
        "requests": int(learner.get("requests") or 0),
        "tokens": {key: int(tokens.get(key) or 0) for key in ("input", "output", "cache_read", "cache_write")},
        "cost_usd": round(int(learner.get("cost_nanousd") or 0) / 1e9, 9),
        "wall_s": round(int(learner.get("wall_ms") or 0) / 1000.0, 3),
        "meter_run_id": learn_record.get("meter_run_id"),
        "learner_image": (_argv_value(learn_record.get("argv"), "--learner-image")
                          or (None if learn_record.get("reused") else "cli-default")),
        "verification_status": (doc.get("verification") or {}).get("status"),
        "kept": {kind: len(doc.get(kind) or []) for kind in ("concepts", "pitfalls", "commands", "rewrites")},
        "dropped": len(doc.get("dropped") or []),
        "spec_learning": spec.get("learning"),
        "spec_locator": locator_summary(spec.get("locator")),
    }
    # The meter is the authority for money in the bench; the bundle's own record is kept beside it.
    meter_cost = float(usage.get("cost_usd") or 0.0) if not learn_record.get("reused") else 0.0
    return {
        "status": "ok",
        "arm": arm,
        "task_id": task_id,
        "mode": "paid" if ctx.paid else "rehearsal",
        "rehearsal_fixture": learner.get("status") == "mock",
        "generator": "bin/harnessforge learn + generate --context lean-ai --learned --json",
        "learning": learning,
        "setup_model_calls": int(usage.get("requests") or 0) if not learn_record.get("reused") else 0,
        "cost_usd": meter_cost,
        "cost_upper_bound_usd": meter_cost,
        "tokens": usage.get("tokens") if not learn_record.get("reused") else {"input": 0, "output": 0, "cache_creation": 0, "cache_read": 0},
        "learn": {k: v for k, v in learn_record.items() if k != "meter_usage"},
        "app_snapshot": snapshot_record,
        "digest": result.get("digest"),
        "profile_digest": result.get("profile_digest"),
        "blueprint_version": result.get("blueprint_version"),
        "counts": result.get("counts"),
        "diagnostics": result.get("diagnostics"),
        "removed_instruction_files": removed,
        "post_base_check": post,
        "post_base_check_before_learning": pre,
        "harness_files": tree_files(arm_dir),
        "harness_bytes": tree_bytes(arm_dir),
        "arm_sha256": tree_digest(arm_dir),
        "exported_settings_sha256": sha256_file(settings_path),
    }


def start_learning_meter(ctx, total_cap_usd):
    """The runner's meter for learning in prepare: per-run cap = the learning cap of the model."""
    model = ctx.args.learn_model or DEFAULT_LEARN_MODEL
    run_cap = ctx.args.learn_cap_usd or LEARN_MODELS[model]
    meter = meterctl.Meter(ctx.out, ctx.tag, ctx.paid, run_cap, total_cap_usd, key_file=ctx.key_file,
                           refuse_web_tools=True, total_reserve_usd=ctx.args.total_reserve_usd)
    meter.up()
    return meter


def prepare(ctx, arms, needs_setup, total_cap_usd):
    """Build every v4 arm that needs it. Returns [(arm, task_id, error)] for the failures."""
    failures = []
    todo = [(task, arm) for task in ctx.tasks for arm in V4_ARMS if arm in arms and needs_setup(ctx, task["task_id"], arm)]
    if not todo:
        return failures
    if ctx.paid:
        for name in (PINNED_APP_ENV, LEARNER_IMAGE_ENV):
            if os.environ.get(name):
                raise BenchError("%s is dry-run only; unset it for a paid run" % name)
    meter = start_learning_meter(ctx, total_cap_usd) if any(arm == OLIVIUM_AI for _t, arm in todo) else None
    try:
        for task, arm in todo:
            task_id = task["task_id"]
            print("%s arm: %s" % (arm, task_id), flush=True)
            try:
                setup = build(ctx, task, ctx.material_dir(task_id), arm, meter)
            except (BenchError, OSError, ValueError) as exc:
                setup = {"status": "failed", "arm": arm, "task_id": task_id, "error": str(exc)}
                if isinstance(exc, SetupFailed):
                    setup.update(exc.fields)
                failures.append((arm, task_id, str(exc)))
            write_json_atomic(ctx.setup_path(task_id, arm), setup)
    finally:
        if meter is not None:
            meter.down()
    return failures


def exported_settings(ctx, task_id, arm):
    with open(os.path.join(ctx.arm_dir(task_id, arm), ".claude", "settings.json"), "rb") as handle:
        return handle.read()


def check_ready(ctx, task_id, arm):
    """Problems that make a trial of this arm unsafe to start; empty when ready."""
    setup = read_json(ctx.setup_path(task_id, arm))
    learning = setup.get("learning") or {}
    problems = []
    try:
        doc, digest = read_bundle(os.path.join(ctx.out, learning.get("bundle_dir") or "missing"))
    except BenchError as exc:
        return ["%s/%s: %s" % (task_id, arm, exc)]
    if digest != learning.get("bundle_file_sha256"):
        problems.append("%s/%s: the bundle changed after prepare" % (task_id, arm))
    if ctx.paid and doc["learner"].get("status") == "mock":
        problems.append("%s/%s: a paid run refuses a mock bundle (prepare it with --paid)" % (task_id, arm))
    arm_dir = ctx.arm_dir(task_id, arm)
    if not os.path.isdir(arm_dir) or tree_digest(arm_dir) != setup.get("arm_sha256"):
        problems.append("%s/%s: the export changed after prepare" % (task_id, arm))
    return problems


__all__ = ["OLIVIUM_AI", "OLIVIUM_DET", "V4_ARMS", "build", "check_ready", "ensure_snapshot", "exported_settings",
           "learn_run_id", "prepare", "read_bundle"]
