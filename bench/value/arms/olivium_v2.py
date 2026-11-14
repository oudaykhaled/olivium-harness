"""The olivium arm of protocol v2: the new generator, through its real CLI.

For each task, a fresh repository is built from the bare clone holding only base_sha
and its ancestors, instruction files are removed as in arms/entry.sh, and
`bin/harnessforge generate` runs from a frozen snapshot of this application with a
fresh workspace. No model is called. The exported files are installed unmodified.

The repository is only parsed: git and the generator's own static analysis run on the
host, nothing from the repository is executed. See PROTOCOL-v2.md, Generator input.
"""

import json
import os
import re
import shutil
import subprocess

from lib.common import (
    REPO_ROOT,
    BenchError,
    read_json,
    sha256_file,
    tree_bytes,
    tree_digest,
    tree_files,
    write_json_atomic,
)
from arms import olivium as olivium_v1

SNAPSHOT_ITEMS = ("lib", "config", "priv", "bin/harnessforge", "mix.exs", "mix.lock", "deps", "_build/dev")
GIT = ["git", "-c", "core.hooksPath=/dev/null", "-c", "protocol.file.allow=always"]
# Same name rule as arms/entry.sh.
INSTRUCTION_NAMES = {"CLAUDE.md", "AGENTS.md", "copilot-instructions.md", ".claude", ".cursor"}
SKIPPED_DIRS = {".git", "node_modules"}
GENERATE_TIMEOUT_S = 900
SHA_PREFIX_LENGTH = 12


def _git(repo, *args, timeout=600, check=True):
    done = subprocess.run(GIT + ["-C", repo] + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, check=False)
    if check and done.returncode != 0:
        raise BenchError("git %s failed in %s: %s" % (args[0], repo, done.stderr.decode("utf-8", "replace")[:400]))
    return done.stdout.decode("utf-8", "replace").strip()


def generator_snapshot_digests():
    return {
        "lib_sha256": tree_digest(os.path.join(REPO_ROOT, "lib")),
        "config_sha256": tree_digest(os.path.join(REPO_ROOT, "config")),
        "priv_blueprints_sha256": tree_digest(os.path.join(REPO_ROOT, "priv", "blueprints")),
        "bin_harnessforge_sha256": sha256_file(os.path.join(REPO_ROOT, "bin", "harnessforge")),
        "mix_lock_sha256": sha256_file(os.path.join(REPO_ROOT, "mix.lock")),
    }


def ensure_generator_snapshot(out_dir):
    """A snapshot of the application under OUT, re-taken when the source changes."""
    snapshot = os.path.join(out_dir, "app-snapshot-v2")
    marker = os.path.join(snapshot, ".complete")
    record_path = os.path.join(out_dir, "app-snapshot-v2.json")
    current = generator_snapshot_digests()
    if os.path.exists(marker) and os.path.exists(record_path):
        recorded = read_json(record_path)
        if all(recorded.get(key) == value for key, value in current.items()):
            return snapshot
        print("generator snapshot is stale (application source changed); re-taking it", flush=True)
    shutil.rmtree(snapshot, ignore_errors=True)
    os.makedirs(snapshot)
    for item in SNAPSHOT_ITEMS:
        source = os.path.join(REPO_ROOT, item)
        target = os.path.join(snapshot, item)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        if os.path.isdir(source):
            shutil.copytree(source, target, symlinks=True, ignore=olivium_v1.SNAPSHOT_IGNORE)
        elif os.path.isfile(source):
            shutil.copy2(source, target)
    write_json_atomic(record_path, dict(current, note="Snapshot of the application used by the generator. See PROTOCOL-v2.md."))
    with open(marker, "w", encoding="utf-8") as handle:
        handle.write("ok\n")
    return snapshot


def build_truncated_repo(bare_clone, base_sha, destination):
    """A repository containing only base_sha and its ancestors, on branch main, without a remote."""
    if not os.path.isdir(bare_clone):
        raise BenchError("bare clone not found for the generator: %s" % bare_clone)
    done = subprocess.run(
        GIT + ["clone", "--quiet", "--no-hardlinks", "--no-tags", bare_clone, destination],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=1800, check=False,
    )
    if done.returncode != 0:
        raise BenchError("local clone failed: %s" % done.stderr.decode("utf-8", "replace")[:400])
    _git(destination, "checkout", "--quiet", "-B", "main", base_sha)
    if _git(destination, "rev-parse", "HEAD") != base_sha:
        raise BenchError("checked-out HEAD is not base_sha in %s" % destination)
    _git(destination, "remote", "remove", "origin", check=False)
    for ref in _git(destination, "for-each-ref", "--format=%(refname)").splitlines():
        if ref != "refs/heads/main":
            _git(destination, "update-ref", "-d", ref)
    _git(destination, "reflog", "expire", "--expire=now", "--all")
    _git(destination, "gc", "--quiet", "--prune=now", timeout=1800)
    # Reachability is what matters to `git log`, but also drop the objects other refs held.
    for name in ("FETCH_HEAD", "ORIG_HEAD"):
        path = os.path.join(destination, ".git", name)
        if os.path.exists(path):
            os.unlink(path)


def remove_instruction_files(repo):
    """Same name rule as arms/entry.sh, at any depth. Returns removed paths, sorted."""
    removed = []
    for directory, subdirs, names in os.walk(repo, followlinks=False):
        rel_dir = os.path.relpath(directory, repo)
        kept = []
        for name in subdirs:
            if name in SKIPPED_DIRS:
                continue
            if name in INSTRUCTION_NAMES:
                removed.append(os.path.normpath(os.path.join(rel_dir, name)))
                shutil.rmtree(os.path.join(directory, name), ignore_errors=True)
                continue
            kept.append(name)
        subdirs[:] = kept
        for name in names:
            if name in INSTRUCTION_NAMES:
                removed.append(os.path.normpath(os.path.join(rel_dir, name)))
                os.unlink(os.path.join(directory, name))
    removed = sorted(removed)
    if removed:
        # No commit: HEAD stays base_sha, and the deleted paths leave the index
        # because the analyzer lists files with `git ls-files --cached`.
        _git(repo, "rm", "-r", "-q", "--cached", "--ignore-unmatch", "--", *removed)
    return removed


def forbidden_commits(bare_clone, base_sha, fix_sha):
    """Every commit reachable from fix_sha but not from base_sha: the fix and the pull request."""
    listing = _git(bare_clone, "rev-list", "%s..%s" % (base_sha, fix_sha))
    return sorted({line.strip() for line in listing.splitlines() if line.strip()} | {fix_sha})


def assert_no_post_base(task, repo, export_dir, bare_clone):
    """The arm's input and output contain nothing from the fix commit or later."""
    base_sha = task["base_sha"]
    fix_sha = task["fix_sha"]
    failures = []
    head = _git(repo, "rev-parse", "HEAD")
    if head != base_sha:
        failures.append("head_is_not_base")
    refs = _git(repo, "for-each-ref", "--format=%(refname)").splitlines()
    if refs != ["refs/heads/main"]:
        failures.append("unexpected_refs:%s" % ",".join(refs))
    if _git(repo, "remote"):
        failures.append("remote_present")
    if _git(repo, "tag", "-l"):
        failures.append("tags_present")
    forbidden = forbidden_commits(bare_clone, base_sha, fix_sha)
    present = []
    for sha in forbidden:
        done = subprocess.run(GIT + ["-C", repo, "cat-file", "-e", sha + "^{commit}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        if done.returncode == 0:
            present.append(sha)
    if present:
        failures.append("post_base_commit_present:%s" % ",".join(sha[:12] for sha in present))
    truncated_log = _git(repo, "rev-list", "HEAD").split()
    bare_log = _git(bare_clone, "rev-list", base_sha).split()
    if set(truncated_log) != set(bare_log):
        failures.append("history_mismatch:truncated=%d,bare_at_base=%d" % (len(truncated_log), len(bare_log)))
    pr_number = int(task["pr_url"].rstrip("/").rsplit("/", 1)[1])
    patterns = [re.compile(r"(?<![\w-])#%d\b" % pr_number)]
    needles = []
    for sha in forbidden:
        needles.append(sha)
        needles.append(sha[:SHA_PREFIX_LENGTH])
    leaks = []
    for rel in tree_files(export_dir):
        with open(os.path.join(export_dir, rel), "rb") as handle:
            text = handle.read().decode("utf-8", "replace")
        for needle in needles:
            if needle in text:
                leaks.append("%s contains %s" % (rel, needle[:12]))
                break
        for pattern in patterns:
            if pattern.search(text):
                leaks.append("%s mentions #%d" % (rel, pr_number))
                break
    if leaks:
        failures.append("post_base_text_in_export:%s" % "; ".join(leaks[:5]))
    return {
        "head": head,
        "commits_in_truncated_history": len(truncated_log),
        "commits_at_base_in_bare_clone": len(bare_log),
        "forbidden_commits_checked": len(forbidden),
        "exported_files_scanned": len(tree_files(export_dir)),
        "failures": failures,
    }


def _generator_env(workspace):
    env = {
        "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
        "HOME": os.environ.get("HOME", ""),
        "LANG": os.environ.get("LANG", "en_US.UTF-8"),
        "MIX_ENV": "dev",
        "HARNESSFORGE_WORKSPACE": workspace,
    }
    # Mix keeps its lock and pubsub files under TMPDIR; without it they land in the system /tmp.
    if os.environ.get("TMPDIR"):
        env["TMPDIR"] = os.environ["TMPDIR"]
    return env


def _parse_generator_output(stdout):
    """The CLI prints one JSON object; tooling noise can precede it, so take the last line that parses."""
    for line in reversed(stdout.decode("utf-8", "replace").splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                return json.loads(line)
            except ValueError:
                continue
    return None


def build(ctx, task, material_dir, arm="olivium", extra_args=()):
    """Build an exported arm. arm and extra_args default to the olivium arm of PROTOCOL-v2.md.

    PROTOCOL-v2r.md adds olivium-nn: arm="olivium-nn", extra_args=("--native", "none"), the same
    snapshot, input and checks, installed under its own arm directory.
    """
    task_id = task["task_id"]
    bare_clone = os.path.join(ctx.clones_dir, task["repo"].replace("/", "__") + ".git")
    work = os.path.join(ctx.out, "olivium-work" if arm == "olivium" else "%s-work" % arm, task_id)
    shutil.rmtree(work, ignore_errors=True)
    # Directory named as a clone would be: the generator derives the project's name from it.
    repo = os.path.join(work, task["repo"].split("/", 1)[1])
    workspace = os.path.join(work, "workspace")
    export_dir = os.path.join(work, "export")
    os.makedirs(workspace)
    build_truncated_repo(bare_clone, task["base_sha"], repo)
    removed = remove_instruction_files(repo)
    snapshot = ensure_generator_snapshot(ctx.out)
    stdout_path = os.path.join(work, "generate.stdout.log")
    stderr_path = os.path.join(work, "generate.stderr.log")
    with open(stdout_path, "wb") as out, open(stderr_path, "wb") as err:
        done = subprocess.run(
            [os.path.join(snapshot, "bin", "harnessforge"), "generate", os.path.realpath(repo),
             "--runtime", "claude_code", "--export", os.path.realpath(export_dir), "--json"] + list(extra_args),
            cwd=snapshot, env=_generator_env(workspace), stdout=out, stderr=err, timeout=GENERATE_TIMEOUT_S,
        )
    # The workspace holds a per-workspace secret; nothing here reads, logs or keeps it.
    token = os.path.join(workspace, "access-token")
    if os.path.exists(token):
        os.unlink(token)
    with open(stdout_path, "rb") as handle:
        report = _parse_generator_output(handle.read())
    if done.returncode != 0 or report is None or not report.get("ok"):
        message = (report or {}).get("error") if isinstance(report, dict) else None
        raise BenchError("generator failed for %s (exit %d, %s); see %s" % (task_id, done.returncode, message, stderr_path))
    if not os.path.isdir(export_dir):
        raise BenchError("generator produced no export directory for %s" % task_id)
    # The generator wrote only its export directory; anything else would be a bug to stop on.
    check = assert_no_post_base(task, repo, export_dir, bare_clone)
    if check["failures"]:
        raise BenchError("post-base check failed for %s: %s" % (task_id, "; ".join(check["failures"])))
    arm_dir = ctx.arm_dir(task_id, arm)
    shutil.rmtree(arm_dir, ignore_errors=True)
    shutil.copytree(export_dir, arm_dir, symlinks=False)
    exported_settings = os.path.join(arm_dir, ".claude", "settings.json")
    if not os.path.isfile(exported_settings):
        raise BenchError("the export has no .claude/settings.json for %s" % task_id)
    if not os.path.isfile(os.path.join(arm_dir, "CLAUDE.md")):
        raise BenchError("the export has no CLAUDE.md for %s" % task_id)
    with open(os.path.join(work, "generate.report.json"), "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, sort_keys=True)
    result = report["result"]
    extra = {}
    if arm != "olivium":
        # PROTOCOL-v2r.md: the arm's generator flags and what the export holds of the native
        # skills and subagents. The olivium arm's record is unchanged.
        extra = {"generator_extra_args": list(extra_args), "native": result.get("native"),
                 "context": result.get("context")}
    return {
        **extra,
        "status": "ok",
        "arm": arm,
        "task_id": task_id,
        "mode": "paid" if ctx.paid else "rehearsal",
        "rehearsal_fixture": False,
        "generator": " ".join(["bin/harnessforge generate --runtime claude_code --json"] + list(extra_args)),
        "setup_model_calls": 0,
        "cost_usd": 0.0,
        "cost_upper_bound_usd": 0.0,
        "tokens": {"input": 0, "output": 0, "cache_creation": 0, "cache_read": 0},
        "digest": result.get("digest"),
        "profile_digest": result.get("profile_digest"),
        "blueprint_version": result.get("blueprint_version"),
        "counts": result.get("counts"),
        "diagnostics": result.get("diagnostics"),
        "skipped_commands": result.get("skipped_commands"),
        "removed_instruction_files": removed,
        "post_base_check": check,
        "harness_files": tree_files(arm_dir),
        "harness_bytes": tree_bytes(arm_dir),
        "arm_sha256": tree_digest(arm_dir),
        "exported_settings_sha256": sha256_file(exported_settings),
    }


__all__ = ["build", "ensure_generator_snapshot"]
