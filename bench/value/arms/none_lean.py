"""The none-lean arm (protocol 2, for information): the none arm plus only the lean trim.

Same prompt, flags, permission mode and benchmark settings as none; no CLAUDE.md, no
hooks, no other file in the repository. The settings passed with --settings are
arms/benchmark-settings.json plus exactly two things, both read from this task's
olivium export in the same OUT, so the trim is the one the olivium arm runs with:

  includeGitInstructions   the exported value (false in the lean profile)
  permissions.deny         the bare tool names the lean profile denies
                           (.olivium/spec.json spec.context.deny_tools), as they
                           appear in the exported .claude/settings.json

Nothing else from the export is carried over: no allow or ask rules, no Bash or
path deny patterns, no hooks, no permission mode. An export that is not lean, or
whose settings disagree with its spec, is refused; nothing falls back to another trim.

v4 (contract-v4.md, protocol 2 only): when OUT also holds an ok olivium-ai setup, the
trim is read the same way from that `lean-ai` export (its trim keys are those of
`lean`). With both exports present, both are read and must give the same trim, or the
arm is refused. With only the olivium export, everything above is unchanged, byte for
byte.
"""

import json
import os

from lib.common import ARMS_DIR, NONE_LEAN, OLIVIUM_AI, BenchError, read_json, sha256_bytes, sha256_file, tree_digest

# Exports a trim may come from, in the order the facts name them. lean-ai only from olivium-ai.
TRIM_SOURCES = ("olivium", OLIVIUM_AI)
SOURCE_PROFILES = {"olivium": ("lean",), OLIVIUM_AI: ("lean-ai",)}


def _olivium_files(ctx, task_id, arm="olivium"):
    arm_dir = ctx.arm_dir(task_id, arm)
    return arm_dir, os.path.join(arm_dir, ".claude", "settings.json"), os.path.join(arm_dir, ".olivium", "spec.json")


def _setup_ok(ctx, task_id, arm):
    path = ctx.setup_path(task_id, arm)
    return os.path.exists(path) and read_json(path).get("status") == "ok"


def trim_sources(ctx, task_id):
    """The exports this task's trim is read from: olivium alone as before, olivium-ai when prepared."""
    sources = ["olivium"] if _setup_ok(ctx, task_id, "olivium") else []
    if _setup_ok(ctx, task_id, OLIVIUM_AI):
        sources.append(OLIVIUM_AI)
    return sources


def lean_trim(settings, spec, profiles=("lean",)):
    """(includeGitInstructions value, deny entries in export order) from an exported lean harness."""
    context = (spec.get("spec") or {}).get("context") if isinstance(spec, dict) else None
    if not isinstance(context, dict) or context.get("profile") not in profiles:
        raise BenchError("the olivium export is not the lean context profile (spec.context.profile=%r)"
                         % (context or {}).get("profile"))
    deny_tools = context.get("deny_tools")
    if not isinstance(deny_tools, list) or not deny_tools or not all(isinstance(name, str) and name for name in deny_tools):
        raise BenchError("spec.context.deny_tools is missing or not a list of tool names")
    if any("(" in name or ")" in name for name in deny_tools):
        raise BenchError("spec.context.deny_tools holds a pattern, not a bare tool name")
    if context.get("auto_memory") is False or "autoMemoryEnabled" in settings:
        # The arm is defined as includeGitInstructions plus the denied tools; a third key would change it.
        raise BenchError("the lean export also sets auto memory; none-lean carries only includeGitInstructions and deny")
    if "includeGitInstructions" not in settings or not isinstance(settings["includeGitInstructions"], bool):
        raise BenchError("the exported settings have no boolean includeGitInstructions")
    if settings["includeGitInstructions"] != context.get("include_git_instructions"):
        raise BenchError("exported includeGitInstructions disagrees with spec.context.include_git_instructions")
    deny = ((settings.get("permissions") or {}).get("deny")) or []
    wanted = set(deny_tools)
    entries = [entry for entry in deny if entry in wanted]
    if sorted(set(entries)) != sorted(wanted) or len(entries) != len(set(entries)):
        raise BenchError("exported permissions.deny does not carry each spec.context.deny_tools name exactly once "
                         "(missing: %s)" % ", ".join(sorted(wanted - set(entries))))
    return settings["includeGitInstructions"], entries


def settings_for(base_bytes, include_git_instructions, deny):
    """The none settings with only the trim added. Deterministic bytes."""
    settings = json.loads(base_bytes.decode("utf-8"))
    permissions = settings.get("permissions")
    if not isinstance(permissions, dict) or "deny" in permissions or "includeGitInstructions" in settings:
        raise BenchError("benchmark-settings.json changed shape; the none-lean arm needs review")
    permissions["deny"] = list(deny)
    settings["includeGitInstructions"] = include_git_instructions
    return (json.dumps(settings, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def settings_path(ctx, task_id):
    return os.path.join(ctx.out, "arms", task_id, "%s.settings.json" % NONE_LEAN)


def _source_trim(ctx, task_id, arm):
    arm_dir, exported_settings, exported_spec = _olivium_files(ctx, task_id, arm)
    for path in (exported_settings, exported_spec):
        if not os.path.isfile(path):
            raise BenchError("none-lean needs the prepared %s export of %s; missing %s" % (arm, task_id, path))
    include_git, deny = lean_trim(read_json(exported_settings), read_json(exported_spec), SOURCE_PROFILES[arm])
    return include_git, deny, arm_dir, exported_settings, exported_spec


def derive(ctx, task_id):
    """Recompute the arm's settings from the current olivium (and olivium-ai) export. Returns (bytes, facts)."""
    sources = trim_sources(ctx, task_id) or ["olivium"]
    trims = {arm: _source_trim(ctx, task_id, arm) for arm in sources}
    first = trims[sources[0]]
    for arm in sources[1:]:
        if trims[arm][:2] != first[:2]:
            raise BenchError("the %s and %s exports of %s disagree on the lean trim; none-lean takes no side"
                             % (sources[0], arm, task_id))
    include_git, deny, arm_dir, exported_settings, exported_spec = first
    base = ctx.settings_bytes()
    data = settings_for(base, include_git, deny)
    facts = {
        "trim": {"includeGitInstructions": include_git, "permissions.deny": deny},
        "trim_source": {
            "olivium_settings_sha256": sha256_file(exported_settings),
            "olivium_spec_sha256": sha256_file(exported_spec),
            "olivium_arm_sha256": tree_digest(arm_dir),
        },
        "base_settings": os.path.relpath(os.path.join(ARMS_DIR, "benchmark-settings.json"), os.path.dirname(ARMS_DIR)),
        "base_settings_sha256": sha256_bytes(base),
    }
    if sources != ["olivium"]:
        # v4: name every export the trim was read from (the olivium-only facts stay as they were).
        if sources == [OLIVIUM_AI]:
            facts["trim_source"] = {}
        _ai_dir, ai_settings, ai_spec = trims[OLIVIUM_AI][2:]
        facts["trim_source"].update({
            "olivium_ai_settings_sha256": sha256_file(ai_settings),
            "olivium_ai_spec_sha256": sha256_file(ai_spec),
            "olivium_ai_arm_sha256": tree_digest(_ai_dir),
        })
        facts["trim_sources"] = list(sources)
    return data, facts


def build(ctx, task):
    """Write OUT/arms/<task>/none-lean.settings.json and return the setup record. No model call."""
    task_id = task["task_id"]
    olivium_setup_path = ctx.setup_path(task_id, "olivium")
    olivium_setup = read_json(olivium_setup_path) if os.path.exists(olivium_setup_path) else {}
    if olivium_setup.get("status") != "ok" and not _setup_ok(ctx, task_id, OLIVIUM_AI):
        raise BenchError("none-lean needs an ok olivium setup for %s (status %r)" % (task_id, olivium_setup.get("status")))
    data, facts = derive(ctx, task_id)
    path = settings_path(ctx, task_id)
    tmp = path + ".tmp"
    with open(tmp, "wb") as handle:
        handle.write(data)
    os.replace(tmp, path)
    return dict(
        facts,
        status="ok",
        arm=NONE_LEAN,
        task_id=task_id,
        mode="paid" if ctx.paid else "rehearsal",
        rehearsal_fixture=False,
        setup_model_calls=0,
        cost_usd=0.0,
        cost_upper_bound_usd=0.0,
        tokens={"input": 0, "output": 0, "cache_creation": 0, "cache_read": 0},
        harness_files=[],
        harness_bytes=0,
        settings_file=os.path.basename(path),
        settings_sha256=sha256_bytes(data),
        olivium_digest=olivium_setup.get("digest"),
        olivium_exported_settings_sha256=olivium_setup.get("exported_settings_sha256"),
    )


def check_ready(ctx, task_id):
    """Problems that make a scored none-lean trial unsafe to start; empty when ready."""
    path = settings_path(ctx, task_id)
    setup_path = ctx.setup_path(task_id, NONE_LEAN)
    if not os.path.isfile(path) or not os.path.isfile(setup_path):
        return ["%s/%s settings (run prepare)" % (task_id, NONE_LEAN)]
    with open(path, "rb") as handle:
        stored = handle.read()
    try:
        current, _facts = derive(ctx, task_id)
    except BenchError as exc:
        return ["%s/%s: %s" % (task_id, NONE_LEAN, exc)]
    problems = []
    if stored != current:
        problems.append("%s/%s settings no longer match the olivium export's trim (run prepare again)" % (task_id, NONE_LEAN))
    if read_json(setup_path).get("settings_sha256") != sha256_bytes(stored):
        problems.append("%s/%s settings changed after prepare" % (task_id, NONE_LEAN))
    return problems


def settings_bytes(ctx, task_id):
    with open(settings_path(ctx, task_id), "rb") as handle:
        return handle.read()


__all__ = ["build", "check_ready", "derive", "lean_trim", "settings_bytes", "settings_for"]
