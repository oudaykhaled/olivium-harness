#!/usr/bin/env python3
"""Benchmark v3 task selection (PROTOCOL-v3.md, "Repository pool", "Task rules", "Walk").

Commands:
  population  take the one GitHub search snapshot of the repository population
  walk        walk the population in seeded order, validate in Docker, write the pool
  ahead       optional helper: pre-computes Docker validations further down the order
  report      counts per rule, repository and language from the walk log
  selftest    build and validate one known task (development data) with the v3 recipes
  gold-check  grade the real fix of every accepted task through the scoring grader
              (T5, change log of 2026-11-11, gold patch graded); read-only on the walk log
  rewind      drop the walk log from one repository on, keeping a copy, so the walk
              replays it from the caches under an amended rule (walk must be stopped)

Read-only GitHub access (`gh api -X GET` and GraphQL queries), git clones without a
checkout, and Docker. Nothing from a candidate repository runs on the host. Every
candidate considered is one line of the walk log with the protocol rule id.

This directory holds select.py, whose name shadows a standard library module that
subprocess imports, so the directory is dropped from sys.path before anything else.
"""

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:] = [p for p in sys.path if os.path.abspath(p or os.getcwd()) != _HERE]

import argparse  # noqa: E402
import collections  # noqa: E402
import concurrent.futures  # noqa: E402
import datetime  # noqa: E402
import hashlib  # noqa: E402
import json  # noqa: E402
import math  # noqa: E402
import re  # noqa: E402
import shutil  # noqa: E402
import subprocess  # noqa: E402,F401
import threading  # noqa: E402
import time  # noqa: E402
import urllib.parse  # noqa: E402

sys.path.append(_HERE)

import corpus_lib as v2  # noqa: E402
import v3lib as lib  # noqa: E402
from v3lib import Reject  # noqa: E402

NAME_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
PROTOCOL_PATH = os.path.join(os.path.dirname(_HERE), "PROTOCOL-v3.md")
DEV_REPOS_PATH = os.path.join(_HERE, "dev-repos-v3.txt")
MANIFEST_PATH = os.path.join(_HERE, "manifest-v3.json")


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha256_file(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def pid_alive(pid):
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, ensure_ascii=False, sort_keys=False)
        handle.write("\n")
    os.replace(tmp, path)


class Log:
    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()

    def __call__(self, message):
        line = "[%s] %s" % (utc_now(), message)
        with self.lock:
            print(line, flush=True)
            with open(self.path, "a", encoding="utf-8") as handle:
                handle.write(line + "\n")


# ---------------------------------------------------------------- GitHub access

class GitHub:
    """Read-only, cached GitHub access through gh. Waits out rate limits."""

    def __init__(self, cache_dir, log):
        self.cache_dir = cache_dir
        self.log = log
        os.makedirs(cache_dir, exist_ok=True)
        self.search_lock = threading.Lock()
        self.last_search = 0.0

    def _cache_path(self, key):
        return os.path.join(self.cache_dir, hashlib.sha256(key.encode("utf-8")).hexdigest() + ".json")

    def _load(self, key):
        path = self._cache_path(key)
        if os.path.exists(path):
            with open(path, encoding="utf-8") as handle:
                return True, json.load(handle)
        return False, None

    def _store(self, key, data):
        path = self._cache_path(key)
        tmp = "%s.%d.tmp" % (path, threading.get_ident())
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(data, handle)
        os.replace(tmp, path)

    def _wait_rate(self, resource):
        proc = v2.run(["gh", "api", "-X", "GET", "rate_limit"], check=False, timeout=60)
        wait = 60
        if proc.returncode == 0:
            try:
                info = json.loads(proc.stdout)["resources"][resource]
                if info.get("remaining", 1) == 0:
                    wait = max(5, int(info["reset"] - time.time()) + 5)
            except (ValueError, KeyError, TypeError):
                pass
        wait = min(wait, 3700)
        self.log("rate limited (%s); waiting %d s" % (resource, wait))
        time.sleep(wait)

    def _call(self, argv, resource):
        last = ""
        for attempt in range(8):
            proc = v2.run(argv, check=False, timeout=180)
            if proc.returncode == 0:
                return proc.stdout
            text = (proc.stderr or "") + (proc.stdout or "")[:500]
            last = text.strip()[:300]
            lowered = text.lower()
            if "404" in text and "not found" in lowered:
                return None
            if "http 451" in lowered or "repository access blocked" in lowered or "http 410" in lowered:
                return None
            if "rate limit" in lowered or "abuse" in lowered or "http 429" in lowered:
                self._wait_rate(resource)
                continue
            if "http 422" in lowered or "http 400" in lowered or lowered.startswith("graphql:") or "\ngraphql:" in lowered:
                break  # a request GitHub will never answer; retrying does not help
            time.sleep(min(60, 3 * (attempt + 1)))
        raise RuntimeError("gh call failed (%s): %s" % (" ".join(argv[:4]), last))

    def get(self, endpoint, resource="core"):
        found, data = self._load(endpoint)
        if found:
            return data
        if resource == "search":
            with self.search_lock:
                gap = time.time() - self.last_search
                if gap < 2.2:
                    time.sleep(2.2 - gap)
                self.last_search = time.time()
                out = self._call(["gh", "api", "-X", "GET", endpoint], resource)
        else:
            out = self._call(["gh", "api", "-X", "GET", endpoint], resource)
        data = None if out is None else json.loads(out)
        self._store(endpoint, data)
        return data

    def graphql(self, query, variables):
        key = "graphql\n" + query + "\n" + json.dumps(variables, sort_keys=True)
        found, data = self._load(key)
        if found:
            return data
        argv = ["gh", "api", "graphql", "-f", "query=" + query]
        for name, value in sorted(variables.items()):
            argv += ["-F" if isinstance(value, int) else "-f", "%s=%s" % (name, value)]
        out = self._call(argv, "graphql")
        data = None if out is None else json.loads(out)
        self._store(key, data)
        return data


# ---------------------------------------------------------------- population

def search_query(language, licence, low, high, created=None):
    query = "language:%s license:%s stars:%d..%d archived:false fork:false is:public pushed:>=%s" % (
        language, licence, low, high, lib.PUSHED_AFTER)
    if created:
        query += " created:%s..%s" % created
    return query


def search_page(gh, query, page):
    endpoint = "search/repositories?q=%s&per_page=100&page=%d" % (urllib.parse.quote(query, safe=""), page)
    return gh.get(endpoint, resource="search") or {}


def split_dates(start, end):
    a = datetime.date.fromisoformat(start)
    b = datetime.date.fromisoformat(end)
    mid = a + (b - a) // 2
    return (start, mid.isoformat()), ((mid + datetime.timedelta(days=1)).isoformat(), end)


def collect_population(gh, star_ranges, log):
    leaves, items = [], {}

    def leaf(language, licence, low, high, created=None):
        query = search_query(language, licence, low, high, created)
        first = search_page(gh, query, 1)
        total = first.get("total_count", 0)
        if total > 1000:
            if low < high:
                mid = (low + high) // 2
                leaf(language, licence, low, mid, created)
                leaf(language, licence, mid + 1, high, created)
                return
            span = created or ("2008-01-01", datetime.date.today().isoformat())
            if span[0] < span[1]:
                one, two = split_dates(*span)
                leaf(language, licence, low, high, one)
                leaf(language, licence, low, high, two)
                return
        got = list(first.get("items", []))
        incomplete = bool(first.get("incomplete_results"))
        for page in range(2, min(10, int(math.ceil(total / 100.0))) + 1):
            data = search_page(gh, query, page)
            got.extend(data.get("items", []))
            incomplete = incomplete or bool(data.get("incomplete_results"))
        for item in got:
            name = item.get("full_name") or ""
            if not NAME_RE.match(name):
                continue
            items[name.lower()] = {
                "full_name": name,
                "stars": item.get("stargazers_count", 0),
                "language": item.get("language"),
                "license": (item.get("license") or {}).get("spdx_id"),
                "archived": bool(item.get("archived")),
                "fork": bool(item.get("fork")),
                "default_branch": item.get("default_branch"),
                "pushed_at": item.get("pushed_at"),
            }
        leaves.append({"query": query, "total_count": total, "items": len(got), "incomplete_results": incomplete})

    for language in lib.LANGUAGES:
        for licence in lib.LICENCES_SEARCH:
            for low, high in star_ranges:
                leaf(language, licence, low, high)
            log("population: %s %s done, %d distinct so far, %d queries" % (language, licence, len(items), len(leaves)))
    return leaves, items


def cmd_population(args):
    v3 = os.path.abspath(args.v3)
    log = Log(os.path.join(v3, "select.log"))
    gh = GitHub(os.path.join(v3, "work", "api-cache"), log)
    out = os.path.join(v3, "population.json" if args.phase == "base" else "population-f1.json")
    if os.path.exists(out):
        log("population snapshot already exists, not refreshed: %s" % out)
        return 0
    if args.phase == "base":
        ranges = [lib.STARS]
    else:
        ranges = [(lib.FALLBACK_STARS[0], lib.STARS[0] - 1), (lib.STARS[1] + 1, lib.FALLBACK_STARS[1])]
    started = utc_now()
    leaves, items = collect_population(gh, ranges, log)
    repos = sorted(items.values(), key=lambda r: lib.repo_key(r["full_name"]))
    for record in repos:
        record["key"] = lib.repo_key(record["full_name"])
    write_json(out, {
        "taken_from": started, "taken_to": utc_now(), "phase": args.phase, "star_ranges": ranges,
        "languages": lib.LANGUAGES, "licences": lib.LICENCES_SEARCH, "pushed_after": lib.PUSHED_AFTER,
        "seed": lib.SEED, "queries": leaves, "repositories": repos,
    })
    log("population written: %d repositories, %d leaf queries, sha256 %s" % (len(repos), len(leaves), sha256_file(out)))
    return 0


# ---------------------------------------------------------------- static evaluation

PR_REFS_QUERY = """query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { %s } }"""
PR_REF_FIELD = "p%d: pullRequest(number: %d) { closingIssuesReferences(first: 10) { nodes { number repository { nameWithOwner } } } }"


class RepoWork:
    """Everything the walk needs about one repository; also used by the prefetcher."""

    def __init__(self, ctx, record):
        self.ctx = ctx
        self.record = record
        self.full_name = record["full_name"]
        self.repo = PartialRepo(self.full_name, ctx.clones)
        self._pulls = None
        self._refs = None
        self.graph_error = None

    def pulls(self):
        if self._pulls is not None:
            return self._pulls
        gh, branch = self.ctx.gh, self.record["default_branch"] or "main"
        found, page = [], 1
        while page <= 50:
            endpoint = "repos/%s/pulls?state=closed&base=%s&sort=updated&direction=desc&per_page=100&page=%d" % (
                self.full_name, urllib.parse.quote(branch, safe=""), page)
            items = gh.get(endpoint)
            if items is None:
                self._pulls = None
                raise Reject("R2", "repository_unavailable")
            if not items:
                break
            stop = False
            for pr in items:
                if (pr.get("updated_at") or "") < lib.MERGED_FROM:
                    stop = True
                    continue
                if pr.get("merged_at") and pr["merged_at"] >= lib.MERGED_FROM:
                    found.append(pr)
            if stop or len(items) < 100:
                break
            page += 1
        found.sort(key=lambda p: (p["merged_at"], p["number"]), reverse=True)
        self._pulls = found
        return found

    def graph_refs(self):
        if self._refs is not None:
            return self._refs
        owner, name = self.full_name.split("/", 1)
        refs = {}
        numbers = [pr["number"] for pr in self.pulls()]
        for start in range(0, len(numbers), 40):
            chunk = numbers[start:start + 40]
            query = PR_REFS_QUERY % " ".join(PR_REF_FIELD % (n, n) for n in chunk)
            try:
                data = self.ctx.gh.graphql(query, {"owner": owner, "name": name}) or {}
            except RuntimeError as exc:
                # Recorded by the walk: these pull requests are judged by closing keywords only.
                self.graph_error = str(exc)[:200]
                data = {}
            repo_data = ((data.get("data") or {}).get("repository") or {})
            for n in chunk:
                nodes = (((repo_data.get("p%d" % n) or {}).get("closingIssuesReferences") or {}).get("nodes") or [])
                refs[n] = [node["number"] for node in nodes
                           if ((node.get("repository") or {}).get("nameWithOwner") or "").lower() == self.full_name.lower()]
        self._refs = refs
        return refs

    def linked_issues(self, pr):
        ordered = []
        for number in v2.closing_issue_refs(self.full_name, pr.get("body")) + self.graph_refs().get(pr["number"], []):
            if number not in ordered:
                ordered.append(number)
        return ordered

    def issue_checks(self, pr):
        """[(issue_number, issue or None, failure Reject or None)] in link order."""
        out = []
        for number in self.linked_issues(pr):
            issue = self.ctx.gh.get("repos/%s/issues/%d" % (self.full_name, number))
            failure = None
            if issue is None:
                failure = Reject("T2", "linked_issue_not_found", {"issue": number})
            elif issue.get("pull_request"):
                failure = Reject("T2", "linked_ref_is_pull_request", {"issue": number})
            elif not (issue.get("html_url") or "").lower().startswith(("https://github.com/%s/issues/" % self.full_name).lower()):
                failure = Reject("T2", "linked_issue_moved", {"issue": number})
            elif (issue.get("created_at") or "") < lib.ISSUE_FROM:
                failure = Reject("T1", "issue_before_cutoff", {"issue": number, "created_at": issue.get("created_at")})
            else:
                words = v2.prose_word_count(issue.get("body"))
                if words < lib.MIN_PROSE_WORDS:
                    failure = Reject("T2", "too_little_prose", {"issue": number, "words": words})
            out.append((number, issue, failure))
        return out

    def pr_files(self, pr):
        files, page = [], 1
        while page <= 30:
            items = self.ctx.gh.get("repos/%s/pulls/%d/files?per_page=100&page=%d" % (self.full_name, pr["number"], page)) or []
            files.extend(items)
            if len(items) < 100:
                break
            page += 1
        return files

    def static(self, pr, used_issues, min_source_files, api_only=False):
        """Rules up to R6, in the protocol's order. Returns a candidate dict or raises Reject.

        api_only stops before git (the prefetcher only warms the API cache).
        """
        links = self.linked_issues(pr)
        if not links:
            raise Reject("T2", "no_linked_issue")
        checks = self.issue_checks(pr)
        usable = [(n, issue) for n, issue, failure in checks if failure is None]
        if not usable:
            raise next(failure for _n, _i, failure in checks if failure is not None)
        fresh = [(n, issue) for n, issue in usable if (self.full_name.lower(), n) not in used_issues]
        if not fresh:
            raise Reject("T2", "issue_reused", {"issue": usable[0][0]})
        number, issue = fresh[0]
        files = self.pr_files(pr)
        facts = lib.shape(lib.api_entries(files))
        try:
            lib.check_t3(facts)
        except Reject as exc:
            exc.detail["stage"] = "api"
            raise
        text = (issue.get("title") or "") + "\n" + (issue.get("body") or "")
        if lib.names_a_file(text, facts["code_files"]):
            raise Reject("T4", "issue_names_fixed_file", {"stage": "api"})
        commits = self.ctx.gh.get("repos/%s/pulls/%d/commits?per_page=100" % (self.full_name, pr["number"])) or []
        if api_only:
            return None
        # Git: partial bare clone, base commit, exact numstat.
        self.repo.ensure_clone()
        fix_sha = pr.get("merge_commit_sha")
        if not fix_sha or not self.repo.ensure_commit(fix_sha):
            raise Reject("T3", "merge_commit_unavailable")
        pr_view = dict(pr, _files=files, _commits=len(commits))
        try:
            base_sha, base_how = v2.derive_base(self.repo, self.ctx.gh, pr_view, fix_sha)
        except v2.Rejection as exc:
            raise Reject("T3", exc.reason, exc.detail)
        if not self.repo.ensure_commit(base_sha):
            raise Reject("T3", "base_commit_unavailable")
        facts = lib.shape(self.repo.numstat(base_sha, fix_sha))
        try:
            lib.check_t3(facts)
        except Reject as exc:
            exc.detail["stage"] = "git"
            raise
        if lib.names_a_file(text, facts["code_files"]):
            raise Reject("T4", "issue_names_fixed_file", {"stage": "git"})
        paths = self.repo.tree_paths(base_sha)
        sources = sum(1 for p in paths if lib.is_source_file(p))
        if sources < min_source_files:
            raise Reject("R5", "too_few_source_files", {"source_files": sources})
        root_paths = set(paths)
        recipe = lib.recipe_for(self.record["language"], lambda path: self.repo.show(base_sha, path), root_paths)
        owner, name = self.full_name.split("/", 1)
        return {
            "task_id": lib.task_id_for(self.full_name, pr["number"]),
            "repo": self.full_name,
            "repo_url": "https://github.com/%s" % self.full_name,
            "license": self.record["license"],
            "language": self.record["language"],
            "stars": self.record["stars"],
            "pr_number": pr["number"],
            "pr_url": "https://github.com/%s/pull/%d" % (self.full_name, pr["number"]),
            "issue_number": number,
            "issue_url": "https://github.com/%s/issues/%d" % (self.full_name, number),
            "issue_sha256": v2.sha256_text(v2.issue_markdown(issue.get("title"), issue.get("body"))),
            "issue_prose_words": v2.prose_word_count(issue.get("body")),
            "issue_created_at": issue.get("created_at"),
            "base_sha": base_sha,
            "base_derivation": base_how,
            "fix_sha": fix_sha,
            "merged_at": pr["merged_at"],
            "gold_files": facts["gold_files"],
            "test_files": facts["test_files"],
            "code_files_count": len(facts["code_files"]),
            "code_lines": facts["code_lines"],
            "source_files_count": sources,
            "pr_commits": sorted({c["sha"] for c in commits if isinstance(c, dict) and c.get("sha")}),
            "recipe": recipe,
            "markdown_files_count": sum(1 for p in paths if v2.MARKDOWN_RE.search(p)),
        }


class PartialRepo(v2.Repo):
    """A bare clone without blobs; git fetches blobs on demand. No checkout, no hooks."""

    def ensure_clone(self):
        if os.path.isdir(self.path):
            return
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        tmp = self.path + ".partial"
        if os.path.isdir(tmp):
            shutil.rmtree(tmp)
        v2.run(v2.GIT + ["clone", "--quiet", "--bare", "--filter=blob:none", self.url, tmp], timeout=1800)
        os.replace(tmp, self.path)


# ---------------------------------------------------------------- walk

class Context:
    def __init__(self, args):
        self.v3 = os.path.abspath(args.v3)
        self.work = os.path.join(self.v3, "work")
        self.clones = os.path.join(self.work, "clones")
        self.log = Log(os.path.join(self.v3, "select.log"))
        self.gh = GitHub(os.path.join(self.work, "api-cache"), self.log)
        self._locks = collections.defaultdict(threading.Lock)
        self._locks_guard = threading.Lock()

    def clone_lock(self, name):
        with self._locks_guard:
            return self._locks[name.lower()]

    def jobs(self):
        return 2

    def docker_gate(self):
        """Hold Docker work while a paid run of the benchmark is in progress on this machine.

        Not a protocol rule: a courtesy so selection load never causes infra errors in a
        paid run. Checked before each candidate's Docker validation.
        """
        quiet = 0
        while not lib.docker_answers():
            # Change log of 2026-11-11 (walk safety): never add work to a Docker daemon that does not answer.
            if quiet % 600 == 0:
                self.log("the Docker daemon does not answer; Docker validation waits")
            time.sleep(30)
            quiet += 30
        waited = 0
        while True:
            # Any copy of the runner (the rehearsal's snapshot or bench/value/run.py itself).
            proc = v2.run(["pgrep", "-f", "run.py run .*--paid"], check=False, timeout=30)
            busy = proc.returncode == 0 and proc.stdout.strip()
            if not busy:
                if waited:
                    self.log("paid run finished; Docker validation resumes after %d s" % waited)
                return
            if waited % 600 == 0:
                self.log("a paid benchmark run is in progress; Docker validation waits")
            time.sleep(60)
            waited += 60


def read_dev_repos(path):
    names = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.split("#", 1)[0].strip()
            if line:
                names.append(line.lower())
    return names


def gold_check_saved(ctx, task_id, test_files, test_command, validated, record_path):
    """The gold-grading step of T5 for a validation record written before it existed.

    Updates the record: accepted with the evidence added, or rejected (T5
    gold_not_gradeable) with the earlier record kept under validated_before_gold_grade.
    The dependency image is kept either way, as evidence. Raises Reject on rejection.
    """
    task_dir = os.path.join(ctx.work, "tasks", task_id)
    for name in ("test.patch", "gold.patch"):
        if not os.path.isfile(os.path.join(task_dir, name)):
            raise RuntimeError("%s: %s is missing; the gold patch cannot be graded" % (task_id, name))
    grade_task = {
        "test_files": test_files, "test_command": test_command, "lint_command": validated["lint_command"],
        "deps_image": lib.image_name(task_id), "f2p": validated["f2p"], "p2p": validated["p2p"],
    }
    ctx.docker_gate()
    try:
        evidence = lib.check_gold_grade(task_id, task_dir, grade_task, ctx.log)
    except Reject as exc:
        write_json(record_path, {"status": "rejected", "rule": exc.rule, "reason": exc.reason, "detail": exc.detail,
                                 "validated_before_gold_grade": validated})
        raise
    validated = dict(validated, evidence=dict(validated["evidence"], gold_grade=evidence))
    write_json(record_path, {"status": "accepted", "validated": validated})
    return validated


class Walk:
    def __init__(self, ctx, args):
        self.ctx = ctx
        self.args = args
        self.walk_path = os.path.join(ctx.v3, "walk.jsonl")
        self.dev_repos = read_dev_repos(args.dev_repos)
        self.records = []
        self.accepted = []
        self.seq = 0
        self.stop_file = os.path.join(ctx.v3, "STOP")
        self.on_accept = None
        self._resume()

    def _resume(self):
        if not os.path.exists(self.walk_path):
            return
        with open(self.walk_path, encoding="utf-8") as handle:
            lines = [json.loads(line) for line in handle if line.strip()]
        keep = 0
        for index, record in enumerate(lines):
            if record["kind"] in ("repo_done", "phase", "walk_end"):
                keep = index + 1
        dropped = len(lines) - keep
        lines = lines[:keep]
        with open(self.walk_path + ".tmp", "w", encoding="utf-8") as handle:
            for record in lines:
                handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
        os.replace(self.walk_path + ".tmp", self.walk_path)
        self.records = lines
        self.seq = max([r.get("seq", 0) for r in lines] or [0])
        self.accepted = [r["task"] for r in lines if r["kind"] == "candidate" and r["rule"] == "accepted"]
        self.ctx.log("resumed walk: %d records kept, %d dropped (unfinished repository), %d accepted" % (keep, dropped, len(self.accepted)))

    def write(self, record):
        self.seq += 1
        record = dict(record, seq=self.seq, ts=utc_now())
        self.records.append(record)
        with open(self.walk_path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
        return record

    def done(self, phase):
        return {r["repo"].lower() for r in self.records if r["kind"] == "repo_done" and r["phase"] == phase}

    def phase_marked(self, phase):
        return any(r["kind"] == "phase" and r["phase"] == phase for r in self.records)

    def per_repo(self):
        counts = collections.Counter()
        for task in self.accepted:
            counts[task["repo"].lower()] += 1
        return counts

    def used_issues(self):
        return {(t["repo"].lower(), t["issue_number"]) for t in self.accepted}

    # ---------------------------------------------------------- one candidate through T5

    def validate(self, cand, phase):
        ctx = self.ctx
        record_path = os.path.join(ctx.work, "validation", cand["task_id"] + ".json")
        if os.path.exists(record_path):
            with open(record_path, encoding="utf-8") as handle:
                saved = json.load(handle)
            ctx.log("reusing validation for %s" % cand["task_id"])
            if saved["status"] == "rejected":
                raise Reject(saved["rule"], saved["reason"], saved.get("detail"))
            validated = saved["validated"]
            if "gold_grade" not in (validated.get("evidence") or {}):
                # Validated before the gold-grading step existed: run that step now.
                validated = gold_check_saved(ctx, cand["task_id"], cand["test_files"],
                                             cand["recipe"]["test_command"], validated, record_path)
            return validated
        repo = PartialRepo(cand["repo"], ctx.clones)
        show = lambda path: repo.show(cand["base_sha"], path)  # noqa: E731
        ctx.docker_gate()
        try:
            validated = lib.validate(repo, cand, cand["recipe"], ctx.work, ctx.jobs(), ctx.log, show)
        except Reject as exc:
            write_json(record_path, {"status": "rejected", "rule": exc.rule, "reason": exc.reason, "detail": exc.detail})
            lib.remove_image(cand["task_id"])
            raise
        write_json(record_path, {"status": "accepted", "validated": validated})
        return validated

    # ---------------------------------------------------------- one repository

    def process_repo(self, record, phase, cap, min_sources, only=None):
        """Walk one repository. only: list of PR numbers to (re)consider (fallbacks F2, F3)."""
        ctx = self.ctx
        name = record["full_name"]
        work = RepoWork(ctx, record)
        base = {"kind": "candidate", "phase": phase, "repo": name, "language": record["language"]}
        owner = name.split("/", 1)[0].lower()
        if owner in lib.EXCLUDED_OWNERS or name.lower() in self.dev_repos:
            self.write(dict(base, kind="repo", rule="R4", reason="excluded_owner" if owner in lib.EXCLUDED_OWNERS else "dev_repos_v3"))
            return
        if record["archived"] or record["fork"] or record["license"] not in lib.LICENCES_SPDX or record["language"] not in lib.LANGUAGES:
            self.write(dict(base, kind="repo", rule="R2" if record["language"] in lib.LANGUAGES else "R1", reason="snapshot_fields"))
            return
        try:
            pulls = work.pulls()
        except Reject as exc:
            self.write(dict(base, kind="repo", rule=exc.rule, reason=exc.reason))
            return
        if not pulls:
            self.write(dict(base, kind="repo", rule="T1", reason="no_merged_pr_in_window"))
            return
        considered = 0
        try:
            work.graph_refs()
        except RuntimeError:
            pass
        if work.graph_error:
            self.write(dict(base, kind="repo", rule="infra", reason="linked_issue_field_unavailable",
                            detail={"error": work.graph_error, "effect": "closing keywords only for this repository"}))
        t5_streak = 0
        for index, pr in enumerate(pulls):
            if only is not None and pr["number"] not in only:
                continue
            if self.per_repo()[name.lower()] >= cap:
                self.write(dict(base, kind="repo", rule="T6", reason="repository_cap_reached",
                                detail={"cap": cap, "not_considered": len(pulls) - index}))
                break
            if t5_streak >= lib.T5_STREAK_LIMIT:
                # Change log of 2026-11-11 (walk cost): stop a repository whose candidates keep failing in Docker.
                self.write(dict(base, kind="repo", rule="T5", reason="repository_t5_streak",
                                detail={"limit": lib.T5_STREAK_LIMIT, "not_considered": len(pulls) - index}))
                break
            if len(self.accepted) >= lib.POOL_TARGET:
                break
            considered += 1
            entry = dict(base, pr=pr["number"], task_id=lib.task_id_for(name, pr["number"]), merged_at=pr["merged_at"])
            try:
                cand = work.static(pr, self.used_issues(), min_sources)
                entry["recipe_kind"] = cand["recipe"]["kind"]
                entry["source_files"] = cand["source_files_count"]
                ctx.log("validating %s (%s, %s)" % (cand["task_id"], cand["recipe"]["kind"], phase))
                validated = self.validate(cand, phase)
            except Reject as exc:
                self.write(dict(entry, rule=exc.rule, reason=exc.reason, detail=exc.detail))
                if exc.rule == "T5":
                    t5_streak += 1
                continue
            except (RuntimeError, subprocess.SubprocessError, OSError, ValueError) as exc:
                # Infrastructure trouble (network, git, gh) is not a rule; record and continue.
                self.write(dict(entry, rule="infra", reason=type(exc).__name__, detail={"error": str(exc)[:300]}))
                continue
            t5_streak = 0
            task = manifest_task(cand, validated, phase, len(self.accepted) + 1)
            self.accepted.append(task)
            self.write(dict(entry, rule="accepted", reason="all_rules_pass", task=task))
            ctx.log("accepted %s (%d in pool)" % (cand["task_id"], len(self.accepted)))
            if self.on_accept is not None:
                self.on_accept()

    def finish_repo(self, record, phase):
        self.write({"kind": "repo_done", "phase": phase, "repo": record["full_name"],
                    "accepted_in_repo": self.per_repo()[record["full_name"].lower()]})

    # ---------------------------------------------------------- repository claims (walk and look-ahead)

    def claim_path(self, name):
        digest = hashlib.sha256(name.lower().encode("utf-8")).hexdigest()[:32]
        return os.path.join(self.ctx.work, "claims", digest)

    def claim(self, name, role, wait):
        """Claim a repository for this process ("walk" or "ahead").

        The look-ahead helper only fills the shared Docker validation cache. The walk
        processes every repository itself, in order, and writes the walk log and the pool;
        it waits while the helper is working on the same repository. Returns True when the
        caller may process the repository.
        """
        path = self.claim_path(name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        waited = 0
        while True:
            try:
                fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
            except FileExistsError:
                try:
                    with open(path, encoding="utf-8") as handle:
                        info = json.load(handle)
                except (OSError, ValueError):
                    time.sleep(1)  # the other process is still writing it
                    continue
                if info.get("role") == role:
                    return True
                if os.path.exists(path + ".done"):
                    return wait
                if not pid_alive(info.get("pid")):
                    os.remove(path)
                    continue
                if not wait:
                    return False
                if waited % 600 == 0:
                    self.ctx.log("waiting for the look-ahead helper to finish %s" % name)
                time.sleep(15)
                waited += 15
                continue
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump({"role": role, "pid": os.getpid(), "repo": name}, handle)
            return True

    def mark_done(self, name, role):
        write_json(self.claim_path(name) + ".done", {"role": role, "pid": os.getpid(), "repo": name})

    def stop_requested(self):
        return os.path.exists(self.stop_file)

    # ---------------------------------------------------------- phases

    def walk_population(self, population, phase, cap, min_sources):
        done = self.done(phase)
        if not self.phase_marked(phase):
            self.write({"kind": "phase", "phase": phase, "repo": "", "cap": cap, "min_source_files": min_sources,
                        "population_sha256": population["sha256"], "repositories": len(population["repositories"])})
        prefetch = Prefetcher(self.ctx, [r for r in population["repositories"] if r["full_name"].lower() not in done],
                              self.dev_repos, min_sources)
        prefetch.start()
        try:
            for record in population["repositories"]:
                if record["full_name"].lower() in done:
                    continue
                if len(self.accepted) >= lib.POOL_TARGET:
                    return "target_reached"
                if self.stop_requested():
                    return "stopped"
                prefetch.advance(record["full_name"])
                self.claim(record["full_name"], "walk", wait=True)
                self.process_repo(record, phase, cap, min_sources)
                self.finish_repo(record, phase)
                self.mark_done(record["full_name"], "walk")
        finally:
            prefetch.stop()
        return "exhausted"

    def fallback_f2(self, populations):
        phase = "F2"
        if not self.phase_marked(phase):
            self.write({"kind": "phase", "phase": phase, "repo": "", "cap": lib.FALLBACK_MAX_PER_REPO})
        done = self.done(phase)
        by_name = {}
        for pop in populations:
            for record in pop["repositories"]:
                by_name[record["full_name"].lower()] = record
        order = []
        for task in self.accepted:
            if task["repo"].lower() not in order:
                order.append(task["repo"].lower())
        for name in order:
            if len(self.accepted) >= lib.POOL_MINIMUM or self.stop_requested():
                break
            if name in done or self.per_repo()[name] != lib.MAX_PER_REPO:
                continue
            record = by_name[name]
            seen = {r.get("pr") for r in self.records if r["kind"] == "candidate" and r["repo"].lower() == name}
            work = RepoWork(self.ctx, record)
            remaining = [pr["number"] for pr in work.pulls() if pr["number"] not in seen]
            self.process_repo(record, phase, lib.FALLBACK_MAX_PER_REPO, lib.MIN_SOURCE_FILES, only=set(remaining))
            self.finish_repo(record, phase)

    def fallback_f3(self, populations, cap):
        phase = "F3"
        if not self.phase_marked(phase):
            self.write({"kind": "phase", "phase": phase, "repo": "", "cap": cap, "min_source_files": lib.FALLBACK_MIN_SOURCE_FILES})
        done = self.done(phase)
        by_name = {}
        for pop in populations:
            for record in pop["repositories"]:
                by_name[record["full_name"].lower()] = record
        targets = collections.OrderedDict()
        for r in self.records:
            if (r["kind"] == "candidate" and r["rule"] == "R5"
                    and lib.FALLBACK_MIN_SOURCE_FILES <= r.get("detail", {}).get("source_files", 0) < lib.MIN_SOURCE_FILES):
                targets.setdefault(r["repo"].lower(), set()).add(r["pr"])
        for name, prs in targets.items():
            if len(self.accepted) >= lib.POOL_MINIMUM or self.stop_requested():
                break
            if name in done:
                continue
            self.process_repo(by_name[name], phase, cap, lib.FALLBACK_MIN_SOURCE_FILES, only=prs)
            self.finish_repo(by_name[name], phase)


class Prefetcher(threading.Thread):
    """Warms the API cache and clones for the next repositories in walk order.

    It makes no decision: the walk re-reads everything from the cache and applies
    the rules itself, in order. Its errors are ignored (the walk will meet them).
    """

    AHEAD = 25

    def __init__(self, ctx, records, dev_repos, min_sources):
        threading.Thread.__init__(self, daemon=True)
        self.ctx = ctx
        self.records = records
        self.dev_repos = dev_repos
        self.min_sources = min_sources
        self.position = 0
        self.index = {r["full_name"]: i for i, r in enumerate(records)}
        self.cond = threading.Condition()
        self.halt = False

    def advance(self, name):
        with self.cond:
            if name in self.index:
                self.position = max(self.position, self.index[name])
            self.cond.notify_all()

    def stop(self):
        with self.cond:
            self.halt = True
            self.cond.notify_all()

    def run(self):
        for index, record in enumerate(self.records):
            with self.cond:
                while not self.halt and index > self.position + self.AHEAD:
                    self.cond.wait(5)
                if self.halt:
                    return
            owner = record["full_name"].split("/", 1)[0].lower()
            if owner in lib.EXCLUDED_OWNERS or record["full_name"].lower() in self.dev_repos:
                continue
            try:
                work = RepoWork(self.ctx, record)
                for pr in work.pulls()[:60]:
                    if self.halt:
                        return
                    try:
                        work.static(pr, set(), self.min_sources, api_only=True)
                    except Reject:
                        pass
            except Exception:  # noqa: BLE001 - warming only; the walk meets real errors itself
                continue


def manifest_task(cand, validated, phase, pool_index):
    recipe = cand["recipe"]
    return {
        "task_id": cand["task_id"],
        "repo": cand["repo"],
        "repo_url": cand["repo_url"],
        "license": cand["license"],
        "language": cand["language"].lower(),
        "pr_url": cand["pr_url"],
        "issue_url": cand["issue_url"],
        "issue_number": cand["issue_number"],
        "issue_sha256": cand["issue_sha256"],
        "issue_created_at": cand["issue_created_at"],
        "base_sha": cand["base_sha"],
        "fix_sha": cand["fix_sha"],
        "merged_at": cand["merged_at"],
        "gold_files": cand["gold_files"],
        "test_files": cand["test_files"],
        "f2p": validated["f2p"],
        "p2p": validated["p2p"],
        "test_command": recipe["test_command"],
        "lint_command": validated["lint_command"],
        "deps_image": lib.image_name(cand["task_id"]),
        "markdown_files_count": cand["markdown_files_count"],
        "held_out": True,
        "pool_index": pool_index,
        "selection_phase": phase,
        "recipe_kind": recipe["kind"],
        "base_image": recipe["base_image"],
        "toolchain_nondefault": bool(recipe["toolchain_nondefault"] or validated.get("pytest_added")),
        "source_files_count": cand["source_files_count"],
        "code_files_count": cand["code_files_count"],
        "code_lines": cand["code_lines"],
        "full_suite_green_at_base": validated["census"]["full_suite_green_at_base"],
        **wall_times(validated["evidence"]),
    }


def wall_times(evidence):
    """Manifest wall times (change log of 2026-11-11, integration 2 repair round; no rule uses them)."""
    return {
        "t5_max_test_seconds": max([w for side in ("base", "fix")
                                    for w in (evidence.get("test_wall_seconds") or {}).get(side) or []] or [None]),
        "gold_grade_test_seconds": (evidence.get("gold_grade") or {}).get("test_wall_seconds"),
    }


def with_wall_times(ctx, task):
    """A task accepted before the wall-time fields existed has none in its walk record; take them
    from its validation record, which gold-check updated. A missing record gives None, not a guess."""
    if "t5_max_test_seconds" in task and "gold_grade_test_seconds" in task:
        return task
    path = os.path.join(ctx.work, "validation", task["task_id"] + ".json")
    evidence = {}
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as handle:
            record = json.load(handle)
        if record.get("status") == "accepted":
            evidence = record["validated"]["evidence"]
    return dict(task, **wall_times(evidence))


def load_population(v3, name):
    path = os.path.join(v3, name)
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    data["sha256"] = sha256_file(path)
    return data


def t4_share(records):
    """Candidates that reached T4 (first failing rule after T3, or accepted) and the share T4 rejected."""
    candidates = [r for r in records if r["kind"] == "candidate"]
    reached = [r for r in candidates if r["rule"] not in ("T1", "T2", "T3")]
    rejected = sum(1 for r in candidates if r["rule"] == "T4")
    return {"reached_t4": len(reached), "rejected_by_t4": rejected,
            "share": round(rejected / float(len(reached)), 4) if reached else None,
            "definition": "candidates whose first failing rule is not T1, T2 or T3 (accepted included)"}


def write_outputs(walk, status, populations, fallbacks):
    ctx = walk.ctx
    pool = [with_wall_times(ctx, task) for task in walk.accepted]
    protocol_sha = sha256_file(PROTOCOL_PATH)
    selection = {
        "protocol": "PROTOCOL-v3.md",
        "protocol_sha256": protocol_sha,
        "status": status,
        "seed": lib.SEED,
        "model_cutoff": lib.CUTOFF,
        "dev_repos_v3_sha256": sha256_file(walk.args.dev_repos),
        "population_sha256": {p["phase"]: p["sha256"] for p in populations},
        "rules": {k: v for k, v in sorted(lib.RULE_TEXT.items())},
        "parameters": {
            "stars": list(lib.STARS), "licences": lib.LICENCES_SPDX, "languages": lib.LANGUAGES,
            "merged_from": lib.MERGED_FROM, "issue_from": lib.ISSUE_FROM, "min_source_files": lib.MIN_SOURCE_FILES,
            "fix_shape": lib.T3, "max_per_repository": lib.MAX_PER_REPO, "pool_target": lib.POOL_TARGET,
            "pool_minimum": lib.POOL_MINIMUM, "floor": lib.POOL_FLOOR, "test_timeout_seconds": lib.TEST_TIMEOUT,
            "repeats_per_side": lib.REPEATS, "t5_streak_limit": lib.T5_STREAK_LIMIT, "pins": lib.PINS,
            "gold_grade": "the real fix graded by grade.sh with protection on, test limit %d s" % lib.gold_grade_limit(),
        },
        "t4_share": t4_share(walk.records),
        "census": {"pool_tasks": len(pool),
                   "full_suite_green_at_base": sum(1 for t in pool if t["full_suite_green_at_base"])},
        "fallbacks_applied": fallbacks,
        "pool_order": "order of acceptance in the walk (repository key order, then newest merge first)",
        "pool_size": len(pool),
        "repositories": len({t["repo"] for t in pool}),
    }
    manifest = {"frozen_at": utc_now(), "checksum": "", "selection": selection, "tasks": pool}
    manifest["checksum"] = v2.manifest_checksum(manifest)
    write_json(walk.args.manifest, manifest)
    t5 = [r for r in walk.records if r["kind"] == "candidate" and (r["rule"] in ("accepted", "T5"))]
    write_json(os.path.join(ctx.v3, "candidates.json"), {
        "written_at": utc_now(), "status": status, "manifest_checksum": manifest["checksum"],
        "pool": [{"pool_index": t["pool_index"], "task_id": t["task_id"], "repo": t["repo"], "language": t["language"],
                  "recipe_kind": t["recipe_kind"], "toolchain_nondefault": t["toolchain_nondefault"],
                  "f2p": len(t["f2p"]), "p2p": len(t["p2p"]), "full_suite_green_at_base": t["full_suite_green_at_base"],
                  "selection_phase": t["selection_phase"]} for t in pool],
        "reached_docker": [{"task_id": r.get("task_id"), "repo": r["repo"], "rule": r["rule"], "reason": r["reason"],
                            "recipe_kind": r.get("recipe_kind")} for r in t5],
    })


def code_hashes():
    """SHA-256 of the protocol and of the code that applies it, for the walk log."""
    value_dir = os.path.dirname(_HERE)
    return {
        "protocol_sha256": sha256_file(PROTOCOL_PATH),
        "select_v3_sha256": sha256_file(os.path.join(_HERE, "select_v3.py")),
        "v3lib_sha256": sha256_file(os.path.join(_HERE, "v3lib.py")),
        "grade_sh_sha256": sha256_file(os.path.join(value_dir, "grade", "grade.sh")),
        "grader_sha256": sha256_file(os.path.join(value_dir, "grade", "grader.py")),
    }


def read_walk_log(v3):
    with open(os.path.join(v3, "walk.jsonl"), encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def walk_process_alive():
    proc = v2.run(["pgrep", "-f", "select_v3.py (walk|ahead) "], check=False, timeout=30)
    return [pid for pid in proc.stdout.split() if pid.strip() and int(pid) != os.getpid()] if proc.returncode == 0 else []


def cmd_gold_check(args):
    """Grade the real fix of every accepted task in the walk log through the scoring grader.

    Read-only on the walk log; writes only the tasks' validation records (accepted with
    the evidence, or rejected T5 gold_not_gradeable) and gold-check.log. Tasks whose
    record already holds the gold-grading evidence are reported, not graded again.
    """
    ctx = Context(args)
    ctx.log = Log(os.path.join(ctx.v3, "gold-check.log"))
    ctx.gh.log = ctx.log
    accepted = [r for r in read_walk_log(ctx.v3) if r["kind"] == "candidate" and r["rule"] == "accepted"]
    if args.tasks:
        wanted = set(args.tasks.split(","))
        accepted = [r for r in accepted if r["task_id"] in wanted]
    ctx.log("gold-check: %d accepted task(s), %d at a time; code %s" % (len(accepted), args.jobs, json.dumps(code_hashes(), sort_keys=True)))
    results = {}

    def one(record):
        task = record["task"]
        record_path = os.path.join(ctx.work, "validation", task["task_id"] + ".json")
        with open(record_path, encoding="utf-8") as handle:
            saved = json.load(handle)
        if saved["status"] != "accepted":
            return task["task_id"], {"status": saved["status"], "rule": saved.get("rule"), "reason": saved.get("reason"),
                                     "graded_now": False}
        if "gold_grade" in (saved["validated"].get("evidence") or {}):
            return task["task_id"], {"status": "accepted", "graded_now": False,
                                     "gold_grade": saved["validated"]["evidence"]["gold_grade"]}
        try:
            validated = gold_check_saved(ctx, task["task_id"], task["test_files"], task["test_command"],
                                         saved["validated"], record_path)
        except Reject as exc:
            return task["task_id"], {"status": "rejected", "rule": exc.rule, "reason": exc.reason, "graded_now": True,
                                     "gold_grade": exc.detail}
        except RuntimeError as exc:
            return task["task_id"], {"status": "infra", "error": str(exc)[:300], "graded_now": True}
        return task["task_id"], {"status": "accepted", "graded_now": True, "gold_grade": validated["evidence"]["gold_grade"]}

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for task_id, outcome in pool.map(one, accepted):
            results[task_id] = outcome
    ordered = [{"task_id": r["task_id"], "repo": r["repo"], "seq": r["seq"],
                "result": results[r["task_id"]]} for r in accepted]
    summary = {"written_at": utc_now(), "code": code_hashes(), "tasks": ordered,
               "rejected": [o["task_id"] for o in ordered if o["result"]["status"] == "rejected"],
               "infra": [o["task_id"] for o in ordered if o["result"]["status"] == "infra"]}
    write_json(os.path.join(ctx.v3, "gold-check.json"), summary)
    ctx.log("gold-check: %d graded solved, rejected %s, infra %s" % (
        sum(1 for o in ordered if o["result"]["status"] == "accepted"), summary["rejected"] or "none", summary["infra"] or "none"))
    return 1 if summary["infra"] else 0


def cmd_rewind(args):
    """Drop the walk log from the first record of one repository on, so that the walk
    replays that repository and every later one from the API and validation caches.

    The full log is kept as walk-before-<label>.jsonl. Refused while a walk or look-ahead
    process is alive, and unless the cut falls right after a repo_done or phase record.
    """
    v3 = os.path.abspath(args.v3)
    alive = walk_process_alive()
    if alive:
        print("a walk or look-ahead process is alive (pid %s); touch %s/STOP and wait for it to exit" % (
            ", ".join(alive), v3), file=sys.stderr)
        return 3
    if not re.match(r"^[a-z0-9][a-z0-9-]{0,40}$", args.label):
        print("--label must be lower-case letters, digits and dashes", file=sys.stderr)
        return 2
    records = read_walk_log(v3)
    name = args.repo.lower()
    cut = next((i for i, r in enumerate(records) if r["kind"] in ("candidate", "repo", "repo_done")
                and r["repo"].lower() == name), None)
    if cut is None:
        print("%s does not appear in the walk log" % args.repo, file=sys.stderr)
        return 2
    if records[cut - 1]["kind"] not in ("repo_done", "phase"):
        print("the cut at record %d does not follow a finished repository" % cut, file=sys.stderr)
        return 2
    backup = os.path.join(v3, "walk-before-%s.jsonl" % args.label)
    if os.path.exists(backup):
        print("%s exists; choose another --label" % backup, file=sys.stderr)
        return 2
    shutil.copy2(os.path.join(v3, "walk.jsonl"), backup)
    dropped = records[cut:]
    kept = records[:cut]
    seq = max([r.get("seq", 0) for r in kept] or [0]) + 1
    marker = dict({"kind": "phase", "phase": "rewind", "repo": args.repo, "seq": seq, "ts": utc_now(),
                   "label": args.label, "reason": args.reason, "dropped_records": len(dropped),
                   "dropped_accepted": [r["task_id"] for r in dropped if r["kind"] == "candidate" and r["rule"] == "accepted"],
                   "backup": os.path.basename(backup), "backup_sha256": sha256_file(backup)}, **code_hashes())
    tmp = os.path.join(v3, "walk.jsonl.tmp")
    with open(tmp, "w", encoding="utf-8") as handle:
        for record in kept + [marker]:
            handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
    os.replace(tmp, os.path.join(v3, "walk.jsonl"))
    print(json.dumps({k: marker[k] for k in ("seq", "repo", "dropped_records", "dropped_accepted", "backup", "backup_sha256")}, indent=2))
    return 0


def cmd_walk(args):
    ctx = Context(args)
    v3 = ctx.v3
    for directory in ("work", os.path.join("work", "validation"), os.path.join("work", "tasks")):
        os.makedirs(os.path.join(v3, directory), exist_ok=True)
    base = load_population(v3, "population.json")
    if base is None:
        print("no population snapshot; run the population command first", file=sys.stderr)
        return 3
    if not os.path.exists(args.dev_repos):
        print("missing %s" % args.dev_repos, file=sys.stderr)
        return 3
    walk = Walk(ctx, args)
    if not walk.phase_marked("start"):
        walk.write({"kind": "phase", "phase": "start", "repo": "", "protocol_sha256": sha256_file(PROTOCOL_PATH),
                    "dev_repos_v3_sha256": sha256_file(args.dev_repos), "dev_repos": walk.dev_repos,
                    "excluded_owners": lib.EXCLUDED_OWNERS, "population_sha256": base["sha256"]})
    else:
        # Change log of 2026-11-11 (integration 2 repair round): every restart is in the walk log.
        walk.write(dict({"kind": "phase", "phase": "resume", "repo": "", "accepted": len(walk.accepted)}, **code_hashes()))
    ctx.log("walk: %d repositories in the base population; protocol %s" % (len(base["repositories"]), sha256_file(PROTOCOL_PATH)))
    populations = [dict(base, phase="base")]
    fallbacks = []
    walk.on_accept = lambda: write_outputs(walk, "walk_in_progress", populations, fallbacks)
    result = walk.walk_population(populations[0], "base", lib.MAX_PER_REPO, lib.MIN_SOURCE_FILES)
    ctx.log("base walk: %s with %d accepted" % (result, len(walk.accepted)))
    cap = lib.MAX_PER_REPO
    if result == "exhausted" and len(walk.accepted) < lib.POOL_MINIMUM:
        f1 = load_population(v3, "population-f1.json")
        if f1 is None:
            ctx.log("fallback F1 needs population-f1.json: run `population --phase f1`, then the walk again")
            write_outputs(walk, "walk_paused_for_f1_population", populations, fallbacks)
            return 2
        populations.append(dict(f1, phase="F1"))
        fallbacks.append({"step": "F1", "accepted_before": len(walk.accepted)})
        result = walk.walk_population(populations[-1], "F1", cap, lib.MIN_SOURCE_FILES)
        fallbacks[-1].update({"result": result, "accepted_after": len(walk.accepted)})
        if result == "exhausted" and len(walk.accepted) < lib.POOL_MINIMUM:
            fallbacks.append({"step": "F2", "accepted_before": len(walk.accepted)})
            walk.fallback_f2(populations)
            cap = lib.FALLBACK_MAX_PER_REPO
            fallbacks[-1]["accepted_after"] = len(walk.accepted)
            if len(walk.accepted) < lib.POOL_MINIMUM and not walk.stop_requested():
                fallbacks.append({"step": "F3", "accepted_before": len(walk.accepted)})
                walk.fallback_f3(populations, cap)
                fallbacks[-1]["accepted_after"] = len(walk.accepted)
    if walk.stop_requested() and len(walk.accepted) < lib.POOL_MINIMUM:
        status = "walk_paused"
    elif len(walk.accepted) < lib.POOL_FLOOR:
        status = "below_floor_ask_owner"
    elif walk.stop_requested():
        status = "pool_before_pilot_stopped_for_time"
    else:
        status = "pool_before_pilot"
    write_outputs(walk, status, populations, fallbacks)
    walk.write({"kind": "walk_end", "phase": "end", "repo": "", "status": status, "accepted": len(walk.accepted)})
    ctx.log("walk finished: %s, %d tasks from %d repositories" % (status, len(walk.accepted), len({t["repo"] for t in walk.accepted})))
    return 0


# ---------------------------------------------------------------- look-ahead helper

class AheadWalk(Walk):
    """Runs the walk's own per-repository steps on repositories further down the order, so
    their Docker validations are in the shared cache when the walk reaches them. It writes
    only `ahead.jsonl` and the validation cache; the walk re-applies every rule itself, in
    order, and alone decides what is accepted and in which order."""

    def __init__(self, ctx, args):  # noqa: D107 - no resume: the helper keeps no pool
        self.ctx = ctx
        self.args = args
        self.walk_path = os.path.join(ctx.v3, "ahead.jsonl")
        self.dev_repos = read_dev_repos(args.dev_repos)
        self.records = []
        self.accepted = []
        self.seq = 0
        self.stop_file = os.path.join(ctx.v3, "STOP-AHEAD")
        self.on_accept = None


def main_walk_state(v3):
    done, ended = set(), False
    with open(os.path.join(v3, "walk.jsonl"), encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            record = json.loads(line)
            if record["kind"] == "repo_done" and record["phase"] == "base":
                done.add(record["repo"].lower())
            elif record["kind"] == "walk_end":
                ended = True
    pool = 0
    if os.path.exists(MANIFEST_PATH):
        with open(MANIFEST_PATH, encoding="utf-8") as handle:
            pool = json.load(handle).get("selection", {}).get("pool_size", 0)
    return done, ended, pool


def cmd_ahead(args):
    ctx = Context(args)
    ctx.log = Log(os.path.join(ctx.v3, "select-ahead.log"))
    ctx.gh.log = ctx.log
    ctx.jobs = lambda: args.jobs
    base = load_population(ctx.v3, "population.json")
    walk = AheadWalk(ctx, args)
    order = base["repositories"]
    ctx.log("look-ahead helper: gap %d repositories, %d test container(s) at a time" % (args.gap, args.jobs))
    while True:
        done, ended, pool = main_walk_state(ctx.v3)
        if ended or pool >= lib.POOL_TARGET or os.path.exists(walk.stop_file) or os.path.exists(os.path.join(ctx.v3, "STOP")):
            ctx.log("look-ahead helper stops: walk ended %s, pool %d" % (ended, pool))
            return 0
        position = next((i for i, r in enumerate(order) if r["full_name"].lower() not in done), len(order))
        target = None
        for record in order[position + args.gap:]:
            name = record["full_name"]
            owner = name.split("/", 1)[0].lower()
            if owner in lib.EXCLUDED_OWNERS or name.lower() in walk.dev_repos or name.lower() in done:
                continue
            if record["archived"] or record["fork"] or record["license"] not in lib.LICENCES_SPDX or record["language"] not in lib.LANGUAGES:
                continue
            if os.path.exists(walk.claim_path(name)):
                continue
            target = record
            break
        if target is None:
            ctx.log("look-ahead helper: nothing left to look at")
            return 0
        if not walk.claim(target["full_name"], "ahead", wait=False):
            continue
        walk.accepted = []
        try:
            walk.process_repo(target, "base", lib.MAX_PER_REPO, lib.MIN_SOURCE_FILES)
            walk.finish_repo(target, "base")
        finally:
            walk.mark_done(target["full_name"], "ahead")


# ---------------------------------------------------------------- report

def cmd_report(args):
    path = os.path.join(os.path.abspath(args.v3), "walk.jsonl")
    with open(path, encoding="utf-8") as handle:
        records = [json.loads(line) for line in handle if line.strip()]
    repos = [r for r in records if r["kind"] == "repo_done"]
    candidates = [r for r in records if r["kind"] == "candidate"]
    repo_level = [r for r in records if r["kind"] == "repo"]
    accepted = [r for r in candidates if r["rule"] == "accepted"]
    by_rule = collections.Counter(r["rule"] for r in candidates)
    by_reason = collections.Counter("%s %s" % (r["rule"], r["reason"]) for r in candidates)
    repo_rules = collections.Counter("%s %s" % (r["rule"], r["reason"]) for r in repo_level if r["rule"] != "T6")
    reached_t4 = [r for r in candidates if r["rule"] not in ("T1", "T2", "T3")]
    t4 = [r for r in candidates if r["rule"] == "T4"]
    pool_repos = collections.Counter(r["repo"] for r in accepted)
    langs = collections.Counter(r["language"] for r in accepted)
    out = {
        "repositories_walked": len(repos),
        "repository_level_rejections": dict(sorted(repo_rules.items())),
        "candidates_considered": len(candidates),
        "rejections_by_rule": dict(sorted(by_rule.items())),
        "rejections_by_rule_and_reason": dict(sorted(by_reason.items())),
        "accepted": len(accepted),
        "accepted_by_phase": dict(collections.Counter(r["phase"] for r in accepted)),
        "pool_repositories": len(pool_repos),
        "pool_tasks_per_repository": dict(sorted(pool_repos.items())),
        "pool_by_language": dict(langs),
        "pool_toolchain_nondefault": sum(1 for r in accepted if r["task"]["toolchain_nondefault"]),
        "pool_full_suite_green_at_base": sum(1 for r in accepted if r["task"]["full_suite_green_at_base"]),
        "t4_share": {"reached_t4": len(reached_t4), "rejected_by_t4": len(t4),
                     "share": round(len(t4) / float(len(reached_t4)), 3) if reached_t4 else None},
        "reached_docker": sum(1 for r in candidates if r["rule"] in ("T5", "accepted")),
        "docker_rejections": dict(collections.Counter(r["reason"] for r in candidates if r["rule"] == "T5")),
        "recipe_kinds_reaching_docker": dict(collections.Counter(r.get("recipe_kind") for r in candidates if r["rule"] in ("T5", "accepted"))),
        "infra_records": sum(1 for r in candidates if r["rule"] == "infra"),
    }
    print(json.dumps(out, indent=2, sort_keys=False))
    return 0


# ---------------------------------------------------------------- selftest (development data only)

def cmd_selftest(args):
    """Validate one known v2 task with the v3 recipes, under a selftest image tag."""
    ctx = Context(args)
    with open(args.manifest_v2, encoding="utf-8") as handle:
        manifest = json.load(handle)
    task = next(t for t in manifest["tasks"] if t["task_id"] == args.task)
    owner = task["repo"].split("/", 1)[0].lower()
    if owner not in lib.EXCLUDED_OWNERS:
        print("selftest runs only on development data (excluded owners)", file=sys.stderr)
        return 3
    repo = PartialRepo(task["repo"], os.path.join(ctx.work, "selftest-clones"))
    repo.ensure_clone()
    for sha in (task["base_sha"], task["fix_sha"]):
        repo.ensure_commit(sha)
    meta = ctx.gh.get("repos/%s" % task["repo"])
    language = meta.get("language")
    paths = set(repo.tree_paths(task["base_sha"]))
    show = lambda path: repo.show(task["base_sha"], path)  # noqa: E731
    recipe = lib.recipe_for(language, show, paths)
    cand = {"task_id": "v3selftest-" + task["task_id"], "repo": task["repo"], "repo_url": task["repo_url"],
            "base_sha": task["base_sha"], "fix_sha": task["fix_sha"], "gold_files": task["gold_files"],
            "test_files": task["test_files"], "pr_commits": []}
    ctx.log("selftest %s: recipe %s" % (task["task_id"], json.dumps(recipe, sort_keys=True)))
    ctx.docker_gate()
    try:
        validated = lib.validate(repo, cand, recipe, os.path.join(ctx.work, "selftest"), ctx.jobs(), ctx.log, show)
        ctx.log("selftest %s accepted: f2p %d (v2 %d), p2p %d (v2 %d), census %s, lint %s" % (
            task["task_id"], len(validated["f2p"]), len(task["f2p"]), len(validated["p2p"]), len(task["p2p"]),
            validated["census"], validated["evidence"]["lint"]))
        same_f2p = sorted(validated["f2p"]) == sorted(task["f2p"])
        ctx.log("selftest %s: f2p identical to v2: %s" % (task["task_id"], same_f2p))
    except Reject as exc:
        ctx.log("selftest %s rejected: %s %s %s" % (task["task_id"], exc.rule, exc.reason, exc.detail))
        return 1
    finally:
        if not args.keep_image:
            lib.remove_image(cand["task_id"])
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("population", "walk", "ahead", "report", "selftest", "gold-check", "rewind"):
        p = sub.add_parser(name)
        p.add_argument("--v3", required=True, help="v3 work directory outside the repository")
        if name == "population":
            p.add_argument("--phase", choices=["base", "f1"], default="base")
        if name in ("walk", "ahead"):
            p.add_argument("--dev-repos", default=DEV_REPOS_PATH)
            p.add_argument("--manifest", default=MANIFEST_PATH)
        if name == "ahead":
            p.add_argument("--gap", type=int, default=20, help="repositories to stay ahead of the walk")
            p.add_argument("--jobs", type=int, choices=[1], default=1, help="test containers at a time (memory budget)")
        if name == "gold-check":
            p.add_argument("--jobs", type=int, choices=[1, 2], default=1, help="grading containers at a time")
            p.add_argument("--tasks", help="comma-separated task ids (default: every accepted task)")
        if name == "rewind":
            p.add_argument("--repo", required=True, help="owner/name: the first repository to replay")
            p.add_argument("--label", required=True, help="names the kept copy walk-before-LABEL.jsonl")
            p.add_argument("--reason", required=True)
        if name == "selftest":
            p.add_argument("--task", required=True)
            p.add_argument("--manifest-v2", default=os.path.join(_HERE, "manifest-v2.json"))
            p.add_argument("--keep-image", action="store_true")
    args = parser.parse_args(argv)
    return {"population": cmd_population, "walk": cmd_walk, "ahead": cmd_ahead, "report": cmd_report,
            "selftest": cmd_selftest, "gold-check": cmd_gold_check, "rewind": cmd_rewind}[args.command](args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
