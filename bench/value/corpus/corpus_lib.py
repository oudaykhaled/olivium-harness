"""Selection and validation logic for the value benchmark task corpus.

Standard library only (host Python may be 3.9). Everything fetched from GitHub
is treated as untrusted data: it is parsed, hashed and stored in the scratch
work directory, and never executed on the host. Repository code runs only in
Docker containers named olivium-bench-* and labelled olivium-bench=1.

Entry points: select.py (selection_main) and materialize.py (materialize_main).
"""

from __future__ import annotations

import argparse
import collections
import concurrent.futures
import datetime
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("olivium_bench_testids", os.path.join(HERE, "testids.py"))
testids = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(testids)

GIT = ["git", "-c", "core.hooksPath=/dev/null", "-c", "protocol.file.allow=never"]

# The pre-registered rule from PROTOCOL.md. Changing a value here is a deviation
# and has to be recorded under selection.relaxations (see build_relaxations).
RULES = {
    "start_repositories": [
        "pallets/click",
        "pallets/flask",
        "pallets/jinja",
        "encode/httpx",
        "python-attrs/attrs",
        "expressjs/express",
    ],
    "extra_repository_min_stars": 1000,
    "licenses": ["MIT", "BSD-2-Clause", "BSD-3-Clause", "Apache-2.0"],
    "languages": ["Python", "JavaScript", "TypeScript"],
    "merged_after": "2026-06-30",
    "order": "merged_at descending within each repository",
    "max_non_test_files": 3,
    "max_non_test_lines": 100,
    "min_test_files": 1,
    "min_issue_prose_words": 20,
    "min_markdown_files": 1,
    "test_timeout_seconds": 300,
    "repeats_per_side": 3,
    "max_tasks": 5,
    "max_per_repository": 2,
    "selection_order": "round-robin over start_repositories, newest eligible first",
    "linked_issue": "closing keyword in the pull request body naming an issue in the same repository",
    # Added 2026-11-09 after the canary (PROTOCOL.md change log): a stale cross-reference
    # linked a 2019 issue to a 2026 fix, and an old issue's text is in the model's training data.
    "max_issue_age_days": 365,
    "dependency_change": "any non-test dependency manifest or lock file touched",
    "non_test_definition": "every changed path that is not a test path (changelogs and docs count)",
    "test_path_definition": "a directory segment tests, test or __tests__; test_*.py; *_test.py; conftest.py; *.test.* or *.spec.* for js/ts",
}

DEPENDENCY_BASENAMES = {
    "pyproject.toml",
    "setup.py",
    "setup.cfg",
    "Pipfile",
    "Pipfile.lock",
    "poetry.lock",
    "uv.lock",
    "pdm.lock",
    "package.json",
    "package-lock.json",
    "npm-shrinkwrap.json",
    "yarn.lock",
    "pnpm-lock.yaml",
}
DEPENDENCY_RE = re.compile(r"(^|/)(requirements([-_.][^/]*)?\.(txt|in)|constraints([-_.][^/]*)?\.txt)$|(^|/)requirements/[^/]+\.(txt|in)$")
TEST_FILE_RE = re.compile(r"^(test_.*\.py|.*_test\.py|conftest\.py|.*\.(test|spec)\.(js|jsx|ts|tsx|mjs|cjs))$")
CLOSING_RE = re.compile(
    r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b\s*:?\s+"
    r"(?:https://github\.com/([\w.-]+/[\w.-]+)/issues/(\d+)|(?:([\w.-]+/[\w.-]+))?#(\d+))",
    re.IGNORECASE,
)
MARKDOWN_RE = re.compile(r"\.(md|markdown|mdx)$", re.IGNORECASE)

PY_TEST_COMMAND = (
    "mkdir -p /work/test-results && "
    "python -m pytest -p no:cacheprovider -q --tb=short --junitxml=/work/test-results/results.xml"
)
EXPRESS_TEST_COMMAND = (
    "mkdir -p /work/test-results && "
    "node_modules/.bin/mocha --require test/support/env --check-leaks "
    "--reporter xunit --reporter-option output=/work/test-results/results.xml "
    "test/ test/acceptance/"
)

RECIPES = {
    # click's pager tests shell out to `less`, which python:3.12 does not ship.
    "pallets/click": {"kind": "uv", "groups": ["tests", "dev"], "dists": ["click"], "imports": ["click"], "apt": ["less"]},
    "pallets/flask": {"kind": "uv", "groups": ["tests", "dev"], "dists": ["flask"], "imports": ["flask"]},
    "pallets/jinja": {"kind": "uv", "groups": ["tests", "dev"], "dists": ["jinja2"], "imports": ["jinja2"]},
    "encode/httpx": {"kind": "requirements", "dists": ["httpx"], "imports": ["httpx"]},
    # The image has no tags by design, so hatch-vcs would produce a version that
    # attrs cannot parse. tox.ini in that repository passes this same variable.
    # The value is neutral and says nothing about the release containing the fix.
    "python-attrs/attrs": {
        "kind": "uv",
        "groups": ["tests"],
        "lint_groups": ["lint", "dev"],
        "dists": ["attrs"],
        "imports": ["attr", "attrs"],
        "build_env": {"SETUPTOOLS_SCM_PRETEND_VERSION": "0.0.0"},
    },
    "expressjs/express": {"kind": "npm", "dists": ["express"], "imports": ["express"]},
}


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def is_test_path(path):
    parts = path.split("/")
    if any(segment in ("tests", "test", "__tests__") for segment in parts[:-1]):
        return True
    return bool(TEST_FILE_RE.match(parts[-1]))


def is_dependency_path(path):
    return os.path.basename(path) in DEPENDENCY_BASENAMES or bool(DEPENDENCY_RE.search(path))


def issue_markdown(title, body):
    """Canonical issue text. issue_sha256 is the SHA-256 of these UTF-8 bytes."""
    text = "# %s\n\n%s\n" % ((title or "").strip(), (body or "").strip())
    return text.replace("\r\n", "\n").replace("\r", "\n")


def prose_word_count(body):
    text = body or ""
    text = re.sub(r"<!--.*?-->", " ", text, flags=re.DOTALL)
    text = re.sub(r"```.*?```", " ", text, flags=re.DOTALL)
    text = re.sub(r"~~~.*?~~~", " ", text, flags=re.DOTALL)
    text = re.sub(r"`[^`\n]*`", " ", text)
    text = re.sub(r"https?://\S+", " ", text)
    return len(re.findall(r"[A-Za-z]{2,}", text))


def sha256_text(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def run(cmd, cwd=None, input_text=None, timeout=None, check=True):
    return subprocess.run(
        cmd,
        cwd=cwd,
        input=input_text,
        timeout=timeout,
        check=check,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
        errors="replace",
    )


class Api:
    """Read-only GitHub access through `gh api -X GET`, cached under the work dir."""

    def __init__(self, cache_dir, refresh=False):
        self.cache_dir = cache_dir
        self.refresh = refresh
        os.makedirs(cache_dir, exist_ok=True)

    def get(self, endpoint):
        key = hashlib.sha256(endpoint.encode()).hexdigest()
        path = os.path.join(self.cache_dir, key + ".json")
        if os.path.exists(path) and not self.refresh:
            with open(path, "r", encoding="utf-8") as fh:
                return json.load(fh)
        last = None
        for attempt in range(4):
            proc = run(["gh", "api", "-X", "GET", endpoint], check=False, timeout=120)
            if proc.returncode == 0:
                data = json.loads(proc.stdout)
                tmp = path + ".tmp"
                with open(tmp, "w", encoding="utf-8") as fh:
                    json.dump(data, fh)
                os.replace(tmp, path)
                return data
            last = proc.stderr
            if "404" in proc.stderr or "Not Found" in proc.stderr:
                return None
            time.sleep(2 * (attempt + 1))
        raise RuntimeError("gh api GET failed for %s: %s" % (endpoint, last))


class Repo:
    def __init__(self, full_name, clones_dir):
        self.full_name = full_name
        self.url = "https://github.com/%s" % full_name
        self.path = os.path.join(clones_dir, full_name.replace("/", "__") + ".git")

    def ensure_clone(self):
        if os.path.isdir(self.path):
            return
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        run(GIT + ["clone", "--quiet", "--bare", self.url, self.path], timeout=900)

    def git(self, *args, **kwargs):
        return run(GIT + ["-C", self.path] + list(args), **kwargs)

    def has_commit(self, sha):
        proc = self.git("cat-file", "-e", sha + "^{commit}", check=False)
        return proc.returncode == 0

    def ensure_commit(self, sha):
        if self.has_commit(sha):
            return True
        self.git("fetch", "--quiet", "--no-tags", "origin", sha, check=False, timeout=300)
        return self.has_commit(sha)

    def parents(self, sha):
        out = self.git("rev-list", "--parents", "-n", "1", sha).stdout.split()
        return out[1:]

    def numstat(self, base, fix):
        """Return [(path, added_or_None, deleted_or_None)], binary files as None."""
        out = self.git("diff", "--numstat", "--no-renames", "-z", base, fix).stdout
        items = []
        for chunk in out.split("\0"):
            if not chunk:
                continue
            added, deleted, path = chunk.split("\t", 2)
            items.append((path, None if added == "-" else int(added), None if deleted == "-" else int(deleted)))
        return items

    def patch(self, base, fix, paths):
        return self.git("diff", "--binary", "--no-renames", base, fix, "--", *paths).stdout

    def tree_paths(self, sha):
        out = self.git("ls-tree", "-r", "-z", "--name-only", sha).stdout
        return [p for p in out.split("\0") if p]

    def show(self, sha, path):
        proc = self.git("show", "%s:%s" % (sha, path), check=False)
        return proc.stdout if proc.returncode == 0 else None


class Rejection(Exception):
    def __init__(self, reason, detail=None):
        Exception.__init__(self, reason)
        self.reason = reason
        self.detail = detail or {}


def walk_merged_pulls(api, repo, merged_after):
    """Merged pull requests after the cutoff, newest merge first.

    The list endpoint cannot sort by merge time, so this walks by update time
    (merged_at <= updated_at, so older pages cannot hold later merges) and sorts.
    """
    cutoff = merged_after + "T23:59:59Z"
    found = []
    page = 1
    while True:
        items = api.get("repos/%s/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=%d" % (repo, page))
        if not items:
            break
        stop = False
        for pr in items:
            if pr["updated_at"] <= cutoff:
                stop = True
                continue
            if pr.get("merged_at") and pr["merged_at"] > cutoff:
                found.append(pr)
        if stop:
            break
        page += 1
    found.sort(key=lambda p: p["merged_at"], reverse=True)
    return found


def closing_issue_refs(repo, body):
    refs = []
    for match in CLOSING_RE.finditer(body or ""):
        url_repo, url_number, other_repo, number = match.groups()
        target = url_repo or other_repo or repo
        issue_number = int(url_number or number)
        if target.lower() == repo.lower() and issue_number not in refs:
            refs.append(issue_number)
    return refs


def issue_age_days(issue, merged_at):
    """Days from the issue's creation to the pull request's merge; None if unknown."""
    try:
        created = datetime.datetime.strptime(issue["created_at"], "%Y-%m-%dT%H:%M:%SZ")
        merged = datetime.datetime.strptime(merged_at, "%Y-%m-%dT%H:%M:%SZ")
    except (KeyError, TypeError, ValueError):
        return None
    return (merged - created).days


def pick_linked_issue(api, repo, refs, merged_at=None):
    problems = {}
    for number in refs:
        issue = api.get("repos/%s/issues/%d" % (repo, number))
        if issue is None:
            problems[number] = "not_found"
        elif issue.get("pull_request"):
            problems[number] = "is_pull_request"
        elif issue.get("state") != "closed":
            problems[number] = "not_closed"
        elif merged_at is not None and (
            issue_age_days(issue, merged_at) is None
            or issue_age_days(issue, merged_at) > RULES["max_issue_age_days"]
        ):
            problems[number] = "issue_too_old:%s_days" % issue_age_days(issue, merged_at)
        else:
            words = prose_word_count(issue.get("body"))
            if words < RULES["min_issue_prose_words"]:
                problems[number] = "too_little_prose:%d" % words
            else:
                return issue, words, problems
    return None, 0, problems


def derive_base(repo, api, pr, fix_sha):
    parents = repo.parents(fix_sha)
    if not parents:
        raise Rejection("base_undeterminable", {"why": "merge commit has no parent"})
    if len(parents) >= 2 or pr["_commits"] == 1:
        return parents[0], "first_parent"
    # One parent and several commits: a squash, or a rebase of the whole branch.
    file_names = {f["filename"] for f in pr["_files"]}
    parent_paths = {p for p, _a, _d in repo.numstat(parents[0], fix_sha)}
    if parent_paths == file_names:
        return parents[0], "squash_parent"
    proc = repo.git("rev-parse", "--verify", "--quiet", "%s~%d" % (fix_sha, pr["_commits"]), check=False)
    if proc.returncode != 0:
        raise Rejection("base_undeterminable", {"why": "cannot walk back over rebased commits"})
    return proc.stdout.strip(), "rebase_walk_back"


def evaluate_pull(api, repo, repo_meta, pr):
    """Apply the static rule. Returns a candidate dict or raises Rejection."""
    full_name = repo.full_name
    number = pr["number"]
    refs = closing_issue_refs(full_name, pr.get("body"))
    if not refs:
        raise Rejection("no_closing_issue_reference")
    issue, words, problems = pick_linked_issue(api, full_name, refs, pr.get("merged_at"))
    if issue is None:
        raise Rejection("linked_issue_not_usable", {"issues": {str(k): v for k, v in problems.items()}})
    fix_sha = pr.get("merge_commit_sha")
    if not fix_sha or not repo.ensure_commit(fix_sha):
        raise Rejection("merge_commit_unavailable")
    files = api.get("repos/%s/pulls/%d/files?per_page=100" % (full_name, number)) or []
    pr["_files"] = files
    commits = api.get("repos/%s/pulls/%d/commits?per_page=100" % (full_name, number)) or []
    pr["_commits"] = len(commits)
    base_sha, base_how = derive_base(repo, api, pr, fix_sha)
    if not repo.ensure_commit(base_sha):
        raise Rejection("base_commit_unavailable")
    stats = repo.numstat(base_sha, fix_sha)
    paths = [p for p, _a, _d in stats]
    tests = [p for p in paths if is_test_path(p)]
    non_tests = [(p, a, d) for p, a, d in stats if not is_test_path(p)]
    dependency = sorted(p for p, _a, _d in non_tests if is_dependency_path(p))
    if dependency:
        raise Rejection("dependency_change", {"paths": dependency})
    if not tests:
        raise Rejection("no_test_change")
    if not non_tests:
        raise Rejection("no_non_test_change")
    if any(a is None or d is None for _p, a, d in non_tests):
        raise Rejection("binary_non_test_change")
    if len(non_tests) > RULES["max_non_test_files"]:
        raise Rejection("too_many_non_test_files", {"count": len(non_tests)})
    lines = sum(a + d for _p, a, d in non_tests)
    if lines > RULES["max_non_test_lines"]:
        raise Rejection("too_many_non_test_lines", {"lines": lines})
    markdown = sum(1 for p in repo.tree_paths(base_sha) if MARKDOWN_RE.search(p))
    if markdown < RULES["min_markdown_files"]:
        raise Rejection("no_markdown_documentation")
    owner, name = full_name.split("/", 1)
    return {
        "task_id": ("%s-%s-%d" % (owner, name, number)).lower().replace(".", "-"),
        "repo": full_name,
        "repo_url": repo.url,
        "license": repo_meta["license"],
        "language": repo_meta["language"],
        "pr_number": number,
        "pr_url": "%s/pull/%d" % (repo.url, number),
        "issue_number": issue["number"],
        "issue_url": "%s/issues/%d" % (repo.url, issue["number"]),
        "issue_sha256": sha256_text(issue_markdown(issue.get("title"), issue.get("body"))),
        "issue_prose_words": words,
        "base_sha": base_sha,
        "base_derivation": base_how,
        "fix_sha": fix_sha,
        "merged_at": pr["merged_at"],
        "gold_files": sorted(p for p, _a, _d in non_tests),
        "test_files": sorted(tests),
        "non_test_lines": lines,
        "markdown_files_count": markdown,
        "pr_commits": sorted({c["sha"] for c in commits}),
    }


def repo_metadata(api, full_name):
    data = api.get("repos/%s" % full_name)
    if data is None:
        raise RuntimeError("repository not found: %s" % full_name)
    return {
        "license": (data.get("license") or {}).get("spdx_id"),
        "language": data.get("language"),
        "stars": data.get("stargazers_count", 0),
    }


def dependency_groups(pyproject_text):
    """Names under [dependency-groups]; the host has no tomllib on Python 3.9."""
    groups = set()
    inside = False
    for line in (pyproject_text or "").splitlines():
        stripped = line.strip()
        if stripped.startswith("["):
            inside = stripped == "[dependency-groups]"
            continue
        if inside:
            match = re.match(r"([A-Za-z0-9_-]+)\s*=", stripped)
            if match:
                groups.add(match.group(1))
    return groups


def recipe_for(repo, cand):
    recipe = dict(RECIPES[cand["repo"]])
    if recipe["kind"] == "uv":
        if repo.show(cand["base_sha"], "uv.lock") is None:
            raise Rejection("recipe_not_applicable", {"why": "no uv.lock at base_sha"})
        available = dependency_groups(repo.show(cand["base_sha"], "pyproject.toml"))
        if "tests" not in available:
            raise Rejection("recipe_not_applicable", {"why": "no tests dependency group at base_sha"})
        groups = [g for g in recipe["groups"] if g in available]
        for group in recipe.get("lint_groups", []):
            if group in available:
                groups.append(group)
                break
        recipe["groups"] = groups
    if recipe["kind"] == "requirements" and repo.show(cand["base_sha"], "requirements.txt") is None:
        raise Rejection("recipe_not_applicable", {"why": "no requirements.txt at base_sha"})
    recipe["test_command"] = EXPRESS_TEST_COMMAND if recipe["kind"] == "npm" else PY_TEST_COMMAND
    return recipe


def dockerfile_for(cand, recipe):
    base_image = "node:22" if recipe["kind"] == "npm" else "python:3.12"
    lines = [
        "FROM %s" % base_image,
        'LABEL olivium-bench="1" olivium-bench.kind="deps" olivium-bench.task="%s"' % cand["task_id"],
        "ENV PYTHONDONTWRITEBYTECODE=1 PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1",
        *(
            [
                "RUN set -eux; apt-get update -qq; "
                "apt-get install -y -qq --no-install-recommends %s; "
                "rm -rf /var/lib/apt/lists/*" % " ".join(recipe["apt"])
            ]
            if recipe.get("apt")
            else []
        ),
        "RUN git init -q -b main /work/repo",
        "WORKDIR /work/repo",
        # Only base_sha and its ancestors enter this repository: no remote, no
        # tags, no later refs. FETCH_HEAD and reflogs are removed afterwards.
        "RUN set -eux; "
        "git fetch --quiet --no-tags %s %s; " % (cand["repo_url"], cand["base_sha"])
        + "git checkout --quiet -B main FETCH_HEAD; "
        + 'test "$(git rev-parse HEAD)" = "%s"; ' % cand["base_sha"]
        + "rm -f .git/FETCH_HEAD .git/ORIG_HEAD; "
        + "git reflog expire --expire=now --all; "
        + "git gc --quiet --prune=now",
    ]
    if recipe["kind"] == "uv":
        lines.append("ENV UV_PROJECT_ENVIRONMENT=/opt/venv UV_CACHE_DIR=/tmp/uv-cache")
        group_args = " ".join("--group %s" % g for g in recipe["groups"])
        lines.append(
            "RUN set -eux; pip install --quiet uv; "
            "%suv sync --quiet --frozen --no-default-groups %s; "
            "rm -rf /tmp/uv-cache /root/.cache"
            % ("".join("%s=%s " % item for item in sorted(recipe.get("build_env", {}).items())), group_args)
        )
        lines.append("ENV PATH=/opt/venv/bin:$PATH")
    elif recipe["kind"] == "requirements":
        lines.append(
            "RUN set -eux; python -m venv /opt/venv; "
            "/opt/venv/bin/pip install --quiet -r requirements.txt; "
            "rm -rf /root/.cache"
        )
        lines.append("ENV PATH=/opt/venv/bin:$PATH")
    elif recipe["kind"] == "npm":
        lines.append(
            "RUN set -eux; npm install --no-audit --no-fund --no-package-lock --ignore-scripts; "
            "rm -rf /root/.npm"
        )
    else:
        raise ValueError("unknown recipe kind: %s" % recipe["kind"])
    # Installing the project must not leave the tracked tree modified.
    lines.append('RUN set -eux; test -z "$(git status --porcelain)"')
    return "\n".join(lines) + "\n"


def docker(*args, **kwargs):
    return run(["docker"] + list(args), **kwargs)


def force_remove(name):
    docker("rm", "-f", name, check=False, timeout=60)


def container_run(name, image, script, files=None, timeout=330, results_dir=None, memory="1800m"):
    """One create/cp/start/cp/rm cycle with no network and no host mounts."""
    force_remove(name)
    docker(
        "create", "--name", name, "--label", "olivium-bench=1", "--network", "none",
        "--memory", memory, "--memory-swap", memory, "--cpus", "2", "--pids-limit", "2048",
        image, "/bin/bash", "/work/job.sh",
    )
    try:
        docker("cp", script, "%s:/work/job.sh" % name)
        for source, target in (files or {}).items():
            docker("cp", source, "%s:%s" % (name, target))
        started = time.time()
        timed_out = False
        try:
            proc = docker("start", "-a", name, timeout=timeout, check=False)
            exit_code, stdout, stderr = proc.returncode, proc.stdout, proc.stderr
        except subprocess.TimeoutExpired:
            timed_out, exit_code, stdout, stderr = True, None, "", ""
            docker("kill", name, check=False, timeout=30)
        elapsed = time.time() - started
        if results_dir is not None:
            os.makedirs(results_dir, exist_ok=True)
            docker("cp", "%s:/work/test-results/." % name, results_dir, check=False, timeout=60)
        return {"exit": exit_code, "stdout": stdout, "stderr": stderr, "wall": elapsed, "timed_out": timed_out}
    finally:
        force_remove(name)


JOB_TEST = """#!/bin/bash
set -u
cd /work/repo
mkdir -p /work/test-results
for p in $(ls /work/patches 2>/dev/null | sort); do
  git apply --whitespace=nowarn "/work/patches/$p" || { echo "patch failed: $p" >&2; exit 99; }
done
bash -c "$(cat /work/command.txt)" > /work/test-results/console.log 2>&1
echo $? > /work/test-results/exit_code
exit 0
"""

JOB_PROBE = """#!/bin/bash
cd /work/repo
echo "head=$(git rev-parse HEAD)"
echo "refs=$(git for-each-ref --format='%(refname)' | tr '\\n' ',')"
echo "remotes=$(git remote | tr '\\n' ',')"
echo "tags=$(git tag -l | tr '\\n' ',')"
echo "reflog_entries=$(git reflog 2>/dev/null | wc -l | tr -d ' ')"
echo "fetch_head=$(test -e .git/FETCH_HEAD && echo present || echo absent)"
echo "dirty=$(git status --porcelain | wc -l | tr -d ' ')"
while read -r sha; do
  [ -z "$sha" ] && continue
  if git cat-file -e "$sha" 2>/dev/null; then echo "reachable=$sha"; fi
done < /work/forbidden_shas.txt
{ command -v python >/dev/null && python /work/copies.py /work/dists.txt; } || true
if [ -d node_modules ]; then
  while read -r dist; do
    find node_modules -type f -path "*/node_modules/$dist/package.json" -o -type f -path "node_modules/$dist/package.json" | sed 's/^/node_copy=/'
  done < /work/dists.txt
fi
"""

COPIES_PY = """
import importlib.metadata as md, json, os, re, sys
targets = {re.sub(r"[-_.]+", "-", l.strip()).lower() for l in open(sys.argv[1]) if l.strip()}
imports = {l.strip() for l in open(sys.argv[1].replace("dists", "imports")) if l.strip()}
bad = []
for dist in md.distributions():
    name = re.sub(r"[-_.]+", "-", dist.metadata["Name"] or "").lower()
    if name not in targets:
        continue
    raw = dist.read_text("direct_url.json") or "{}"
    info = json.loads(raw)
    editable = (info.get("dir_info") or {}).get("editable") is True
    if not (editable and info.get("url") == "file:///work/repo"):
        bad.append("%s %s editable=%s url=%s" % (name, dist.version, editable, info.get("url")))
for entry in sys.path:
    if "site-packages" not in entry or not os.path.isdir(entry):
        continue
    for root, dirs, _files in os.walk(entry):
        for d in dirs:
            if d in imports:
                bad.append("package directory %s" % os.path.join(root, d))
for item in bad:
    print("python_copy=" + item)
print("python_copies_checked=1")
"""


def write_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def build_image(cand, recipe, task_dir, log):
    dockerfile = dockerfile_for(cand, recipe)
    write_text(os.path.join(task_dir, "Dockerfile"), dockerfile)
    context = os.path.join(task_dir, "context")
    os.makedirs(context, exist_ok=True)
    image = "olivium-bench-deps-%s:v1" % cand["task_id"]
    log("building %s" % image)
    started = time.time()
    proc = run(
        [
            "docker", "build", "--quiet", "--label", "olivium-bench=1",
            "-t", image, "-f", os.path.join(task_dir, "Dockerfile"), context,
        ],
        check=False,
        timeout=1800,
    )
    write_text(os.path.join(task_dir, "build.log"), proc.stdout + "\n" + proc.stderr)
    if proc.returncode != 0:
        raise Rejection("image_build_failed", {"log": "scratch only", "seconds": round(time.time() - started)})
    return image, round(time.time() - started, 1)


def probe_image(cand, recipe, image, task_dir):
    sha_list = [cand["fix_sha"]] + [c for c in cand["pr_commits"] if c != cand["base_sha"]]
    probe_dir = os.path.join(task_dir, "probe")
    os.makedirs(probe_dir, exist_ok=True)
    write_text(os.path.join(probe_dir, "forbidden_shas.txt"), "\n".join(sha_list) + "\n")
    write_text(os.path.join(probe_dir, "dists.txt"), "\n".join(recipe["dists"]) + "\n")
    write_text(os.path.join(probe_dir, "imports.txt"), "\n".join(recipe["imports"]) + "\n")
    write_text(os.path.join(probe_dir, "copies.py"), COPIES_PY)
    script = os.path.join(probe_dir, "job.sh")
    write_text(script, JOB_PROBE)
    result = container_run(
        "olivium-bench-probe-%s" % cand["task_id"],
        image,
        script,
        files={
            os.path.join(probe_dir, "forbidden_shas.txt"): "/work/forbidden_shas.txt",
            os.path.join(probe_dir, "dists.txt"): "/work/dists.txt",
            os.path.join(probe_dir, "imports.txt"): "/work/imports.txt",
            os.path.join(probe_dir, "copies.py"): "/work/copies.py",
        },
        timeout=120,
    )
    write_text(os.path.join(task_dir, "probe.log"), result["stdout"] + "\n" + result["stderr"])
    facts = collections.defaultdict(list)
    for line in result["stdout"].splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            facts[key].append(value)
    first = lambda key: facts[key][0] if facts[key] else None
    failures = []
    if first("head") != cand["base_sha"]:
        failures.append("head_mismatch")
    if first("refs") != "refs/heads/main,":
        failures.append("unexpected_refs")
    if first("remotes") != "":
        failures.append("remote_present")
    if first("tags") != "":
        failures.append("tags_present")
    if first("reflog_entries") != "0":
        failures.append("reflog_present")
    if first("fetch_head") != "absent":
        failures.append("fetch_head_present")
    if first("dirty") != "0":
        failures.append("tracked_tree_modified")
    if facts["reachable"]:
        failures.append("later_commit_reachable")
    if facts["python_copy"] or facts["node_copy"]:
        failures.append("released_copy_present")
    if recipe["kind"] != "npm" and first("python_copies_checked") != "1":
        failures.append("copy_scan_did_not_run")
    if failures:
        raise Rejection("isolation_check_failed", {"failures": failures})
    return {
        "head": first("head"),
        "refs": first("refs").rstrip(","),
        "remotes": first("remotes").rstrip(","),
        "tags": first("tags").rstrip(","),
        "reflog_entries": int(first("reflog_entries")),
        "fix_sha_absent": True,
        "pr_commits_absent": len(sha_list),
        "released_copy": "none",
    }


def run_tests_once(cand, recipe, image, task_dir, side, run_index):
    run_dir = os.path.join(task_dir, "runs", "%s-%d" % (side, run_index))
    patch_dir = os.path.join(run_dir, "patches")
    os.makedirs(patch_dir, exist_ok=True)
    shutil.copy(os.path.join(task_dir, "test.patch"), os.path.join(patch_dir, "1-test.patch"))
    if side == "fix":
        shutil.copy(os.path.join(task_dir, "gold.patch"), os.path.join(patch_dir, "2-gold.patch"))
    script = os.path.join(run_dir, "job.sh")
    write_text(script, JOB_TEST)
    command_file = os.path.join(run_dir, "command.txt")
    write_text(command_file, recipe["test_command"])
    result = container_run(
        "olivium-bench-val-%s-%s-%d" % (cand["task_id"], side, run_index),
        image,
        script,
        files={patch_dir: "/work/patches", command_file: "/work/command.txt"},
        timeout=RULES["test_timeout_seconds"] + 30,
        results_dir=os.path.join(run_dir, "results"),
    )
    write_text(os.path.join(run_dir, "docker.log"), (result["stdout"] or "") + "\n" + (result["stderr"] or ""))
    outcome = {
        "side": side,
        "run": run_index,
        "wall_seconds": round(result["wall"], 2),
        "timed_out": result["timed_out"],
    }
    if result["timed_out"] or result["wall"] > RULES["test_timeout_seconds"]:
        raise Rejection("test_timeout", {"side": side, "run": run_index})
    if result["exit"] == 99:
        raise Rejection("patch_apply_failed", {"side": side, "run": run_index})
    if result["exit"] != 0:
        raise Rejection("test_container_failed", {"side": side, "run": run_index, "exit": result["exit"]})
    code_path = os.path.join(run_dir, "results", "exit_code")
    junit_path = os.path.join(run_dir, "results", "results.xml")
    if not os.path.exists(junit_path) or not os.path.exists(code_path):
        raise Rejection("no_test_results", {"side": side, "run": run_index})
    outcome["exit_code"] = int(open(code_path, encoding="utf-8").read().strip() or -1)
    if recipe["kind"] != "npm" and outcome["exit_code"] not in (0, 1):
        raise Rejection("test_runner_error", {"side": side, "run": run_index, "exit": outcome["exit_code"]})
    try:
        tests = testids.parse_junit(junit_path)
    except Exception as exc:  # malformed report from a crashed runner
        raise Rejection("no_test_results", {"side": side, "run": run_index, "error": type(exc).__name__})
    if not tests:
        raise Rejection("no_test_results", {"side": side, "run": run_index, "error": "empty"})
    counts = collections.Counter(tests.values())
    outcome.update(
        {"passed": counts.get("pass", 0), "failed": counts.get("fail", 0), "skipped": counts.get("skip", 0), "total": len(tests)}
    )
    return outcome, tests


def classify(side_results):
    """side_results: {"base": [dict,..], "fix": [dict,..]}, 3 result dicts each."""
    all_ids = set()
    for runs in side_results.values():
        for results in runs:
            all_ids.update(results)
    f2p, p2p, flaky, both_failing, fix_regressions = [], [], [], [], []
    for test_id in sorted(all_ids):
        base = [r.get(test_id, "absent") for r in side_results["base"]]
        fix = [r.get(test_id, "absent") for r in side_results["fix"]]
        if len(set(base)) > 1 or len(set(fix)) > 1:
            flaky.append(test_id)
            continue
        b, f = base[0], fix[0]
        if f == "pass" and b in ("fail", "absent"):
            f2p.append(test_id)
        elif f == "pass" and b == "pass":
            p2p.append(test_id)
        elif f == "fail" and b == "pass":
            fix_regressions.append(test_id)
        elif f == "fail" and b == "fail":
            both_failing.append(test_id)
    return {"f2p": f2p, "p2p": p2p, "flaky": flaky, "both_failing": both_failing, "fix_regressions": fix_regressions}


def detect_lint(repo, cand, recipe, image, task_dir):
    """Lint only from the repository's own configuration and only if installed."""
    command = None
    tool = None
    source = None
    if recipe["kind"] == "npm":
        package = repo.show(cand["base_sha"], "package.json")
        try:
            scripts = json.loads(package or "{}").get("scripts") or {}
        except ValueError:
            scripts = {}
        if scripts.get("lint"):
            command, tool, source = "npm run --silent lint", "node_modules/.bin/eslint", "package.json scripts.lint"
    else:
        config = repo.show(cand["base_sha"], "pyproject.toml") or ""
        has_ruff = "[tool.ruff" in config or repo.show(cand["base_sha"], "ruff.toml") is not None
        if has_ruff:
            command, tool, source = "ruff check --no-cache", "ruff", "pyproject.toml [tool.ruff]"
    if command is None:
        return None, {"status": "no_linter_configured"}
    lint_dir = os.path.join(task_dir, "lint")
    patch_dir = os.path.join(lint_dir, "patches")
    os.makedirs(patch_dir, exist_ok=True)
    shutil.copy(os.path.join(task_dir, "test.patch"), os.path.join(patch_dir, "1-test.patch"))
    shutil.copy(os.path.join(task_dir, "gold.patch"), os.path.join(patch_dir, "2-gold.patch"))
    script = os.path.join(lint_dir, "job.sh")
    write_text(
        script,
        """#!/bin/bash
set -u
cd /work/repo
if [ ! -x "%s" ] && ! command -v "%s" >/dev/null 2>&1; then echo tool_absent; exit 77; fi
for p in $(ls /work/patches | sort); do git apply --whitespace=nowarn "/work/patches/$p" || exit 99; done
%s
exit $?
"""
        % (tool, tool, command),
    )
    result = container_run(
        "olivium-bench-lint-%s" % cand["task_id"],
        image,
        script,
        files={patch_dir: "/work/patches"},
        timeout=300,
    )
    write_text(os.path.join(lint_dir, "lint.log"), (result["stdout"] or "") + "\n" + (result["stderr"] or ""))
    if result["exit"] == 77:
        return None, {"status": "tool_not_installed", "tool": tool, "source": source}
    if result["exit"] != 0:
        return None, {"status": "fails_with_real_fix", "tool": tool, "source": source, "exit": result["exit"]}
    return command, {"status": "ok", "tool": tool, "source": source, "wall_seconds": round(result["wall"], 2)}


def validate_candidate(repo, cand, recipe, work, jobs, log):
    task_dir = os.path.join(work, "tasks", cand["task_id"])
    if os.path.isdir(os.path.join(task_dir, "runs")):
        shutil.rmtree(os.path.join(task_dir, "runs"))
    os.makedirs(task_dir, exist_ok=True)
    write_text(os.path.join(task_dir, "test.patch"), repo.patch(cand["base_sha"], cand["fix_sha"], cand["test_files"]))
    write_text(os.path.join(task_dir, "gold.patch"), repo.patch(cand["base_sha"], cand["fix_sha"], cand["gold_files"]))
    image, build_seconds = build_image(cand, recipe, task_dir, log)
    isolation = probe_image(cand, recipe, image, task_dir)
    log("isolation ok for %s; running 3x base and 3x fix" % cand["task_id"])
    runs = [("base", i) for i in range(1, 4)] + [("fix", i) for i in range(1, 4)]
    side_results = {"base": [None, None, None], "fix": [None, None, None]}
    outcomes = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        futures = {pool.submit(run_tests_once, cand, recipe, image, task_dir, s, i): (s, i) for s, i in runs}
        first_error = None
        for future in concurrent.futures.as_completed(futures):
            side, index = futures[future]
            try:
                outcome, tests = future.result()
            except concurrent.futures.CancelledError:
                continue  # an earlier run already rejected this candidate
            except Rejection as exc:
                first_error = first_error or exc
                # The candidate is rejected whatever the remaining runs do; not-started
                # ones are cancelled so a suite over the time limit does not cost 6 runs.
                for other in futures:
                    other.cancel()
                continue
            outcomes.append(outcome)
            side_results[side][index - 1] = tests
        if first_error is not None:
            raise first_error
    classified = classify(side_results)
    outcomes.sort(key=lambda o: (o["side"], o["run"]))
    log("%s: f2p=%d p2p=%d flaky=%d" % (cand["task_id"], len(classified["f2p"]), len(classified["p2p"]), len(classified["flaky"])))
    if not classified["f2p"]:
        raise Rejection("no_fail_to_pass", {"p2p": len(classified["p2p"]), "flaky": len(classified["flaky"])})
    if not classified["p2p"]:
        raise Rejection("no_pass_to_pass", {"f2p": len(classified["f2p"]), "flaky": len(classified["flaky"])})
    lint_command, lint_evidence = detect_lint(repo, cand, recipe, image, task_dir)
    image_id = docker("image", "inspect", "--format", "{{.Id}}", image).stdout.strip()
    return {
        "lint_command": lint_command,
        "f2p": classified["f2p"],
        "p2p": classified["p2p"],
        "evidence": {
            "image": image,
            "image_id": image_id,
            "build_seconds": build_seconds,
            "isolation": isolation,
            "runs": outcomes,
            "f2p_count": len(classified["f2p"]),
            "p2p_count": len(classified["p2p"]),
            "flaky": classified["flaky"],
            "both_failing_count": len(classified["both_failing"]),
            "both_failing": classified["both_failing"],
            "fix_regressions": classified["fix_regressions"],
            "lint": lint_evidence,
            "test_wall_seconds": {
                side: [o["wall_seconds"] for o in outcomes if o["side"] == side] for side in ("base", "fix")
            },
            "recipe": {key: recipe[key] for key in ("kind", "groups", "apt", "build_env") if key in recipe},
            "base_derivation": cand["base_derivation"],
            "issue_prose_words": cand["issue_prose_words"],
            "non_test_lines": cand["non_test_lines"],
        },
    }


def manifest_task(cand, validated, recipe):
    return {
        "task_id": cand["task_id"],
        "repo": cand["repo"],
        "repo_url": cand["repo_url"],
        "license": cand["license"],
        "language": cand["language"].lower(),
        "pr_url": cand["pr_url"],
        "issue_url": cand["issue_url"],
        "issue_sha256": cand["issue_sha256"],
        "base_sha": cand["base_sha"],
        "fix_sha": cand["fix_sha"],
        "merged_at": cand["merged_at"],
        "gold_files": cand["gold_files"],
        "test_files": cand["test_files"],
        "f2p": validated["f2p"],
        "p2p": validated["p2p"],
        "test_command": recipe["test_command"],
        "lint_command": validated["lint_command"],
        "deps_image": "olivium-bench-deps-%s:v1" % cand["task_id"],
        "markdown_files_count": cand["markdown_files_count"],
    }


def manifest_checksum(manifest):
    payload = {"selection": manifest["selection"], "tasks": manifest["tasks"]}
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def rejection_record(repo, pr, stage, reason, detail):
    return {
        "repo": repo,
        "pr_number": pr["number"],
        "pr_url": "https://github.com/%s/pull/%d" % (repo, pr["number"]),
        "merged_at": pr["merged_at"],
        "stage": stage,
        "reason": reason,
        "detail": detail or {},
    }


def build_relaxations(args):
    relaxations = []
    if args.merged_after != RULES["merged_after"]:
        relaxations.append(
            {"kind": "merged_after", "pre_registered": RULES["merged_after"], "used": args.merged_after, "reason": args.relaxation_note}
        )
    extra = [r for r in args.repos if r not in RULES["start_repositories"]]
    if extra:
        relaxations.append(
            {"kind": "extra_repositories", "added": extra, "min_stars": RULES["extra_repository_min_stars"], "reason": args.relaxation_note}
        )
    return relaxations


def selection_main(argv):
    parser = argparse.ArgumentParser(description="Select and validate the value benchmark task corpus.")
    parser.add_argument("--work", required=True, help="scratch directory for clones, patches, logs and validation output")
    parser.add_argument("--out", default=HERE, help="directory that receives manifest.json and rejected.jsonl")
    parser.add_argument("--merged-after", default=RULES["merged_after"])
    parser.add_argument("--repos", nargs="*", default=RULES["start_repositories"])
    parser.add_argument("--relaxation-note", default="too few eligible tasks under the pre-registered rule")
    parser.add_argument("--max-tasks", type=int, default=RULES["max_tasks"])
    parser.add_argument("--max-per-repo", type=int, default=RULES["max_per_repository"])
    parser.add_argument("--static-only", action="store_true", help="apply the static rule and report survivors only")
    parser.add_argument("--resume", action="store_true", help="reuse validation results already in the work directory")
    parser.add_argument("--refresh", action="store_true", help="ignore the GitHub API cache")
    parser.add_argument("--jobs", type=int, default=2, help="parallel test containers (1800 MB each, at most 2)")
    args = parser.parse_args(argv)
    if args.jobs not in (1, 2):
        parser.error("--jobs must be 1 or 2 to stay within the benchmark memory budget")

    work = os.path.abspath(args.work)
    for directory in ("tasks", "validation"):
        os.makedirs(os.path.join(work, directory), exist_ok=True)

    def log(message):
        print("[%s] %s" % (utc_now(), message), flush=True)

    api = Api(os.path.join(work, "api-cache"), refresh=args.refresh)
    rejected = []
    queues = {}
    repo_objects = {}
    for full_name in args.repos:
        meta = repo_metadata(api, full_name)
        if meta["license"] not in RULES["licenses"]:
            log("repository rejected, licence %s: %s" % (meta["license"], full_name))
            rejected.append({"repo": full_name, "stage": "repository", "reason": "licence_not_allowed", "detail": {"license": meta["license"]}})
            continue
        if meta["language"] not in RULES["languages"]:
            log("repository rejected, language %s: %s" % (meta["language"], full_name))
            rejected.append({"repo": full_name, "stage": "repository", "reason": "language_not_allowed", "detail": {"language": meta["language"]}})
            continue
        if full_name not in RULES["start_repositories"] and meta["stars"] <= RULES["extra_repository_min_stars"]:
            rejected.append({"repo": full_name, "stage": "repository", "reason": "too_few_stars", "detail": {"stars": meta["stars"]}})
            continue
        if full_name not in RECIPES:
            rejected.append({"repo": full_name, "stage": "repository", "reason": "no_install_recipe", "detail": {}})
            continue
        repo = Repo(full_name, os.path.join(work, "clones"))
        repo_objects[full_name] = repo
        pulls = walk_merged_pulls(api, full_name, args.merged_after)
        log("%s: %d pull requests merged after %s" % (full_name, len(pulls), args.merged_after))
        queue = collections.deque()
        for pr in pulls:
            try:
                if pr.get("merge_commit_sha") and not os.path.isdir(repo.path):
                    repo.ensure_clone()
                cand = evaluate_pull(api, repo, meta, pr)
                queue.append((cand, pr))
            except Rejection as exc:
                rejected.append(rejection_record(full_name, pr, "static", exc.reason, exc.detail))
        queues[full_name] = queue
        log("%s: %d static survivors" % (full_name, len(queue)))

    survivors = {name: [item[0]["task_id"] for item in q] for name, q in queues.items()}
    detail = {name: [item[0] for item in q] for name, q in queues.items()}
    write_text(os.path.join(work, "static_survivors.json"), json.dumps(detail, indent=2) + "\n")
    if args.static_only:
        write_rejected(args.out, rejected)
        log("static-only run: %s" % json.dumps({k: len(v) for k, v in survivors.items()}))
        return 0

    selected = []
    evidence = {}
    accepted_per_repo = collections.Counter()
    active = True
    while len(selected) < args.max_tasks and active:
        active = False
        for full_name in args.repos:
            if len(selected) >= args.max_tasks:
                break
            queue = queues.get(full_name)
            if not queue or accepted_per_repo[full_name] >= args.max_per_repo:
                continue
            active = True
            while queue:
                cand, pr = queue.popleft()
                record_path = os.path.join(work, "validation", cand["task_id"] + ".json")
                try:
                    if args.resume and os.path.exists(record_path):
                        with open(record_path, encoding="utf-8") as fh:
                            saved = json.load(fh)
                        if saved.get("status") == "rejected":
                            raise Rejection(saved["reason"], saved.get("detail"))
                        validated = saved["validated"]
                        recipe = recipe_for(repo_objects[full_name], cand)
                        log("reusing validation for %s" % cand["task_id"])
                    else:
                        recipe = recipe_for(repo_objects[full_name], cand)
                        log("validating %s" % cand["task_id"])
                        validated = validate_candidate(repo_objects[full_name], cand, recipe, work, args.jobs, log)
                        write_text(record_path, json.dumps({"status": "accepted", "validated": validated}, indent=2) + "\n")
                except Rejection as exc:
                    write_text(record_path, json.dumps({"status": "rejected", "reason": exc.reason, "detail": exc.detail}, indent=2) + "\n")
                    rejected.append(rejection_record(full_name, pr, "validation", exc.reason, exc.detail))
                    log("rejected %s: %s %s" % (cand["task_id"], exc.reason, exc.detail))
                    continue
                selected.append(manifest_task(cand, validated, recipe))
                evidence[cand["task_id"]] = validated["evidence"]
                accepted_per_repo[full_name] += 1
                log("accepted %s (%d/%d)" % (cand["task_id"], len(selected), args.max_tasks))
                break
    rejected.sort(key=lambda r: (r.get("repo", ""), r.get("stage", ""), r.get("pr_number", 0)))
    write_rejected(args.out, rejected)
    manifest = {
        "frozen_at": utc_now(),
        "checksum": "",
        "selection": {"rules": dict(RULES, repositories_used=list(args.repos)), "relaxations": build_relaxations(args)},
        "tasks": selected,
    }
    manifest["checksum"] = manifest_checksum(manifest)
    write_text(os.path.join(args.out, "manifest.json"), json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    write_text(
        os.path.join(args.out, "validation.json"),
        json.dumps(
            {
                "selected": [t["task_id"] for t in selected],
                # Passed the static rule, but selection stopped before reaching them.
                # They are not rejected: nothing was decided about them.
                "not_reached": sorted(item[0]["task_id"] for q in queues.values() for item in q),
                "evidence": evidence,
            },
            indent=2,
            ensure_ascii=False,
        )
        + "\n",
    )
    log("manifest written: %d tasks, checksum %s" % (len(selected), manifest["checksum"]))
    return 0 if len(selected) == args.max_tasks else 2


def write_rejected(out_dir, rejected):
    with open(os.path.join(out_dir, "rejected.jsonl"), "w", encoding="utf-8") as fh:
        for record in rejected:
            fh.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")


def safe_extract_tar(archive_path, destination):
    """Extract a git archive tar, refusing paths or links that leave destination."""
    import tarfile

    root = os.path.realpath(destination)
    skipped = []
    with tarfile.open(archive_path, "r:") as tar:
        for member in tar.getmembers():
            name = member.name
            if name.startswith("/") or ".." in name.split("/"):
                skipped.append(name)
                continue
            target = os.path.join(root, name)
            if member.isdir():
                os.makedirs(target, exist_ok=True)
                continue
            if member.issym() or member.islnk():
                link = os.path.realpath(os.path.join(os.path.dirname(target), member.linkname))
                if not (link == root or link.startswith(root + os.sep)):
                    skipped.append(name)
                    continue
                os.makedirs(os.path.dirname(target), exist_ok=True)
                if not os.path.lexists(target):
                    os.symlink(member.linkname, target)
                continue
            if not member.isfile():
                skipped.append(name)
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            source = tar.extractfile(member)
            with open(target, "wb") as out:
                shutil.copyfileobj(source, out)
            os.chmod(target, member.mode & 0o755 | 0o644)
    return skipped


def materialize_task(task, out, api, clones_dir, include_snapshot=True, refresh=False):
    task_dir = os.path.join(out, task["task_id"])
    complete = os.path.join(task_dir, ".complete")
    if os.path.exists(complete) and not refresh:
        return {"task_id": task["task_id"], "status": "already_materialized"}
    if os.path.isdir(task_dir):
        shutil.rmtree(task_dir)
    os.makedirs(task_dir)
    repo = Repo(task["repo"], clones_dir)
    repo.ensure_clone()
    for sha, label in ((task["base_sha"], "base_sha"), (task["fix_sha"], "fix_sha")):
        if not repo.ensure_commit(sha):
            raise RuntimeError("%s %s not found in %s" % (label, sha, task["repo"]))
    number = int(task["issue_url"].rstrip("/").rsplit("/", 1)[1])
    issue = api.get("repos/%s/issues/%d" % (task["repo"], number))
    if issue is None:
        raise RuntimeError("issue not found: %s" % task["issue_url"])
    text = issue_markdown(issue.get("title"), issue.get("body"))
    digest = sha256_text(text)
    if digest != task["issue_sha256"]:
        raise RuntimeError(
            "%s: issue text changed since the manifest was frozen (expected %s, got %s)"
            % (task["task_id"], task["issue_sha256"], digest)
        )
    write_text(os.path.join(task_dir, "issue.md"), text)
    write_text(os.path.join(task_dir, "test.patch"), repo.patch(task["base_sha"], task["fix_sha"], task["test_files"]))
    write_text(os.path.join(task_dir, "gold.patch"), repo.patch(task["base_sha"], task["fix_sha"], task["gold_files"]))
    skipped = []
    if include_snapshot:
        archive = os.path.join(task_dir, "snapshot.tar")
        repo.git("archive", "--format=tar", "-o", archive, task["base_sha"], timeout=300)
        snapshot = os.path.join(task_dir, "repo")
        os.makedirs(snapshot)
        skipped = safe_extract_tar(archive, snapshot)
        os.remove(archive)
    write_text(complete, utc_now() + "\n")
    return {"task_id": task["task_id"], "status": "materialized", "skipped_archive_members": skipped}


def materialize_main(argv):
    parser = argparse.ArgumentParser(description="Rebuild third-party task material from manifest references.")
    parser.add_argument("--manifest", default=os.path.join(HERE, "manifest.json"))
    parser.add_argument("--out", required=True, help="scratch directory; one subdirectory per task is created")
    parser.add_argument("--tasks", default="", help="comma-separated task ids (default: all)")
    parser.add_argument("--clones", default="", help="directory for bare clones (default: <out>/.clones)")
    parser.add_argument("--no-snapshot", action="store_true", help="skip the repository snapshot")
    parser.add_argument("--refresh", action="store_true", help="rebuild tasks already materialized")
    args = parser.parse_args(argv)
    with open(args.manifest, encoding="utf-8") as fh:
        manifest = json.load(fh)
    if manifest_checksum(manifest) != manifest.get("checksum"):
        print("manifest checksum mismatch: refusing to materialize", file=sys.stderr)
        return 3
    wanted = {t for t in args.tasks.split(",") if t}
    tasks = [t for t in manifest["tasks"] if not wanted or t["task_id"] in wanted]
    missing = wanted - {t["task_id"] for t in tasks}
    if missing:
        print("unknown task ids: %s" % ",".join(sorted(missing)), file=sys.stderr)
        return 3
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    clones = os.path.abspath(args.clones) if args.clones else os.path.join(out, ".clones")
    api = Api(os.path.join(out, ".api-cache"))
    results = [materialize_task(t, out, api, clones, not args.no_snapshot, args.refresh) for t in tasks]
    print(json.dumps({"manifest_checksum": manifest["checksum"], "tasks": results}, indent=2))
    return 0
