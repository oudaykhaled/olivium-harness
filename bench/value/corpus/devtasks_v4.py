#!/usr/bin/env python3
"""Select and validate the v4 harder development tasks.

    python3 -I corpus/devtasks_v4.py select --rules RULES.json --work WORK --clones CLONES --out OUT [--jobs 1]
        [--resume] [--static-only] [--max-validations N]
    python3 -I corpus/devtasks_v4.py materialize --manifest OUT/manifest-v4dev.json --out MATERIAL
        [--clones CLONES] [--tasks a,b]

Development data only: the repositories come from corpus/dev-repos-v3.txt, which the
benchmark v3 protocol excludes from its pool. The rules are in RULES.json (written before
the selection runs). This file wraps the v2 machinery in corpus_lib.py (linked issue,
base derivation, Docker validation, materialization) and grades each accepted gold fix
through bench/value/grade. It never edits corpus_lib.RECIPES for v2: the v4 recipes live
here. Nothing from a task repository runs on the host: git and read-only `gh api` calls
only; tests and grading run in Docker with network none.

Outputs in OUT: manifest-v4dev.json (with checksum), manifest-v4dev.sha256,
validation-v4dev.json, rejected-v4dev.jsonl. Docker names: olivium-bench-v4dev-* for
validation, olivium-bench-grade-v4dev* for the gold grade, images
olivium-bench-deps-<task>:v1.
"""

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_VALUE = os.path.dirname(_HERE)
# select.py in this directory shadows a standard library module: never put it first.
sys.path[:] = [p for p in sys.path if os.path.abspath(p or os.getcwd()) not in (_HERE, _VALUE)]

import argparse  # noqa: E402
import collections  # noqa: E402
import hashlib  # noqa: E402
import json  # noqa: E402
import re  # noqa: E402
import shutil  # noqa: E402
import subprocess  # noqa: E402,F401
import time  # noqa: E402
import types  # noqa: E402

sys.path.append(_HERE)
sys.path.append(_VALUE)

import corpus_lib as lib  # noqa: E402

RULES_NAME = "olivium.v4dev-rules/1"
CODE_EXTENSIONS = (".py", ".js", ".ts", ".mjs", ".cjs", ".tsx", ".jsx")
NAME_PREFIX = "olivium-bench-"
V4_PREFIX = "olivium-bench-v4dev-"
SAFE_GLOB = re.compile(r"^[A-Za-z0-9_./*{},-]{1,120}$")

PY_TEST_COMMAND = lib.PY_TEST_COMMAND
VITEST_COMMAND = (
    "mkdir -p /work/test-results && "
    "node_modules/.bin/vitest run --project unit --reporter=junit "
    "--outputFile=/work/test-results/results.xml"
)
MOCHA_COMMAND = (
    "mkdir -p /work/test-results && "
    "node bin/mocha.js --forbid-only --reporter xunit "
    "--reporter-option output=/work/test-results/results.xml %s"
)

# v4 recipes for the development repositories. v2's RECIPES is not touched.
PY_RECIPES = {
    "pallets/click": {"groups": ["tests", "dev"], "require": "tests", "dists": ["click"], "imports": ["click"], "apt": ["less"]},
    "pallets/werkzeug": {"groups": ["tests", "dev"], "require": "tests", "dists": ["werkzeug"], "imports": ["werkzeug"]},
    "pallets/flask": {"groups": ["tests", "dev"], "require": "tests", "dists": ["flask"], "imports": ["flask"]},
    # addopts carries -n 8; two workers keep a run inside the 1800 MB container.
    "encode/uvicorn": {"groups": ["dev"], "require": "dev", "dists": ["uvicorn"], "imports": ["uvicorn"], "pytest_args": "-n 2"},
    "urllib3/urllib3": {"groups": ["dev"], "require": "dev", "dists": ["urllib3"], "imports": ["urllib3"]},
    "hynek/structlog": {"groups": ["tests"], "require": "tests", "dists": ["structlog"], "imports": ["structlog"], "pytest_args": "-p no:randomly"},
    "marshmallow-code/marshmallow": {"groups": ["tests"], "require": "tests", "dists": ["marshmallow"], "imports": ["marshmallow"]},
    "python-attrs/attrs": {"groups": ["tests"], "require": "tests", "dists": ["attrs"], "imports": ["attr", "attrs"],
                           "build_env": {"SETUPTOOLS_SCM_PRETEND_VERSION": "0.0.0"}},
}
JS_RECIPES = {
    "axios/axios": {"runner": "vitest-unit", "dists": ["axios"], "imports": ["axios"]},
    "mochajs/mocha": {"runner": "mocha-self", "dists": ["mocha"], "imports": ["mocha"]},
}


# ------------------------------------------------------------------ helpers
def log(message):
    print("[%s] %s" % (lib.utc_now(), message), flush=True)


def canonical(data):
    return json.dumps(data, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def read_rules(path):
    with open(path, encoding="utf-8") as handle:
        rules = json.load(handle)
    if rules.get("schema") != RULES_NAME:
        raise SystemExit("rules file is not %s: %s" % (RULES_NAME, path))
    if rules.get("status") != "frozen":
        raise SystemExit("rules file is not frozen (status %r); freeze it before a selection run" % rules.get("status"))
    return rules


def v4_container_run(original):
    """corpus_lib names its containers olivium-bench-*; v4 runs them as olivium-bench-v4dev-*."""

    def wrapped(name, image, script, *args, **kwargs):
        if name.startswith(NAME_PREFIX) and not name.startswith(V4_PREFIX):
            name = V4_PREFIX + name[len(NAME_PREFIX):]
        return original(name, image, script, *args, **kwargs)

    return wrapped


# container_run removes its container by the (renamed) name it was given, so this one
# wrapper keeps every validation, probe and lint container in the v4dev namespace.
lib.container_run = v4_container_run(lib.container_run)


def is_code_path(path):
    return path.endswith(CODE_EXTENSIONS)


def package_json(repo, sha):
    text = repo.show(sha, "package.json")
    if text is None:
        return None
    try:
        data = json.loads(text)
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


# ------------------------------------------------------------------ static rule
def evaluate_pull_v4(api, repo, meta, pr, rules):
    """The v4 static rule. Returns a candidate dict or raises lib.Rejection."""
    static = rules["static_rule"]
    full_name = repo.full_name
    number = pr["number"]
    refs = lib.closing_issue_refs(full_name, pr.get("body"))
    if not refs:
        raise lib.Rejection("no_closing_issue_reference")
    issue, words, problems = lib.pick_linked_issue(api, full_name, refs, pr.get("merged_at"))
    if issue is None:
        raise lib.Rejection("linked_issue_not_usable", {"issues": {str(k): v for k, v in problems.items()}})
    fix_sha = pr.get("merge_commit_sha")
    if not fix_sha or not repo.ensure_commit(fix_sha):
        raise lib.Rejection("merge_commit_unavailable")
    files = api.get("repos/%s/pulls/%d/files?per_page=100" % (full_name, number)) or []
    pr["_files"] = files
    commits = api.get("repos/%s/pulls/%d/commits?per_page=100" % (full_name, number)) or []
    pr["_commits"] = len(commits)
    base_sha, base_how = lib.derive_base(repo, api, pr, fix_sha)
    if not repo.ensure_commit(base_sha):
        raise lib.Rejection("base_commit_unavailable")
    stats = repo.numstat(base_sha, fix_sha)
    tests = [p for p, _a, _d in stats if lib.is_test_path(p)]
    non_tests = [(p, a, d) for p, a, d in stats if not lib.is_test_path(p)]
    dependency = sorted(p for p, _a, _d in non_tests if lib.is_dependency_path(p))
    if dependency:
        raise lib.Rejection("dependency_change", {"paths": dependency})
    if len(tests) < static["min_test_files"]:
        raise lib.Rejection("no_test_change")
    if any(a is None or d is None for _p, a, d in non_tests):
        raise lib.Rejection("binary_non_test_change")
    code = [(p, a + d) for p, a, d in non_tests if is_code_path(p)]
    code_lines = sum(n for _p, n in code)
    lines = sum(a + d for _p, a, d in non_tests)
    limits = static["code_files_non_test"]
    if len(code) < limits["min"]:
        raise lib.Rejection("no_non_test_code_change")
    if len(code) > limits["max"]:
        raise lib.Rejection("too_many_non_test_code_files", {"count": len(code)})
    if lines > static["max_non_test_lines"]:
        raise lib.Rejection("too_many_non_test_lines", {"lines": lines})
    harder = static["harder_if_any"]
    if len(code) < harder["min_code_files"] and code_lines < harder["min_code_lines"]:
        raise lib.Rejection("not_harder", {"code_files": len(code), "code_lines": code_lines})
    owner, name = full_name.split("/", 1)
    return {
        "task_id": ("%s-%s-%d" % (owner, name, number)).lower().replace(".", "-"),
        "repo": full_name,
        "repo_url": repo.url,
        "license": meta["license"],
        "language": meta["language"],
        "pr_number": number,
        "pr_url": "%s/pull/%d" % (repo.url, number),
        "issue_number": issue["number"],
        "issue_url": "%s/issues/%d" % (repo.url, issue["number"]),
        "issue_sha256": lib.sha256_text(lib.issue_markdown(issue.get("title"), issue.get("body"))),
        "issue_prose_words": words,
        "base_sha": base_sha,
        "base_derivation": base_how,
        "fix_sha": fix_sha,
        "merged_at": pr["merged_at"],
        "gold_files": sorted(p for p, _a, _d in non_tests),
        "test_files": sorted(tests),
        "non_test_lines": lines,
        "code_files": len(code),
        "code_lines": code_lines,
        "markdown_files_count": sum(1 for p in repo.tree_paths(base_sha) if lib.MARKDOWN_RE.search(p)),
        "pr_commits": sorted({c["sha"] for c in commits}),
    }


# ------------------------------------------------------------------ recipes
def recipe_for_v4(repo, cand):
    """The install and test recipe for one candidate at its base commit, or Rejection."""
    name = cand["repo"]
    if name in PY_RECIPES:
        spec = PY_RECIPES[name]
        if repo.show(cand["base_sha"], "uv.lock") is None:
            raise lib.Rejection("recipe_not_applicable", {"why": "no uv.lock at base_sha"})
        available = lib.dependency_groups(repo.show(cand["base_sha"], "pyproject.toml"))
        if spec["require"] not in available:
            raise lib.Rejection("recipe_not_applicable", {"why": "no %s dependency group at base_sha" % spec["require"]})
        recipe = {"kind": "uv", "groups": [g for g in spec["groups"] if g in available], "dists": spec["dists"], "imports": spec["imports"]}
        for key in ("apt", "build_env"):
            if key in spec:
                recipe[key] = spec[key]
        command = PY_TEST_COMMAND
        if spec.get("pytest_args"):
            command = command + " " + spec["pytest_args"]
        recipe["test_command"] = command
        recipe["v4_recipe"] = "uv-pytest"
        return recipe
    if name in JS_RECIPES:
        spec = JS_RECIPES[name]
        package = package_json(repo, cand["base_sha"])
        if package is None:
            raise lib.Rejection("recipe_not_applicable", {"why": "no package.json at base_sha"})
        scripts = package.get("scripts") or {}
        recipe = {"kind": "npm", "dists": spec["dists"], "imports": spec["imports"]}
        if spec["runner"] == "vitest-unit":
            config = repo.show(cand["base_sha"], "vitest.config.js") or repo.show(cand["base_sha"], "vitest.config.mjs") or ""
            if "vitest" not in json.dumps(scripts) or "name: 'unit'" not in config:
                raise lib.Rejection("recipe_not_applicable", {"why": "no vitest unit project at base_sha"})
            recipe["test_command"] = VITEST_COMMAND
            recipe["v4_recipe"] = "npm-vitest-unit"
            return recipe
        if spec["runner"] == "mocha-self":
            script = scripts.get("test-node:unit") or ""
            globs = re.findall(r'"([^"]+)"', script)
            if repo.show(cand["base_sha"], "bin/mocha.js") is None or not globs or not all(SAFE_GLOB.match(g) for g in globs):
                raise lib.Rejection("recipe_not_applicable", {"why": "no test-node:unit globs or bin/mocha.js at base_sha"})
            recipe["test_command"] = MOCHA_COMMAND % " ".join("'%s'" % g for g in globs)
            recipe["v4_recipe"] = "npm-mocha-self-unit"
            return recipe
    raise lib.Rejection("no_install_recipe", {"repo": name})


# ------------------------------------------------------------------ gold grade
def grade_gold(cand, validated, recipe, work):
    """Grade the real fix through bench/value/grade, protected paths on. Returns the grade dict."""
    from grade import grader  # bench/value on sys.path (appended)

    task = manifest_task_v4(cand, validated, recipe)
    task_dir = os.path.join(work, "tasks", cand["task_id"])
    material = os.path.join(task_dir, "goldgrade-material")
    run_dir = os.path.join(task_dir, "goldgrade")
    shutil.rmtree(run_dir, ignore_errors=True)
    os.makedirs(material, exist_ok=True)
    os.makedirs(run_dir)
    shutil.copy(os.path.join(task_dir, "test.patch"), os.path.join(material, "test.patch"))
    tag = "v4dev" + hashlib.sha256(cand["task_id"].encode("utf-8")).hexdigest()[:6]
    ctx = types.SimpleNamespace(paid=False, tag=tag)
    return grader.grade(ctx, task, os.path.join(task_dir, "gold.patch"), material, run_dir)


def manifest_task_v4(cand, validated, recipe):
    task = lib.manifest_task(cand, validated, recipe)
    task.update({
        "held_out": False,
        "v4dev": True,
        "code_files": cand["code_files"],
        "code_lines": cand["code_lines"],
        "non_test_lines": cand["non_test_lines"],
        "recipe": recipe.get("v4_recipe"),
    })
    return task


# ------------------------------------------------------------------ selection
class RepoQueue:
    """Static survivors of one repository, newest merge first, evaluated lazily (as in v2)."""

    def __init__(self, api, full_name, meta, repo, rules, rejected, excluded):
        self.full_name = full_name
        self.meta = meta
        self.repo = repo
        self.rules = rules
        self.rejected = rejected
        self.api = api
        # walk_merged_pulls keeps merged_at > cutoff + T23:59:59Z, so the day before is passed.
        pulls = lib.walk_merged_pulls(api, full_name, rules["static_rule"]["walk_cutoff"])
        self.pulls = collections.deque(pr for pr in pulls if pr["number"] not in excluded)
        self.static_seen = 0

    def next_candidate(self):
        while self.pulls:
            pr = self.pulls.popleft()
            self.static_seen += 1
            if not lib.closing_issue_refs(self.full_name, pr.get("body")):
                self.rejected.append(lib.rejection_record(self.full_name, pr, "static", "no_closing_issue_reference", {}))
                continue
            if not pr.get("merge_commit_sha"):
                self.rejected.append(lib.rejection_record(self.full_name, pr, "static", "merge_commit_unavailable", {}))
                continue
            self.repo.ensure_clone()
            try:
                return evaluate_pull_v4(self.api, self.repo, self.meta, pr, self.rules), pr
            except lib.Rejection as exc:
                self.rejected.append(lib.rejection_record(self.full_name, pr, "static", exc.reason, exc.detail))
        return None


def select(args):
    rules = read_rules(args.rules)
    work = os.path.abspath(args.work)
    out = os.path.abspath(args.out)
    for directory in ("tasks", "validation"):
        os.makedirs(os.path.join(work, directory), exist_ok=True)
    os.makedirs(out, exist_ok=True)
    api = lib.Api(os.path.join(work, "api-cache"), refresh=args.refresh)
    clones = os.path.abspath(args.clones)
    target = rules["target"]
    excluded = {}
    for item in rules["exclude_pull_requests"]:
        excluded.setdefault(item["repo"], set()).add(int(item["pr"]))
    rejected = []
    selected = []
    evidence = {}
    gold = {}
    per_repo = collections.Counter()
    queues = {}
    validations = {"count": 0}
    phase_log = []

    def queue_for(full_name):
        if full_name in queues:
            return queues[full_name]
        meta = lib.repo_metadata(api, full_name)
        problem = None
        if meta["license"] not in lib.RULES["licenses"]:
            problem = ("licence_not_allowed", {"license": meta["license"]})
        elif meta["language"] not in lib.RULES["languages"]:
            problem = ("language_not_allowed", {"language": meta["language"]})
        elif full_name not in PY_RECIPES and full_name not in JS_RECIPES:
            problem = ("no_install_recipe", {})
        if problem:
            rejected.append({"repo": full_name, "stage": "repository", "reason": problem[0], "detail": problem[1]})
            queues[full_name] = None
            return None
        log("%s: walking pull requests merged on or after %s" % (full_name, rules["static_rule"]["merged_on_or_after"]))
        queues[full_name] = RepoQueue(api, full_name, meta, lib.Repo(full_name, clones), rules, rejected, excluded.get(full_name, set()))
        return queues[full_name]

    def take_from(full_name):
        queue = queue_for(full_name)
        if queue is None:
            return False
        while True:
            if validations["count"] >= args.max_validations:
                return False
            item = queue.next_candidate()
            if item is None:
                return False
            cand, pr = item
            if args.static_only:
                selected.append({"task_id": cand["task_id"], "static_only": True, "language": cand["language"].lower(),
                                 "code_files": cand["code_files"],
                                 "code_lines": cand["code_lines"], "non_test_lines": cand["non_test_lines"]})
                per_repo[full_name] += 1
                return True
            record_path = os.path.join(work, "validation", cand["task_id"] + ".json")
            try:
                recipe = recipe_for_v4(queue.repo, cand)
                if args.resume and os.path.exists(record_path):
                    with open(record_path, encoding="utf-8") as handle:
                        saved = json.load(handle)
                    if saved.get("status") == "rejected":
                        raise lib.Rejection(saved["reason"], saved.get("detail"))
                    validated, graded = saved["validated"], saved["gold_grade"]
                    log("reusing validation for %s" % cand["task_id"])
                else:
                    validations["count"] += 1
                    log("validating %s (%d/%d validations)" % (cand["task_id"], validations["count"], args.max_validations))
                    validated = lib.validate_candidate(queue.repo, cand, recipe, work, args.jobs, log)
                    graded = grade_gold(cand, validated, recipe, work)
                    if graded.get("status") != "ok":
                        raise lib.Rejection("gold_grade_infra_error", {"error": graded.get("error")})
                    if not graded.get("solved") or graded.get("p2p_regressions"):
                        raise lib.Rejection("gold_not_solved", {k: graded.get(k) for k in (
                            "f2p_passed", "f2p_total", "p2p_regressions", "p2p_missing", "patch_applied", "test_exit")})
                    lib.write_text(record_path, json.dumps({"status": "accepted", "validated": validated, "gold_grade": graded}, indent=2) + "\n")
            except lib.Rejection as exc:
                lib.write_text(record_path, json.dumps({"status": "rejected", "reason": exc.reason, "detail": exc.detail}, indent=2) + "\n")
                rejected.append(lib.rejection_record(full_name, pr, "validation", exc.reason, exc.detail))
                log("rejected %s: %s %s" % (cand["task_id"], exc.reason, json.dumps(exc.detail)[:300]))
                continue
            selected.append(manifest_task_v4(cand, validated, recipe))
            evidence[cand["task_id"]] = validated["evidence"]
            gold[cand["task_id"]] = {k: graded.get(k) for k in (
                "solved", "f2p_passed", "f2p_total", "p2p_total", "p2p_regressions", "p2p_missing", "lint_ok", "lint_exit", "restored_paths")}
            per_repo[full_name] += 1
            log("accepted %s (%d/%d)" % (cand["task_id"], len(selected), target["max_tasks"]))
            return True

    def round_robin(repositories, stop):
        active = True
        while active and not stop():
            active = False
            for full_name in repositories:
                if stop():
                    break
                if per_repo[full_name] >= target["max_per_repository"]:
                    continue
                if take_from(full_name):
                    active = True

    def js_count():
        return sum(1 for task in selected if (task.get("language") or "").lower() in ("javascript", "typescript"))

    order = rules["repositories"]["use"]
    js_repos = [name for name in order if name in JS_RECIPES]
    # Phase 1: the JavaScript quota first, so it cannot be crowded out by Python repositories.
    round_robin(js_repos, lambda: js_count() >= target["min_js_ts"] or len(selected) >= target["max_tasks"])
    phase_log.append({"phase": "js_quota", "accepted": len(selected)})
    # Phase 2: every repository in order until the target.
    round_robin(order, lambda: len(selected) >= target["max_tasks"])
    phase_log.append({"phase": "all_use", "accepted": len(selected)})
    log("selection finished: %d accepted, %d Docker validations" % (len(selected), validations["count"]))

    rejected.sort(key=lambda r: (r.get("repo", ""), r.get("stage", ""), r.get("pr_number", 0)))
    with open(os.path.join(out, "rejected-v4dev.jsonl"), "w", encoding="utf-8") as handle:
        for record in rejected:
            handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
    not_reached = {name: len(queue.pulls) for name, queue in sorted(queues.items()) if queue is not None}
    if args.static_only:
        lib.write_text(os.path.join(out, "static-v4dev.json"), json.dumps({"survivors": selected, "not_reached": not_reached}, indent=2) + "\n")
        log("static-only: %d survivors taken" % len(selected))
        return 0
    rules_sha = hashlib.sha256(open(args.rules, "rb").read()).hexdigest()
    manifest = {
        "frozen_at": lib.utc_now(),
        "checksum": "",
        "selection": {
            "protocol": "PROTOCOL-v4dev.md (development data; not evidence of value)",
            "rules_sha256": rules_sha,
            "rules": rules,
            "relaxations": [],
            "phases": phase_log,
            "docker_validations": validations["count"],
        },
        "tasks": selected,
    }
    manifest["checksum"] = lib.manifest_checksum(manifest)
    lib.write_text(os.path.join(out, "manifest-v4dev.json"), json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    with open(os.path.join(out, "manifest-v4dev.json"), "rb") as handle:
        file_sha = hashlib.sha256(handle.read()).hexdigest()
    lib.write_text(os.path.join(out, "manifest-v4dev.sha256"), "%s  manifest-v4dev.json\nchecksum %s\n" % (file_sha, manifest["checksum"]))
    lib.write_text(os.path.join(out, "validation-v4dev.json"), json.dumps({
        "selected": [task["task_id"] for task in selected],
        "per_repository": dict(sorted(per_repo.items())),
        "js_ts_tasks": js_count(),
        "phases": phase_log,
        "docker_validations": validations["count"],
        "not_reached_static_queue": not_reached,
        "evidence": evidence,
        "gold_grade": gold,
    }, indent=2, ensure_ascii=False) + "\n")
    log("manifest-v4dev written: %d tasks, checksum %s" % (len(selected), manifest["checksum"]))
    if len(selected) < target["min_tasks"]:
        log("SHORTFALL: %d tasks, the rules ask for at least %d; see rules 'next_relaxation'" % (len(selected), target["min_tasks"]))
        return 2
    if js_count() < target["min_js_ts"]:
        log("SHORTFALL: %d JavaScript/TypeScript tasks, the rules ask for at least %d" % (js_count(), target["min_js_ts"]))
        return 2
    return 0


def materialize(args):
    """Task material (issue.md, test.patch, gold.patch, repo/) for the runner, from manifest references."""
    with open(args.manifest, encoding="utf-8") as handle:
        manifest = json.load(handle)
    if lib.manifest_checksum(manifest) != manifest.get("checksum"):
        print("manifest checksum mismatch: refusing to materialize", file=sys.stderr)
        return 3
    wanted = {t for t in (args.tasks or "").split(",") if t}
    tasks = [t for t in manifest["tasks"] if not wanted or t["task_id"] in wanted]
    missing = wanted - {t["task_id"] for t in tasks}
    if missing:
        print("unknown task ids: %s" % ",".join(sorted(missing)), file=sys.stderr)
        return 3
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    clones = os.path.abspath(args.clones) if args.clones else os.path.join(out, ".clones")
    api = lib.Api(os.path.join(out, ".api-cache"))
    results = [lib.materialize_task(t, out, api, clones, True, args.refresh) for t in tasks]
    print(json.dumps({"manifest_checksum": manifest["checksum"], "tasks": results}, indent=2))
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command")
    sel = sub.add_parser("select")
    sel.add_argument("--rules", required=True)
    sel.add_argument("--work", required=True)
    sel.add_argument("--clones", required=True)
    sel.add_argument("--out", required=True)
    sel.add_argument("--jobs", type=int, default=1)
    sel.add_argument("--resume", action="store_true")
    sel.add_argument("--refresh", action="store_true")
    sel.add_argument("--static-only", action="store_true")
    sel.add_argument("--max-validations", type=int, default=24, help="cap on Docker validations in one run")
    mat = sub.add_parser("materialize")
    mat.add_argument("--manifest", required=True)
    mat.add_argument("--out", required=True)
    mat.add_argument("--clones")
    mat.add_argument("--tasks")
    mat.add_argument("--refresh", action="store_true")
    args = parser.parse_args(argv)
    if args.command == "select":
        if args.jobs not in (1, 2):
            parser.error("--jobs must be 1 or 2")
        if "/v3-program/v3/" in os.path.abspath(args.clones) + "/" or "/v3-program/v3/" in os.path.abspath(args.work) + "/":
            parser.error("v4 dev clones and work never live under v3-program/v3")
        return select(args)
    if args.command == "materialize":
        return materialize(args)
    parser.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
