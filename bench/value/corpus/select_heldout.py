#!/usr/bin/env python3
"""Select the held-out tasks for protocol v2 (PROTOCOL-v2.md, Tasks).

Applies the existing rule in corpus_lib.py to repositories the analyzer was not
tuned on, writes manifest-v2.json (the 5 pilot tasks unchanged, plus the held-out
tasks), rejected-v2.jsonl and validation-v2.json. Nothing is executed on the host
from a task repository: git and read-only `gh api` calls only, tests in Docker.

Same sys.path care as select.py: that file's name shadows a standard library
module, so this directory is dropped from sys.path before anything else loads.
"""

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:] = [p for p in sys.path if os.path.abspath(p or os.getcwd()) != _HERE]

import argparse  # noqa: E402
import base64  # noqa: E402
import collections  # noqa: E402
import json  # noqa: E402
import re  # noqa: E402
import subprocess  # noqa: E402,F401
import time  # noqa: E402
import urllib.parse  # noqa: E402

sys.path.append(_HERE)

import corpus_lib as lib  # noqa: E402

TUNED_REPOSITORIES = ["pallets/click", "pallets/flask", "python-attrs/attrs", "expressjs/express"]
NAMED_REPOSITORIES = ["pallets/jinja", "encode/httpx"]
SEARCH_LANGUAGES = ["Python", "JavaScript", "TypeScript"]
SEARCH_LICENCES = ["mit", "apache-2.0", "bsd-3-clause", "bsd-2-clause"]
EXTRA_REPOSITORY_LIMIT = 15
EXTRA_MIN_STARS = 1000
PUSHED_AFTER = "2026-06-30"
HELDOUT_TARGET = 5
HELDOUT_MINIMUM = 3
MAX_PER_REPOSITORY = 3
MAX_TASKS_TOTAL = 10
FIRST_PASS_CUTOFF = lib.RULES["merged_after"]
WIDENED_CUTOFF = "2026-01-01"


class HeldoutApi(lib.Api):
    """The corpus API cache, waiting out a rate limit instead of failing."""

    def get(self, endpoint):
        while True:
            try:
                return lib.Api.get(self, endpoint)
            except RuntimeError as exc:
                text = str(exc).lower()
                if "rate limit" in text or "api rate" in text or "secondary" in text:
                    print("[%s] rate limited; waiting 120s" % lib.utc_now(), flush=True)
                    time.sleep(120)
                    continue
                raise


def read_manifest(path):
    with open(path, encoding="utf-8") as handle:
        manifest = json.load(handle)
    if lib.manifest_checksum(manifest) != manifest.get("checksum"):
        raise SystemExit("pilot manifest checksum mismatch: %s" % path)
    return manifest


def search_extra_repositories(api, log):
    """Repository search per PROTOCOL-v2.md; returns (ordered records, search queries)."""
    seen = {}
    queries = []
    for language in SEARCH_LANGUAGES:
        for licence in SEARCH_LICENCES:
            query = "language:%s stars:>=%d archived:false fork:false pushed:>=%s license:%s" % (
                language, EXTRA_MIN_STARS, PUSHED_AFTER, licence,
            )
            queries.append(query)
            endpoint = "search/repositories?q=%s&sort=stars&order=desc&per_page=100" % urllib.parse.quote(query, safe="")
            data = api.get(endpoint) or {}
            for item in data.get("items", []):
                seen[item["full_name"]] = {
                    "full_name": item["full_name"],
                    "stars": item.get("stargazers_count", 0),
                    "language": item.get("language"),
                    "license": (item.get("license") or {}).get("spdx_id"),
                    "default_branch": item.get("default_branch"),
                }
            time.sleep(2.5)
    ordered = sorted(seen.values(), key=lambda r: (-r["stars"], r["full_name"]))
    log("repository search: %d queries, %d distinct repositories" % (len(queries), len(ordered)))
    return ordered, queries


def get_contents(api, full_name, path, ref):
    endpoint = "repos/%s/contents/%s?ref=%s" % (full_name, urllib.parse.quote(path), urllib.parse.quote(ref, safe=""))
    data = api.get(endpoint)
    if isinstance(data, dict) and data.get("type") == "file":
        return data
    return None


def project_name(pyproject_text):
    """[project] name, without a TOML parser (host Python may be 3.9)."""
    inside = False
    for line in (pyproject_text or "").splitlines():
        stripped = line.strip()
        if stripped.startswith("["):
            inside = stripped == "[project]"
            continue
        if inside:
            match = re.match(r'name\s*=\s*["\']([^"\']+)["\']', stripped)
            if match:
                return match.group(1)
    return None


def decode_content(entry):
    if entry.get("encoding") != "base64" or not entry.get("content"):
        return ""
    return base64.b64decode(entry["content"]).decode("utf-8", "replace")


def generic_recipe(dist):
    """The pilot's uv recipe with this project's names; recipe_for still checks base_sha."""
    return {
        "kind": "uv",
        "groups": ["tests", "dev"],
        "dists": [dist],
        "imports": [dist.replace("-", "_").lower()],
        "generic": True,
    }


def qualify_extra_repository(api, record):
    """Returns (recipe, rejection_detail): exactly one is not None."""
    if record["language"] != "Python":
        return None, {"reason": "no_generic_install_recipe", "why": "no generic JUnit test command for %s" % record["language"]}
    branch = record["default_branch"] or "main"
    if get_contents(api, record["full_name"], "uv.lock", branch) is None:
        return None, {"reason": "no_generic_install_recipe", "why": "no root uv.lock at default branch"}
    pyproject = get_contents(api, record["full_name"], "pyproject.toml", branch)
    if pyproject is None:
        return None, {"reason": "no_generic_install_recipe", "why": "no pyproject.toml at default branch"}
    text = decode_content(pyproject)
    if "tests" not in lib.dependency_groups(text):
        return None, {"reason": "no_generic_install_recipe", "why": "no tests dependency group at default branch"}
    dist = project_name(text)
    if not dist:
        return None, {"reason": "no_generic_install_recipe", "why": "no [project] name at default branch"}
    return generic_recipe(dist), None


class Queue:
    """Static survivors of one repository, evaluated lazily, newest merge first.

    Lazy on purpose: walking this way visits candidates in exactly the same order as
    the pilot's up-front walk, and skips the API calls for pull requests that the
    round-robin never reaches.
    """

    def __init__(self, api, full_name, meta, repo, cutoff, upper_bound, rejected):
        self.full_name = full_name
        self.meta = meta
        self.repo = repo
        self.rejected = rejected
        pulls = lib.walk_merged_pulls(api, full_name, cutoff)
        if upper_bound is not None:
            pulls = [pr for pr in pulls if pr["merged_at"] <= upper_bound]
        self.pulls = collections.deque(pulls)
        self.api = api

    def next_candidate(self):
        while self.pulls:
            pr = self.pulls.popleft()
            # Checked first so a repository only clones once a pull request needs it.
            if not lib.closing_issue_refs(self.full_name, pr.get("body")):
                self.rejected.append(lib.rejection_record(self.full_name, pr, "static", "no_closing_issue_reference", {}))
                continue
            if not pr.get("merge_commit_sha"):
                self.rejected.append(lib.rejection_record(self.full_name, pr, "static", "merge_commit_unavailable", {}))
                continue
            self.repo.ensure_clone()
            try:
                return lib.evaluate_pull(self.api, self.repo, self.meta, pr), pr
            except lib.Rejection as exc:
                self.rejected.append(lib.rejection_record(self.full_name, pr, "static", exc.reason, exc.detail))
        return None


def select(args):
    def log(message):
        print("[%s] %s" % (lib.utc_now(), message), flush=True)

    work = os.path.abspath(args.work)
    for directory in ("tasks", "validation"):
        os.makedirs(os.path.join(work, directory), exist_ok=True)
    pilot = read_manifest(args.pilot_manifest)
    api = HeldoutApi(os.path.abspath(args.api_cache), refresh=args.refresh)
    clones = os.path.abspath(args.clones)
    rejected = []
    selected = []
    evidence = {}
    relaxations = []
    accepted_per_repo = collections.Counter()
    search_queries = []

    # Build the ordered candidate repository list per the protocol.
    repositories = list(NAMED_REPOSITORIES)
    extras, search_queries = search_extra_repositories(api, log)
    not_reached_repositories = []
    kept = 0
    for record in extras:
        name = record["full_name"]
        if name in TUNED_REPOSITORIES or name in NAMED_REPOSITORIES:
            continue
        if kept >= EXTRA_REPOSITORY_LIMIT:
            not_reached_repositories.append(name)
            continue
        recipe, problem = qualify_extra_repository(api, record)
        if recipe is None:
            rejected.append({"repo": name, "stage": "repository_search", "reason": problem["reason"],
                             "detail": {"why": problem["why"], "stars": record["stars"], "language": record["language"], "license": record["license"]}})
            continue
        lib.RECIPES[name] = recipe
        repositories.append(name)
        kept += 1
    log("candidate repositories (%d): %s" % (len(repositories), ", ".join(repositories)))

    queues = {}
    repo_objects = {}
    repo_rejected_early = set()

    def queue_for(full_name, cutoff, upper_bound):
        key = (full_name, cutoff)
        if key in queues:
            return queues[key]
        if full_name in repo_rejected_early:
            queues[key] = None
            return None
        if full_name not in repo_objects:
            meta = lib.repo_metadata(api, full_name)
            if meta["license"] not in lib.RULES["licenses"]:
                rejected.append({"repo": full_name, "stage": "repository", "reason": "licence_not_allowed", "detail": {"license": meta["license"]}})
                repo_rejected_early.add(full_name)
                queues[key] = None
                return None
            if meta["language"] not in lib.RULES["languages"]:
                rejected.append({"repo": full_name, "stage": "repository", "reason": "language_not_allowed", "detail": {"language": meta["language"]}})
                repo_rejected_early.add(full_name)
                queues[key] = None
                return None
            if full_name not in NAMED_REPOSITORIES and meta["stars"] <= lib.RULES["extra_repository_min_stars"]:
                rejected.append({"repo": full_name, "stage": "repository", "reason": "too_few_stars", "detail": {"stars": meta["stars"]}})
                repo_rejected_early.add(full_name)
                queues[key] = None
                return None
            if full_name not in lib.RECIPES:
                rejected.append({"repo": full_name, "stage": "repository", "reason": "no_install_recipe", "detail": {}})
                repo_rejected_early.add(full_name)
                queues[key] = None
                return None
            repo_objects[full_name] = (lib.Repo(full_name, clones), meta)
        repo, meta = repo_objects[full_name]
        log("%s: walking pull requests merged after %s" % (full_name, cutoff))
        queues[key] = Queue(api, full_name, meta, repo, cutoff, upper_bound, rejected)
        return queues[key]

    def take_from(full_name, cutoff, upper_bound):
        """Validate candidates from one repository until one is accepted. Returns True if accepted."""
        queue = queue_for(full_name, cutoff, upper_bound)
        if queue is None:
            return False
        repo, _meta = repo_objects[full_name]
        while True:
            item = queue.next_candidate()
            if item is None:
                return False
            cand, pr = item
            record_path = os.path.join(work, "validation", cand["task_id"] + ".json")
            try:
                recipe = lib.recipe_for(repo, cand)
                if args.resume and os.path.exists(record_path):
                    with open(record_path, encoding="utf-8") as fh:
                        saved = json.load(fh)
                    if saved.get("status") == "rejected":
                        raise lib.Rejection(saved["reason"], saved.get("detail"))
                    validated = saved["validated"]
                    log("reusing validation for %s" % cand["task_id"])
                else:
                    log("validating %s" % cand["task_id"])
                    validated = lib.validate_candidate(repo, cand, recipe, work, args.jobs, log)
                    lib.write_text(record_path, json.dumps({"status": "accepted", "validated": validated}, indent=2) + "\n")
            except lib.Rejection as exc:
                lib.write_text(record_path, json.dumps({"status": "rejected", "reason": exc.reason, "detail": exc.detail}, indent=2) + "\n")
                rejected.append(lib.rejection_record(full_name, pr, "validation", exc.reason, exc.detail))
                log("rejected %s: %s %s" % (cand["task_id"], exc.reason, exc.detail))
                continue
            selected.append(dict(lib.manifest_task(cand, validated, recipe), held_out=True))
            evidence[cand["task_id"]] = validated["evidence"]
            accepted_per_repo[full_name] += 1
            log("accepted %s (%d/%d)" % (cand["task_id"], len(selected), HELDOUT_TARGET))
            return True

    def round_robin(cutoff, upper_bound):
        active = True
        while active and len(selected) < HELDOUT_TARGET:
            active = False
            for full_name in repositories:
                if len(selected) >= HELDOUT_TARGET:
                    break
                if accepted_per_repo[full_name] >= MAX_PER_REPOSITORY:
                    continue
                if take_from(full_name, cutoff, upper_bound):
                    active = True

    # Pass 1: the pre-registered date. Pass 2 only if the protocol's condition holds.
    round_robin(FIRST_PASS_CUTOFF, None)
    pass_counts = {"first_pass": len(selected)}
    log("first pass (merged after %s): %d accepted" % (FIRST_PASS_CUTOFF, len(selected)))
    if len(selected) < HELDOUT_TARGET:
        relaxations.append({
            "kind": "merged_after",
            "pre_registered": FIRST_PASS_CUTOFF,
            "used": WIDENED_CUTOFF,
            "applies_to": "held-out tasks only",
            "reason": "fewer than %d held-out tasks accepted after every candidate repository was walked at the pre-registered date" % HELDOUT_TARGET,
        })
        round_robin(WIDENED_CUTOFF, FIRST_PASS_CUTOFF + "T23:59:59Z")
        pass_counts["after_widening"] = len(selected)
        log("second pass (merged after %s): %d accepted in total" % (WIDENED_CUTOFF, len(selected)))

    rejected.sort(key=lambda r: (r.get("repo", ""), r.get("stage", ""), r.get("pr_number", 0)))
    with open(os.path.join(args.out, "rejected-v2.jsonl"), "w", encoding="utf-8") as fh:
        for record in rejected:
            fh.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")

    if len(selected) < HELDOUT_MINIMUM:
        log("too few held-out tasks: %d (at least %d required); no manifest written" % (len(selected), HELDOUT_MINIMUM))
        return 3

    pilot_tasks = [dict(task, held_out=False) for task in pilot["tasks"]]
    manifest = {
        "frozen_at": lib.utc_now(),
        "checksum": "",
        "selection": {
            "protocol": "PROTOCOL-v2.md",
            "pilot_manifest_checksum": pilot["checksum"],
            "pilot_task_ids": [task["task_id"] for task in pilot["tasks"]],
            "tuned_repositories": TUNED_REPOSITORIES,
            "rules": dict(
                lib.RULES,
                max_tasks=MAX_TASKS_TOTAL,
                max_per_repository=MAX_PER_REPOSITORY,
                note_max_changes="max_tasks and max_per_repository are raised for the held-out tasks only (PROTOCOL-v2.md)",
                extra_repository_search={
                    "queries": search_queries,
                    "languages": SEARCH_LANGUAGES,
                    "licences": SEARCH_LICENCES,
                    "first_page_per_query": 100,
                    "keep": EXTRA_REPOSITORY_LIMIT,
                    "generic_recipe": "uv, tests dependency group, Python only",
                },
                repositories_used=repositories,
            ),
            "relaxations": relaxations,
            "pass_counts": pass_counts,
        },
        "tasks": pilot_tasks + selected,
    }
    manifest["checksum"] = lib.manifest_checksum(manifest)
    lib.write_text(os.path.join(args.out, "manifest-v2.json"), json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    lib.write_text(
        os.path.join(args.out, "validation-v2.json"),
        json.dumps({
            "selected_held_out": [task["task_id"] for task in selected],
            "pilot_tasks": [task["task_id"] for task in pilot["tasks"]],
            "not_reached_repositories": not_reached_repositories,
            "pass_counts": pass_counts,
            "evidence": evidence,
        }, indent=2, ensure_ascii=False) + "\n",
    )
    log("manifest-v2 written: %d pilot + %d held-out tasks, checksum %s" % (len(pilot_tasks), len(selected), manifest["checksum"]))
    return 0 if len(selected) == HELDOUT_TARGET else 2


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--work", required=True, help="scratch directory for patches, logs and validation output")
    parser.add_argument("--api-cache", required=True, help="GitHub API cache directory (shared with the pilot selection)")
    parser.add_argument("--clones", required=True, help="directory of bare clones (shared with the pilot selection)")
    parser.add_argument("--pilot-manifest", default=os.path.join(_HERE, "manifest.json"))
    parser.add_argument("--out", default=_HERE, help="directory that receives manifest-v2.json and rejected-v2.jsonl")
    parser.add_argument("--resume", action="store_true", help="reuse validation results already in the work directory")
    parser.add_argument("--refresh", action="store_true", help="ignore the GitHub API cache")
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args(argv)
    if args.jobs not in (1, 2):
        parser.error("--jobs must be 1 or 2 to stay within the benchmark memory budget")
    return select(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
