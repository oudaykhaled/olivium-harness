"""Host side of patch extraction and grading.

Both steps run in fresh --network none containers. Host code only moves bytes
with docker cp and reads the results through allow-lists; nothing from a
container is executed or unpacked by path on the host.
"""

import os

from lib.common import GRADE_COMMAND_TIMEOUT_S, GRADE_DIR, GRADE_LIMITS, BenchError, load_parse_junit, tree_files
from lib import dockerops as dk

MAX_XML_BYTES = 64 * (1 << 20)
# Files outside the repository's history (build, cache) never appear in a patch
# because the extractor diffs against the pristine .git.

_parse_junit = None


def _junit(path):
    global _parse_junit
    if _parse_junit is None:
        _parse_junit = load_parse_junit()
    return _parse_junit(path)


def _read_text(path, default=""):
    if not os.path.exists(path):
        return default
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        return handle.read().strip()


def _read_list(path):
    if not os.path.exists(path):
        return []
    with open(path, "rb") as handle:
        data = handle.read()
    return [item.decode("utf-8", "replace") for item in data.split(b"\0") if item]


def extract_patch(ctx, task, agent_container, run_dir):
    """Diff the agent's working tree against the pristine repository, in Docker."""
    name = "olivium-bench-extract-%s-%s" % (ctx.tag, os.path.basename(run_dir)[-24:].replace(".", "-"))
    image = ctx.agent_image(task)
    dk.remove(name)
    dk.create(
        name, image, network="none", memory="512m", cpus="1", pids="256",
        command=["/bin/bash", "/work/extract.sh"],
    )
    try:
        with open(os.path.join(GRADE_DIR, "extract.sh"), "rb") as handle:
            script = handle.read()
        dk.cp_in(
            name, "/work",
            dk.make_tar([("extract.sh", script, 0o755), ("agent", None, 0o755)], uid=1001, gid=1001),
        )
        dk.cp_between(agent_container, "/work/repo", name, "/work/agent")
        dk.start(name)
        code = dk.wait(name, timeout=300)
        if code is None:
            raise dk.DockerError("patch extraction timed out")
        tar_path = os.path.join(run_dir, "extract.tar")
        dk.cp_out_file(name, "/work/extract-out", tar_path)
        written = dk.extract_members(
            tar_path,
            {"agent.patch": "agent.patch", "changed.z": "changed.z", "done": "extract.done",
             "add_status": "add_status", "diff_status": "diff_status", "diff.stderr": "diff.stderr"},
            run_dir,
            max_member_bytes=256 * (1 << 20),
        )
        os.unlink(tar_path)
        if "done" not in written or "agent.patch" not in written:
            raise dk.DockerError("patch extraction produced no result (exit %s)" % code)
        return os.path.join(run_dir, "agent.patch")
    finally:
        dk.remove(name)


def grade(ctx, task, patch_path, material_dir, run_dir, protect=True, test_timeout_s=None):
    """Grade a patch; returns the grade dict (status ok or infra_error).

    test_timeout_s: the test command's limit in grade.sh. None keeps grade.sh's 300 s
    and the outcome exactly as before (protocols 1 and 2). Protocol 3 passes
    GRADE_TEST_TIMEOUT_V3_S; its outcome then also says whether the test command was
    killed at the limit (grade_timeout) and how long it ran.
    """
    name = "olivium-bench-grade-%s-%s" % (ctx.tag, os.path.basename(run_dir)[-24:].replace(".", "-"))
    grade_out = run_dir
    os.makedirs(grade_out, exist_ok=True)
    with open(patch_path, "rb") as handle:
        agent_patch = handle.read()
    with open(os.path.join(material_dir, "test.patch"), "rb") as handle:
        test_patch = handle.read()
    with open(os.path.join(GRADE_DIR, "grade.sh"), "rb") as handle:
        script = handle.read()
    entries = [
        ("grade-in/grade.sh", script, 0o755),
        ("grade-in/agent.patch", agent_patch, 0o644),
        ("grade-in/test.patch", test_patch, 0o644),
        ("grade-in/test_files.z", b"\0".join(p.encode("utf-8") for p in task["test_files"]) + b"\0", 0o644),
        ("grade-in/test_command.txt", task["test_command"].encode("utf-8"), 0o644),
        ("grade-in/lint_command.txt", (task.get("lint_command") or "").encode("utf-8"), 0o644),
        ("grade-out", None, 0o755),
    ]
    if not protect:
        if ctx.paid:
            raise BenchError("protect=False is not available with --paid")
        entries.append(("grade-in/no_protect", b"control\n", 0o644))
    host_timeout = 900
    if test_timeout_s is not None:
        if not isinstance(test_timeout_s, int) or isinstance(test_timeout_s, bool) or test_timeout_s <= 0:
            raise BenchError("test_timeout_s must be a positive whole number of seconds")
        entries.append(("grade-in/test_timeout_seconds.txt", b"%d\n" % test_timeout_s, 0o644))
        # Lint (300 s), the tests, and room for patching and copying results.
        host_timeout = max(900, GRADE_COMMAND_TIMEOUT_S + test_timeout_s + 300)
    dk.remove(name)
    dk.create(
        name, task["deps_image"], network="none",
        memory=GRADE_LIMITS["memory"], cpus=GRADE_LIMITS["cpus"], pids=GRADE_LIMITS["pids"],
        harden=False, command=["/bin/bash", "/work/grade-in/grade.sh"],
    )
    try:
        dk.cp_in(name, "/work", dk.make_tar(entries), archive=False)
        dk.start(name)
        code = dk.wait(name, timeout=host_timeout)
        if code is None:
            dk.kill(name)
            return {"status": "infra_error", "error": "grade container exceeded the host limit"}
        tar_path = os.path.join(run_dir, "grade.tar")
        dk.cp_out_file(name, "/work/grade-out", tar_path)
        allowed = {base: base for base in (
            "done", "patch_applied", "test_patch_applied", "lint_exit", "test_exit",
            "test_wall_seconds", "test_timeout_seconds", "results.xml", "restored.z", "removed.z",
            "agent_apply.stderr", "test_apply.stderr", "lint.log", "test.log", "changed.z",
        )}
        # Avoid clobbering the extractor's changed.z.
        allowed["changed.z"] = "grade_changed.z"
        written = dk.extract_members(tar_path, allowed, grade_out, max_member_bytes=MAX_XML_BYTES)
        os.unlink(tar_path)
    finally:
        dk.remove(name)
    if "done" not in written:
        return {"status": "infra_error", "error": "grade script did not finish (exit %s)" % code}
    outcome = {
        "status": "ok",
        "patch_applied": _read_text(os.path.join(grade_out, "patch_applied")) == "true",
        "test_patch_applied": _read_text(os.path.join(grade_out, "test_patch_applied")) == "true",
        "test_exit": _read_text(os.path.join(grade_out, "test_exit")),
        "lint_exit": _read_text(os.path.join(grade_out, "lint_exit")),
        "restored_paths": _read_list(os.path.join(grade_out, "restored.z")),
        "removed_paths": _read_list(os.path.join(grade_out, "removed.z")),
        "protected": bool(protect),
    }
    if test_timeout_s is not None:
        wall = _read_text(os.path.join(grade_out, "test_wall_seconds"))
        outcome["test_timeout_seconds"] = test_timeout_s
        outcome["test_wall_seconds"] = int(wall) if wall.isdigit() else None
        # timeout --signal=KILL exits 137 when it kills the test command at the limit.
        outcome["grade_timeout"] = outcome["test_exit"] == "137"
    if not outcome["test_patch_applied"]:
        outcome["status"] = "infra_error"
        outcome["error"] = "test patch did not apply"
        return outcome
    f2p = task["f2p"]
    p2p = task["p2p"]
    results_path = os.path.join(grade_out, "results.xml")
    results = {}
    if "results.xml" in written:
        with open(results_path, "rb") as handle:
            content = handle.read()
        # Model-written code can write this file, so scan all of it, not the head.
        if b"<!DOCTYPE" in content or b"<!ENTITY" in content:
            outcome["results_error"] = "doctype_in_results"
        else:
            try:
                results = _junit(results_path)
            except Exception as exc:  # malformed XML from a run counts as no results
                outcome["results_error"] = type(exc).__name__
    else:
        outcome["results_error"] = "no_results_file"
    outcome["f2p_total"] = len(f2p)
    outcome["f2p_passed"] = sum(1 for test in f2p if results.get(test) == "pass")
    regressed = [test for test in p2p if results.get(test) in ("fail", None)]
    outcome["p2p_total"] = len(p2p)
    outcome["p2p_regressions"] = len(regressed)
    outcome["p2p_missing"] = sum(1 for test in p2p if results.get(test) is None)
    outcome["tests_seen"] = len(results)
    outcome["solved"] = bool(
        outcome["patch_applied"]
        and outcome["f2p_passed"] == outcome["f2p_total"]
        and outcome["f2p_total"] > 0
        and not regressed
    )
    lint_exit = outcome["lint_exit"]
    outcome["lint_ok"] = None if lint_exit == "none" else lint_exit == "0"
    return outcome


def repo_file_set(material_dir):
    return set(tree_files(os.path.join(material_dir, "repo")))
