"""The olivium arm: the real pipeline, on the host, one fresh workspace per task.

Repository Markdown is imported as data. The launcher is mix, run from a frozen
snapshot of this repository under OUT so the pipeline stays identical across
tasks while the working tree changes, and so no compilation touches _build in
the working tree. The app's Anthropic provider accepts only the exact endpoint
https://api.anthropic.com/v1, so it cannot be pointed at the meter; in dry-run
the proposal step is a marked fixture and the real proposal path is untested.
"""

import os
import re
import shutil
import subprocess

from lib.common import (
    ARMS_DIR,
    CLAUDE_CODE_VERSION,
    INSTRUCTION_PATHS,
    MODEL,
    REPO_ROOT,
    BenchError,
    SetupFailed,
    read_json,
    read_jsonl,
    sonnet_cost_usd,
    tree_bytes,
    tree_digest,
    tree_files,
    write_json_atomic,
)

# Deterministic proposal rule (recorded in PROTOCOL.md change log).
PROPOSE_MAX_FILES = 5
PROPOSE_MAX_FILE_BYTES = 32768
PROPOSE_MAX_TOTAL_BYTES = 40000
PROPOSE_MAX_OUTPUT_TOKENS = 4096
PROPOSAL_TASK_LIMIT_USD = 1.0
SNAPSHOT_ITEMS = ("lib", "config", "priv", "mix.exs", "mix.lock", "deps", "_build/dev")
SNAPSHOT_IGNORE = shutil.ignore_patterns(".elixir_ls", "*.dump", "node_modules")
CREDENTIAL_ENV = "HARNESSFORGE_BENCH_ANTHROPIC_API_KEY"
_EXCLUDED_BASENAME = re.compile(
    r"^(change|history|news|release|code.of.conduct|security|license|support|funding)", re.I
)


def markdown_files(repo_dir):
    """Markdown files of the snapshot, minus removed instruction files."""
    selected = []
    for rel in tree_files(repo_dir):
        if os.path.splitext(rel)[1].lower() not in (".md", ".markdown"):
            continue
        parts = rel.split("/")
        if parts[-1] in ("CLAUDE.md", "AGENTS.md") or any(part in (".claude", ".cursor") for part in parts):
            continue
        if any(rel == item or rel.startswith(item + "/") for item in INSTRUCTION_PATHS):
            continue
        if ".." in parts:
            continue
        selected.append(rel)
    return selected


def proposal_candidate(rel):
    lower = rel.lower()
    base = os.path.basename(lower)
    if lower.startswith(".github/issue_template/") or "pull_request_template" in base:
        return False
    if "changelog.d" in lower.split("/"):
        return False
    return not _EXCLUDED_BASENAME.match(base)


def proposal_tier(rel):
    base = os.path.basename(rel.lower())
    if "/" not in rel and base.startswith("readme"):
        return 0
    if base.startswith(("contributing", "development", "developing", "hacking", "maintaining")):
        return 1
    if rel.lower().startswith(("docs/", "doc/")):
        return 2
    return 3


def select_proposals(docs_dir, rels):
    """Rule: rank by tier, depth, then path; greedily keep files within limits."""
    ranked = sorted(
        [rel for rel in rels if proposal_candidate(rel)],
        key=lambda rel: (proposal_tier(rel), rel.count("/"), rel.lower(), rel),
    )
    chosen = []
    total = 0
    for rel in ranked:
        size = os.path.getsize(os.path.join(docs_dir, rel))
        if size == 0 or size > PROPOSE_MAX_FILE_BYTES:
            continue
        if total + size > PROPOSE_MAX_TOTAL_BYTES:
            continue
        chosen.append(rel)
        total += size
        if len(chosen) == PROPOSE_MAX_FILES:
            break
    return chosen


def _snapshot_digests():
    return {
        "lib_sha256": tree_digest(os.path.join(REPO_ROOT, "lib")),
        "config_sha256": tree_digest(os.path.join(REPO_ROOT, "config")),
        "mix_lock_sha256": _file_digest(os.path.join(REPO_ROOT, "mix.lock")),
    }


def ensure_snapshot(out_dir):
    """Snapshot of the pipeline under OUT, re-taken when lib/, config/ or mix.lock changed.

    Before, a snapshot was reused as long as it existed, so a fix to the pipeline
    between a failed prepare and --retry-failed would have run the old code.
    """
    snap = os.path.join(out_dir, "app-snapshot")
    marker = os.path.join(snap, ".complete")
    record_path = os.path.join(out_dir, "app-snapshot.json")
    current = _snapshot_digests()
    if os.path.exists(marker) and os.path.exists(record_path):
        recorded = read_json(record_path)
        if all(recorded.get(key) == value for key, value in current.items()):
            return snap
        print("app snapshot is stale (pipeline source changed); re-taking it", flush=True)
    shutil.rmtree(snap, ignore_errors=True)
    os.makedirs(snap)
    for item in SNAPSHOT_ITEMS:
        source = os.path.join(REPO_ROOT, item)
        target = os.path.join(snap, item)
        if os.path.isdir(source):
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copytree(source, target, symlinks=True, ignore=SNAPSHOT_IGNORE)
        elif os.path.isfile(source):
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copy2(source, target)
    write_json_atomic(
        record_path,
        dict(
            current,
            snapshot_lib_sha256=tree_digest(os.path.join(snap, "lib")),
            note="Snapshot of this repository's pipeline, taken at prepare and re-taken when lib/, config/ or mix.lock change.",
        ),
    )
    with open(marker, "w", encoding="utf-8") as handle:
        handle.write("ok\n")
    return snap


def _file_digest(path):
    import hashlib

    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def copy_markdown(repo_dir, docs_dir, rels):
    for rel in rels:
        target = os.path.join(docs_dir, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copyfile(os.path.join(repo_dir, rel), target)


def _budget(docs_dir, proposals):
    """Ledger limits for one task, above the provider's reservation bound."""
    per_request_overhead = 3000 + 1024 + PROPOSE_MAX_OUTPUT_TOKENS
    tokens = sum(os.path.getsize(os.path.join(docs_dir, rel)) for rel in proposals) * 2
    tokens += per_request_overhead * len(proposals) * 2
    return {
        "max_requests": max(1, len(proposals)),
        "max_tokens": max(50000, tokens),
        "max_estimated_microusd": int(PROPOSAL_TASK_LIMIT_USD * 1_000_000),
    }


def _usage_fields(usage_rows):
    """Tokens and dollars of the proposal calls; unknown usage counts at its full reservation."""
    input_tokens = sum(int(item.get("input_tokens") or 0) for item in usage_rows)
    output_tokens = sum(int(item.get("output_tokens") or 0) for item in usage_rows)
    cost = sonnet_cost_usd(input_tokens, output_tokens)
    unknown = [item for item in usage_rows if item.get("usage_status") != "reported"]
    return {
        "usage_requests": usage_rows,
        "tokens": {"input": input_tokens, "output": output_tokens, "cache_creation": 0, "cache_read": 0},
        "cost_usd": cost,
        "cost_upper_bound_usd": cost
        + sum((item.get("reserved_estimated_microusd") or 0) / 1e6 for item in unknown),
    }


def _unknown_usage_fields(mode):
    """The pipeline died before reporting usage: assume the whole task limit was spent."""
    bound = PROPOSAL_TASK_LIMIT_USD if mode == "paid" else 0.0
    return {"usage_requests": [], "tokens": {"input": 0, "output": 0, "cache_creation": 0, "cache_read": 0},
            "cost_usd": 0.0, "cost_upper_bound_usd": bound}


def _app_env(workspace, key_value):
    env = {
        "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
        "HOME": os.environ.get("HOME", ""),
        "LANG": os.environ.get("LANG", "en_US.UTF-8"),
        "MIX_ENV": "dev",
        "HARNESSFORGE_WORKSPACE": workspace,
    }
    if key_value is not None:
        env[CREDENTIAL_ENV] = key_value
    return env


def build(ctx, task, material_dir):
    """Run the real pipeline for a task and collect the exported arm files."""
    task_id = task["task_id"]
    repo_dir = os.path.join(material_dir, "repo")
    work = os.path.join(ctx.out, "olivium-work", task_id)
    shutil.rmtree(work, ignore_errors=True)
    docs_dir = os.path.join(work, "docs")
    workspace = os.path.join(work, "workspace")
    export_dir = os.path.join(work, "export")
    os.makedirs(docs_dir)
    os.makedirs(workspace)

    rels = markdown_files(repo_dir)
    copy_markdown(repo_dir, docs_dir, rels)
    proposals = select_proposals(docs_dir, rels)
    if not proposals:
        raise BenchError("no Markdown files eligible for proposal in %s" % task_id)

    mode = "paid" if ctx.paid else "rehearsal"
    run_id = "bench-%s" % task_id
    config = {
        "mode": mode,
        "name": "bench-%s" % task_id,
        "task_id": task_id,
        "docs_dir": docs_dir,
        "export_dir": export_dir,
        "result_path": os.path.join(work, "result.json"),
        "propose": proposals,
        "model": MODEL,
        "input_microusd_per_million": 2_000_000,
        "output_microusd_per_million": 10_000_000,
        "budget": _budget(docs_dir, proposals),
        "ledger_run_id": run_id,
        "max_output_tokens": PROPOSE_MAX_OUTPUT_TOKENS,
        "runtime_version": CLAUDE_CODE_VERSION,
    }
    config_path = os.path.join(work, "config.json")
    write_json_atomic(config_path, config)

    snapshot = ensure_snapshot(ctx.out)
    key_value = None
    if ctx.paid:
        with open(ctx.key_file, "r", encoding="utf-8") as handle:
            key_value = handle.read().strip()
    log_path = os.path.join(work, "pipeline.log")
    script = os.path.join(ARMS_DIR, "pipeline.exs")
    with open(log_path, "wb") as log:
        done = subprocess.run(
            ["mix", "run", script, config_path],
            cwd=snapshot,
            env=_app_env(workspace, key_value),
            stdout=log,
            stderr=subprocess.STDOUT,
            timeout=1800,
        )
    # The app created this per-workspace secret; nothing here reads or keeps it.
    token_path = os.path.join(workspace, "access-token")
    if os.path.exists(token_path):
        os.unlink(token_path)
    if done.returncode != 0 or not os.path.exists(config["result_path"]):
        raise SetupFailed(
            "pipeline exited %d for %s; see %s" % (done.returncode, task_id, log_path),
            _unknown_usage_fields(mode),
        )
    report = read_json(config["result_path"])
    usage_rows = report.get("usage") or []
    usage = _usage_fields(usage_rows)
    if report.get("status") != "ok":
        raise SetupFailed(
            "pipeline failed at %s for %s: %s" % (report.get("stage"), task_id, report.get("error")), usage
        )
    if report.get("approved", 0) < 1:
        raise SetupFailed("no approved claims for %s" % task_id, usage)

    arm_dir = ctx.arm_dir(task_id, "olivium")
    exported = ctx.exported_dir(task_id)
    for path in (arm_dir, exported):
        shutil.rmtree(path, ignore_errors=True)
    os.makedirs(arm_dir)
    os.makedirs(exported)
    shutil.copy2(os.path.join(export_dir, "CLAUDE.md"), os.path.join(arm_dir, "CLAUDE.md"))
    for subdir in ("agents", "skills"):
        source = os.path.join(export_dir, ".claude", subdir)
        if os.path.isdir(source):
            shutil.copytree(source, os.path.join(arm_dir, ".claude", subdir), symlinks=False)
    settings = os.path.join(export_dir, ".claude", "settings.json")
    if os.path.isfile(settings):
        os.makedirs(os.path.join(exported, ".claude"))
        shutil.copy2(settings, os.path.join(exported, ".claude", "settings.json"))

    setup = {
        "status": "ok",
        "arm": "olivium",
        "task_id": task_id,
        "mode": mode,
        "rehearsal_fixture": mode != "paid",
        "digest": report.get("digest"),
        "markdown_files_imported": len(rels),
        "manifest_markdown_files_count": task.get("markdown_files_count"),
        "proposed_files": proposals,
        "proposals": report.get("proposals"),
        "claims_total": report.get("claims_total"),
        "claims_approved": report.get("approved"),
        "decide_errors": report.get("decide_errors"),
        "model_status": report.get("model_status"),
        **usage,
        "usage_source": "application ledger (not the meter; the provider rejects any endpoint except api.anthropic.com)",
        "harness_files": tree_files(arm_dir),
        "harness_bytes": tree_bytes(arm_dir),
        "arm_sha256": tree_digest(arm_dir),
    }
    return setup


__all__ = ["build", "read_jsonl"]
