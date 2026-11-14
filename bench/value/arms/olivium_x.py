"""The olivium-x arm (protocol 2 only, v5 development test; v5 contract.md, lane C, item 4).

olivium-x is none-lean plus two things from the task's `lean-x` export, and nothing else:

  settings (--settings)  the task's none-lean.settings.json, parsed, plus the export's
                         `hooks` (PreToolUse only: the guard, then the Bash output
                         shaper) and `outputStyle` ("olivium")
  repository files       exactly .claude/hooks/olivium-guard.sh,
                         .claude/hooks/olivium-shape.sh and .claude/output-styles/olivium.md
  permission mode        bypassPermissions, the same as none-lean

The export is made by `bin/harnessforge generate --context lean-x` from the v4 application
snapshot (arms/olivium_ai.ensure_snapshot), on a repository holding only the base commit and
its ancestors, as the v4 arms do. It is kept whole under arms/<task>/olivium-x.export (its
.olivium/ provenance included) and is never installed. No model is called in prepare.

Prepare refuses, never repairs:
  - an export whose settings keys are not exactly those of a lean export plus outputStyle;
  - an export whose trim (permissions.deny tool names, includeGitInstructions) differs from
    the none-lean settings of the same task in the same OUT;
  - hooks with any event other than PreToolUse, or a hook command that runs a file the arm
    does not install;
  - a style file over 495 bytes (the largest style measured) or an outputStyle other than
    "olivium".
The none-lean settings are read, never written: prepare builds olivium-x after none-lean.
"""

import json
import os
import shutil

from lib.common import (
    OLIVIUM_X,
    BenchError,
    read_json,
    sha256_bytes,
    sha256_file,
    tree_bytes,
    tree_digest,
    tree_files,
    write_json_atomic,
)
from arms import none_lean
from arms import olivium_ai
from arms import olivium_v2

PROFILE = "lean-x"
GUARD = ".claude/hooks/olivium-guard.sh"
SHAPER = ".claude/hooks/olivium-shape.sh"
STYLE = ".claude/output-styles/olivium.md"
INSTALLED = (GUARD, SHAPER, STYLE)
STYLE_NAME = "olivium"
STYLE_MAX_BYTES = 495
# The keys of a lean export's .claude/settings.json, plus outputStyle.
EXPORT_KEYS = ("$schema", "disableSkillShellExecution", "hooks", "includeGitInstructions", "outputStyle", "permissions")
# What olivium-x adds to the none-lean settings.
CARRIED = ("hooks", "outputStyle")
HOOK_EVENTS = ("PreToolUse",)
HOOK_FILES = (GUARD, SHAPER)
GENERATE_TIMEOUT_S = 900
ZERO_TOKENS = {"input": 0, "output": 0, "cache_creation": 0, "cache_read": 0}


def export_dir(ctx, task_id):
    """The whole lean-x export, kept for provenance; never installed."""
    return os.path.join(ctx.out, "arms", task_id, "%s.export" % OLIVIUM_X)


def settings_path(ctx, task_id):
    return os.path.join(ctx.out, "arms", task_id, "%s.settings.json" % OLIVIUM_X)


def _read_bytes(path):
    with open(path, "rb") as handle:
        return handle.read()


# ------------------------------------------------------------------ checks
def check_hooks(hooks):
    """PreToolUse entries only, each running one of the installed hook files; the shaper at least once."""
    if not isinstance(hooks, dict) or not hooks:
        raise BenchError("the lean-x export has no hooks object")
    others = sorted(event for event in hooks if event not in HOOK_EVENTS)
    if others:
        raise BenchError("the lean-x export has hooks for %s; olivium-x carries PreToolUse only" % ", ".join(others))
    entries = hooks.get("PreToolUse")
    if not isinstance(entries, list) or not entries:
        raise BenchError("the lean-x export has no PreToolUse hook entries")
    used = set()
    for entry in entries:
        commands = entry.get("hooks") if isinstance(entry, dict) else None
        if not isinstance(commands, list) or not commands:
            raise BenchError("a PreToolUse entry of the lean-x export has no hooks list")
        for hook in commands:
            if not isinstance(hook, dict) or hook.get("type") != "command" or not isinstance(hook.get("command"), str):
                raise BenchError("a PreToolUse hook of the lean-x export is not a command hook")
            named = [path for path in HOOK_FILES if "$CLAUDE_PROJECT_DIR/%s" % path in hook["command"]]
            if len(named) != 1:
                raise BenchError("a PreToolUse hook command of the lean-x export does not run exactly one of %s"
                                 % ", ".join(HOOK_FILES))
            used.add(named[0])
    if SHAPER not in used:
        raise BenchError("the lean-x export does not run the shaper %s" % SHAPER)
    return sorted(used)


def check_style(output_style, style_bytes):
    if output_style != STYLE_NAME:
        raise BenchError("the lean-x export selects outputStyle %r, not %r" % (output_style, STYLE_NAME))
    if len(style_bytes) > STYLE_MAX_BYTES:
        raise BenchError("the style file is %d bytes, over the measured %d" % (len(style_bytes), STYLE_MAX_BYTES))
    if not style_bytes.startswith(("---\nname: %s\n" % STYLE_NAME).encode("ascii")):
        raise BenchError("the style file does not start with the front matter of the %r style" % STYLE_NAME)


def check_export(settings, spec, style_bytes):
    """(hooks, outputStyle) of a lean-x export, after every check above but the trim."""
    if not isinstance(settings, dict) or sorted(settings) != sorted(EXPORT_KEYS):
        raise BenchError("the lean-x export's settings keys are %s, not exactly %s"
                         % (sorted(settings) if isinstance(settings, dict) else type(settings).__name__, ", ".join(EXPORT_KEYS)))
    context = (spec.get("spec") or {}).get("context") if isinstance(spec, dict) else None
    if not isinstance(context, dict) or context.get("profile") != PROFILE:
        raise BenchError("the export is not the lean-x profile (spec.context.profile=%r)" % (context or {}).get("profile"))
    hooks = settings["hooks"]
    check_hooks(hooks)
    check_style(settings["outputStyle"], style_bytes)
    return hooks, settings["outputStyle"]


def check_trim(settings, spec, none_lean_bytes):
    """The export's trim, which must equal the trim in the task's none-lean settings."""
    include_git, deny = none_lean.lean_trim(settings, spec, (PROFILE,))
    base = json.loads(none_lean_bytes.decode("utf-8"))
    base_deny = (base.get("permissions") or {}).get("deny") if isinstance(base, dict) else None
    if include_git != base.get("includeGitInstructions") or deny != base_deny:
        raise BenchError("the lean-x trim (includeGitInstructions=%r, %d deny names) differs from none-lean's "
                         "(includeGitInstructions=%r, %s deny names)"
                         % (include_git, len(deny), base.get("includeGitInstructions"),
                            len(base_deny) if isinstance(base_deny, list) else None))
    return include_git, deny


def settings_for(none_lean_bytes, hooks, output_style):
    """none-lean's settings plus hooks and outputStyle. Deterministic bytes, formatted as none-lean's."""
    settings = json.loads(none_lean_bytes.decode("utf-8"))
    if not isinstance(settings, dict):
        raise BenchError("the none-lean settings are not a JSON object")
    present = [key for key in CARRIED if key in settings]
    if present:
        raise BenchError("the none-lean settings already set %s; olivium-x needs review" % ", ".join(present))
    settings["hooks"] = hooks
    settings["outputStyle"] = output_style
    return (json.dumps(settings, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


# ------------------------------------------------------------------ derive
def derive(ctx, task_id):
    """The arm's settings from the stored export and the task's none-lean settings. Returns (bytes, facts)."""
    export = export_dir(ctx, task_id)
    paths = {
        "settings": os.path.join(export, ".claude", "settings.json"),
        "spec": os.path.join(export, ".olivium", "spec.json"),
        "style": os.path.join(export, STYLE),
        "none_lean": none_lean.settings_path(ctx, task_id),
    }
    for name, path in sorted(paths.items()):
        if not os.path.isfile(path):
            if name == "none_lean":
                raise BenchError("olivium-x needs the none-lean settings of %s (prepare none-lean first): %s" % (task_id, path))
            raise BenchError("the lean-x export of %s has no %s" % (task_id, os.path.relpath(path, export)))
    settings = read_json(paths["settings"])
    spec = read_json(paths["spec"])
    style_bytes = _read_bytes(paths["style"])
    base = _read_bytes(paths["none_lean"])
    hooks, output_style = check_export(settings, spec, style_bytes)
    include_git, deny = check_trim(settings, spec, base)
    data = settings_for(base, hooks, output_style)
    facts = {
        "trim": {"includeGitInstructions": include_git, "permissions.deny": deny},
        "carried": list(CARRIED),
        "hook_files": check_hooks(hooks),
        "none_lean_settings_sha256": sha256_bytes(base),
        "exported_settings_sha256": sha256_file(paths["settings"]),
        "exported_spec_sha256": sha256_file(paths["spec"]),
        "style_bytes": len(style_bytes),
        "settings_file": os.path.basename(settings_path(ctx, task_id)),
        "settings_sha256": sha256_bytes(data),
    }
    return data, facts


def install(ctx, task_id):
    """OUT/arms/<task>/olivium-x holds exactly the three installed files, copied byte for byte."""
    export = export_dir(ctx, task_id)
    arm_dir = ctx.arm_dir(task_id, OLIVIUM_X)
    for rel in INSTALLED:
        if not os.path.isfile(os.path.join(export, rel)) or os.path.islink(os.path.join(export, rel)):
            raise BenchError("the lean-x export of %s has no regular file %s" % (task_id, rel))
    shutil.rmtree(arm_dir, ignore_errors=True)
    for rel in INSTALLED:
        target = os.path.join(arm_dir, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copyfile(os.path.join(export, rel), target)
    if tree_files(arm_dir) != sorted(INSTALLED):
        raise BenchError("the olivium-x arm directory of %s holds other files" % task_id)
    return arm_dir


def _write_settings(ctx, task_id, data):
    path = settings_path(ctx, task_id)
    tmp = path + ".tmp"
    with open(tmp, "wb") as handle:
        handle.write(data)
    os.replace(tmp, path)


# ------------------------------------------------------------------ build
def generate_export(ctx, task):
    """Run generate --context lean-x on the truncated repository; returns facts about the run."""
    task_id = task["task_id"]
    bare_clone = os.path.join(ctx.clones_dir, task["repo"].replace("/", "__") + ".git")
    work = os.path.join(ctx.out, "%s-work" % OLIVIUM_X, task_id)
    shutil.rmtree(work, ignore_errors=True)
    # Named as a clone would be: the generator derives the project's name from it.
    repo = os.path.join(work, task["repo"].split("/", 1)[1])
    workspace = os.path.join(work, "workspace")
    export = os.path.join(work, "export")
    empty = os.path.join(work, "empty")
    os.makedirs(workspace)
    os.makedirs(empty)
    olivium_v2.build_truncated_repo(bare_clone, task["base_sha"], repo)
    removed = olivium_v2.remove_instruction_files(repo)
    pre = olivium_v2.assert_no_post_base(task, repo, empty, bare_clone)
    if pre["failures"]:
        raise BenchError("post-base check failed before generating for %s: %s" % (task_id, "; ".join(pre["failures"])))
    snapshot, snapshot_record = olivium_ai.ensure_snapshot(ctx.out, ctx.paid)
    code, report = olivium_ai._run_cli(
        snapshot,
        ["generate", os.path.realpath(repo), "--runtime", "claude_code", "--export", os.path.realpath(export),
         "--context", PROFILE, "--json"],
        workspace, os.path.join(work, "generate"), GENERATE_TIMEOUT_S,
    )
    if code != 0 or report is None or not report.get("ok"):
        message = (report or {}).get("error") if isinstance(report, dict) else None
        raise BenchError("generate --context lean-x failed for %s (exit %s, %s); see %s"
                         % (task_id, code, message, os.path.join(work, "generate.stderr.log")))
    if not os.path.isdir(export):
        raise BenchError("generate produced no export directory for %s" % task_id)
    post = olivium_v2.assert_no_post_base(task, repo, export, bare_clone)
    if post["failures"]:
        raise BenchError("post-base check failed for %s: %s" % (task_id, "; ".join(post["failures"])))
    if os.path.exists(os.path.join(export, "CLAUDE.md")):
        raise BenchError("the lean-x export of %s has a CLAUDE.md" % task_id)
    with open(os.path.join(work, "generate.report.json"), "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, sort_keys=True)
    target = export_dir(ctx, task_id)
    shutil.rmtree(target, ignore_errors=True)
    shutil.copytree(export, target, symlinks=False)
    result = report.get("result") or {}
    return {
        "generator": "bin/harnessforge generate --context lean-x --json",
        "app_snapshot": snapshot_record,
        "digest": result.get("digest"),
        "profile_digest": result.get("profile_digest"),
        "blueprint_version": result.get("blueprint_version"),
        "counts": result.get("counts"),
        "diagnostics": result.get("diagnostics"),
        "removed_instruction_files": removed,
        "post_base_check": post,
        "post_base_check_before_generate": pre,
    }


def _record(ctx, task_id, generated, facts):
    arm_dir = ctx.arm_dir(task_id, OLIVIUM_X)
    return dict(
        generated,
        **facts,
        status="ok",
        arm=OLIVIUM_X,
        task_id=task_id,
        mode="paid" if ctx.paid else "rehearsal",
        rehearsal_fixture=False,
        setup_model_calls=0,
        cost_usd=0.0,
        cost_upper_bound_usd=0.0,
        tokens=dict(ZERO_TOKENS),
        permission_mode="bypassPermissions",
        export_dir=os.path.relpath(export_dir(ctx, task_id), ctx.out),
        export_sha256=tree_digest(export_dir(ctx, task_id)),
        harness_files=tree_files(arm_dir),
        harness_bytes=tree_bytes(arm_dir),
        arm_sha256=tree_digest(arm_dir),
        installed_sha256={rel: sha256_file(os.path.join(arm_dir, rel)) for rel in INSTALLED},
    )


def build(ctx, task):
    """Generate the export, install the three files and write the settings. No model call."""
    task_id = task["task_id"]
    if not os.path.isfile(none_lean.settings_path(ctx, task_id)):
        raise BenchError("olivium-x needs the none-lean settings of %s (prepare none-lean first)" % task_id)
    generated = generate_export(ctx, task)
    install(ctx, task_id)
    data, facts = derive(ctx, task_id)
    _write_settings(ctx, task_id, data)
    return _record(ctx, task_id, generated, facts)


def refresh(ctx, task_id, setup):
    """An ok setup: the export and installed files must be unchanged; the settings are derived again."""
    if tree_digest(export_dir(ctx, task_id)) != setup.get("export_sha256"):
        raise BenchError("the olivium-x export of %s changed after prepare; remove %s and prepare again"
                         % (task_id, ctx.setup_path(task_id, OLIVIUM_X)))
    if tree_digest(ctx.arm_dir(task_id, OLIVIUM_X)) != setup.get("arm_sha256"):
        raise BenchError("the olivium-x files of %s changed after prepare" % task_id)
    data, facts = derive(ctx, task_id)
    _write_settings(ctx, task_id, data)
    generated = {key: setup.get(key) for key in ("generator", "app_snapshot", "digest", "profile_digest",
                                                 "blueprint_version", "counts", "diagnostics",
                                                 "removed_instruction_files", "post_base_check",
                                                 "post_base_check_before_generate")}
    return _record(ctx, task_id, generated, facts)


def prepare(ctx, needs_setup):
    """Build or refresh olivium-x for every task, after none-lean. Returns [(arm, task_id, error)]."""
    failures = []
    for task in ctx.tasks:
        task_id = task["task_id"]
        path = ctx.setup_path(task_id, OLIVIUM_X)
        existing = read_json(path) if os.path.exists(path) else {}
        try:
            if existing.get("status") == "ok":
                print("olivium-x arm: %s (settings derived again)" % task_id, flush=True)
                setup = refresh(ctx, task_id, existing)
            elif needs_setup(ctx, task_id, OLIVIUM_X):
                print("olivium-x arm: %s" % task_id, flush=True)
                setup = build(ctx, task)
            else:
                continue
        except (BenchError, OSError, ValueError) as exc:
            setup = {"status": "failed", "arm": OLIVIUM_X, "task_id": task_id, "error": str(exc), "cost_usd": 0.0}
            failures.append((OLIVIUM_X, task_id, str(exc)))
        write_json_atomic(path, setup)
    return failures


def check_ready(ctx, task_id):
    """Problems that make a scored olivium-x trial unsafe to start; empty when ready."""
    setup_path = ctx.setup_path(task_id, OLIVIUM_X)
    path = settings_path(ctx, task_id)
    if not os.path.isfile(setup_path) or not os.path.isfile(path):
        return ["%s/%s settings (run prepare)" % (task_id, OLIVIUM_X)]
    setup = read_json(setup_path)
    problems = []
    arm_dir = ctx.arm_dir(task_id, OLIVIUM_X)
    if not os.path.isdir(arm_dir) or tree_files(arm_dir) != sorted(INSTALLED) or tree_digest(arm_dir) != setup.get("arm_sha256"):
        problems.append("%s/%s: the installed files changed after prepare" % (task_id, OLIVIUM_X))
    if not os.path.isdir(export_dir(ctx, task_id)) or tree_digest(export_dir(ctx, task_id)) != setup.get("export_sha256"):
        problems.append("%s/%s: the export changed after prepare" % (task_id, OLIVIUM_X))
    try:
        current, _facts = derive(ctx, task_id)
    except BenchError as exc:
        return problems + ["%s/%s: %s" % (task_id, OLIVIUM_X, exc)]
    stored = _read_bytes(path)
    if stored != current:
        problems.append("%s/%s settings no longer match none-lean's settings plus the export's hooks and style "
                        "(run prepare again)" % (task_id, OLIVIUM_X))
    if setup.get("settings_sha256") != sha256_bytes(stored):
        problems.append("%s/%s settings changed after prepare" % (task_id, OLIVIUM_X))
    return problems


def settings_bytes(ctx, task_id):
    return _read_bytes(settings_path(ctx, task_id))


__all__ = ["CARRIED", "EXPORT_KEYS", "INSTALLED", "build", "check_export", "check_hooks", "check_ready",
           "check_style", "check_trim", "derive", "install", "prepare", "refresh", "settings_bytes", "settings_for"]
