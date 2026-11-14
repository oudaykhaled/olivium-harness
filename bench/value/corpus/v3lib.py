"""Rules, install recipes and Docker validation for benchmark v3 (PROTOCOL-v3.md).

Standard library only (host Python may be 3.9). Load it from select_v3.py, which
removes this directory from sys.path first (select.py here shadows a standard
library module). Everything read from GitHub or from a candidate repository is
data: it is parsed, hashed and stored outside the repository, and never executed
on the host. Candidate code, tests and install scripts run only in Docker
containers and images named olivium-bench-* and labelled olivium-bench=1.
"""

from __future__ import annotations

import collections
import concurrent.futures
import configparser
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
import types

import corpus_lib as v2

# ---------------------------------------------------------------- fixed values

SEED = "olivium-bench-v3-20261111"
LANGUAGES = ["Python", "JavaScript", "TypeScript"]
LICENCES_SEARCH = ["mit", "apache-2.0", "bsd-2-clause", "bsd-3-clause", "isc"]
LICENCES_SPDX = ["MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "ISC"]
STARS = (100, 3000)
FALLBACK_STARS = (50, 5000)
PUSHED_AFTER = "2026-07-31"
CUTOFF = "2026-06-30"
MERGED_FROM = "2026-07-31T00:00:00Z"
ISSUE_FROM = "2026-07-01T00:00:00Z"
EXCLUDED_OWNERS = ["pallets", "pallets-eco", "python-attrs", "expressjs"]
MIN_SOURCE_FILES = 150
FALLBACK_MIN_SOURCE_FILES = 100
MIN_PROSE_WORDS = 20
T3 = {"min_code_files": 2, "min_code_lines": 25, "max_code_files": 8, "max_code_lines": 400}
MAX_PER_REPO = 2
FALLBACK_MAX_PER_REPO = 3
POOL_TARGET = 48
POOL_MINIMUM = 24
POOL_FLOOR = 12
TEST_TIMEOUT = 300
REPEATS = 3
# Change log of 2026-11-11 (walk cost): a repository stops after this many T5 rejections in a row.
T5_STREAK_LIMIT = 3

CODE_EXTENSIONS = (".py", ".pyi", ".pyx", ".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts", ".vue", ".svelte")
JS_EXTENSIONS = ("js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts")
TEST_DIRS = {"tests", "test", "__tests__", "__test__", "testing", "spec", "specs"}
TEST_FILE_RE = re.compile(r"^(test_.*\.py|.*_test\.py|conftest\.py|.*\.(test|spec)\.(%s))$" % "|".join(JS_EXTENSIONS))
VENDOR_DIRS = {"node_modules", "vendor", "third_party", "dist", "build", "site-packages"}
DEPENDENCY_BASENAMES = set(v2.DEPENDENCY_BASENAMES) | {"bun.lock", "bun.lockb"}

PYTHON_IMAGES = ["3.12", "3.13", "3.11", "3.14", "3.10"]
NODE_IMAGE = "node:22"
TEST_GROUP_NAMES = ["test", "tests", "testing"]
REQUIREMENT_FILES = [
    "requirements-test.txt", "requirements_test.txt", "test-requirements.txt", "test_requirements.txt",
    "requirements-tests.txt", "requirements-dev.txt", "requirements_dev.txt", "dev-requirements.txt",
    "requirements/test.txt", "requirements/tests.txt", "requirements/testing.txt", "requirements/dev.txt",
    "tests/requirements.txt",
]
PINS = {
    "poetry": "2.5.1",
    "pip": "25.3",
    "pytest": "8.4.2",
    "jest-junit": "16.0.0",
    "yarn-classic": "1.22.22",
    "pnpm-by-lock": {"9": "10.34.9", "6": "8.15.9", "5": "7.33.7"},
}
RESULTS = "/work/test-results/results.xml"
PY_TEST_COMMAND = (
    "mkdir -p /work/test-results && "
    "python -m pytest -p no:cacheprovider -q --tb=short --continue-on-collection-errors --junitxml=%s" % RESULTS
)
PYTHON_KINDS = ("uv", "uv-extra", "poetry", "pip-group", "pip-extra", "pip-requirements")
NODE_KINDS = ("npm", "pnpm", "yarn", "yarn-berry", "npm-nolock")

RULE_TEXT = {
    "R1": "primary language Python, JavaScript or TypeScript",
    "R2": "100 to 3,000 stars; not archived; not a fork; MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause or ISC",
    "R3": "order by SHA-256 of seed + newline + lower-case full name",
    "R4": "excluded owners and corpus/dev-repos-v3.txt",
    "R5": "at least 150 tracked non-test source files at the base commit",
    "R6": "install recipe from the fixed list applies at the base commit",
    "T1": "merged into the default branch on or after 2026-07-31; issue opened on or after 2026-07-01",
    "T2": "linked same-repository issue (closing keyword or closingIssuesReferences) with >= 20 prose words, not reused",
    "T3": "fix shape: >= 2 non-test code files or >= 25 code lines; <= 8 files, <= 400 lines; >= 1 code test file; no dependency or binary code change",
    "T4": "issue title and body name no fixed non-test code file (path or whole-token file name)",
    "T5": "Docker: 3/3 fail before, 3/3 pass after, 300 s, no network; isolation probe; the real fix graded solved by the scoring grader (grade.sh, protection on); a repository stops after 3 T5 rejections in a row",
    "T6": "at most 2 tasks per repository; at least 8 repositories",
}


class Reject(Exception):
    """A candidate fails a rule. rule is a protocol id (R1-R6, T1-T6)."""

    def __init__(self, rule, reason, detail=None):
        Exception.__init__(self, "%s %s" % (rule, reason))
        self.rule = rule
        self.reason = reason
        self.detail = detail or {}


# ---------------------------------------------------------------- path rules

def repo_key(full_name):
    return hashlib.sha256((SEED + "\n" + full_name.lower()).encode("utf-8")).hexdigest()


def task_id_for(full_name, number):
    raw = ("%s-%d" % (full_name.replace("/", "-"), number)).lower()
    raw = re.sub(r"[^a-z0-9-]", "-", raw)
    return re.sub(r"-{2,}", "-", raw).strip("-")


def is_test_path(path):
    parts = path.split("/")
    if any(segment in TEST_DIRS for segment in parts[:-1]):
        return True
    return bool(TEST_FILE_RE.match(parts[-1]))


def is_code_path(path):
    return path.lower().endswith(CODE_EXTENSIONS)


def is_dependency_path(path):
    return os.path.basename(path) in DEPENDENCY_BASENAMES or bool(v2.DEPENDENCY_RE.search(path))


def is_source_file(path):
    if not is_code_path(path) or is_test_path(path) or path.lower().endswith(".min.js"):
        return False
    return not any(segment in VENDOR_DIRS for segment in path.split("/")[:-1])


def shape(entries):
    """entries: [(path, added_or_None, deleted_or_None)]. Returns the T3 facts."""
    tests = [p for p, _a, _d in entries if is_test_path(p)]
    non_tests = [(p, a, d) for p, a, d in entries if not is_test_path(p)]
    code = [(p, a, d) for p, a, d in non_tests if is_code_path(p)]
    return {
        "test_files": sorted(tests),
        "code_test_files": sorted(p for p in tests if is_code_path(p)),
        "gold_files": sorted(p for p, _a, _d in non_tests),
        "code_files": sorted(p for p, _a, _d in code),
        "code_lines": sum((a or 0) + (d or 0) for _p, a, d in code),
        "binary_code": sorted(p for p, a, d in code if a is None or d is None),
        "dependency": sorted(p for p, _a, _d in non_tests if is_dependency_path(p)),
    }


def check_t3(facts):
    if facts["dependency"]:
        raise Reject("T3", "dependency_change", {"count": len(facts["dependency"])})
    if not facts["code_test_files"]:
        raise Reject("T3", "no_code_test_file")
    if facts["binary_code"]:
        raise Reject("T3", "binary_code_change")
    files, lines = len(facts["code_files"]), facts["code_lines"]
    if files == 0:
        raise Reject("T3", "no_code_change")
    if files < T3["min_code_files"] and lines < T3["min_code_lines"]:
        raise Reject("T3", "fix_too_small", {"code_files": files, "code_lines": lines})
    if files > T3["max_code_files"]:
        raise Reject("T3", "too_many_code_files", {"code_files": files})
    if lines > T3["max_code_lines"]:
        raise Reject("T3", "too_many_code_lines", {"code_lines": lines})


def api_entries(files):
    """PR file list -> numstat-like entries; a rename counts as delete + add (git --no-renames)."""
    entries = []
    for item in files:
        additions, deletions = item.get("additions", 0), item.get("deletions", 0)
        if item.get("status") == "renamed" and item.get("previous_filename"):
            entries.append((item["previous_filename"], 0, deletions))
            entries.append((item["filename"], additions, 0))
        else:
            entries.append((item["filename"], additions, deletions))
    return entries


def names_a_file(text, code_files):
    """T4: True if the text contains a fixed code file's path or whole-token file name."""
    lowered = (text or "").lower()
    for path in code_files:
        for needle in {path.lower(), os.path.basename(path).lower()}:
            pattern = r"(?<![A-Za-z0-9_])" + re.escape(needle) + r"(?![A-Za-z0-9_])"
            if re.search(pattern, lowered):
                return True
    return False


# ---------------------------------------------------------------- tiny TOML reading

def toml_tables(text):
    """{table header: [(key, raw value first line)]} for simple TOML (no parser on host 3.9).

    Lines inside a multi-line array or inline table are skipped by bracket depth.
    """
    tables = collections.OrderedDict()
    current = ""
    tables[current] = []
    depth = 0
    for line in (text or "").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if depth == 0:
            header = re.match(r"^\[\[?\s*([^\]]+?)\s*\]\]?\s*(#.*)?$", stripped)
            if header:
                current = re.sub(r"\s*\.\s*", ".", header.group(1)).replace('"', "").replace("'", "")
                tables.setdefault(current, [])
                continue
            key = re.match(r"""^["']?([A-Za-z0-9_.-]+)["']?\s*=\s*(.*)$""", stripped)
            if key:
                tables[current].append((key.group(1), key.group(2)))
        depth = max(0, depth + _bracket_balance(stripped))
    return tables


def _bracket_balance(line):
    """Net count of [ and { minus ] and } outside quoted strings and comments."""
    balance, quote = 0, None
    i = 0
    while i < len(line):
        ch = line[i]
        if quote:
            if ch == "\\" and quote == '"':
                i += 2
                continue
            if ch == quote:
                quote = None
        elif ch in ("'", '"'):
            quote = ch
        elif ch == "#":
            break
        elif ch in "[{":
            balance += 1
        elif ch in "]}":
            balance -= 1
        i += 1
    return balance


def toml_string(raw):
    match = re.match(r"""^(["'])(.*?)\1""", (raw or "").strip())
    return match.group(2) if match else None


def toml_keys(tables, table):
    return [key for key, _raw in tables.get(table, [])]


def toml_value(tables, table, key):
    for name, raw in tables.get(table, []):
        if name == key:
            return toml_string(raw)
    return None


def inline_table_keys(raw):
    match = re.match(r"^\{(.*)\}\s*$", (raw or "").strip())
    if not match:
        return []
    return re.findall(r"""(?:^|,)\s*["']?([A-Za-z0-9_.-]+)["']?\s*=""", match.group(1))


def python_versions_allowed(spec):
    """Images from PYTHON_IMAGES that a requires-python string allows (major.minor check)."""
    if not spec:
        return list(PYTHON_IMAGES)
    clauses = [c.strip() for c in spec.split(",") if c.strip()]

    def version(text):
        parts = re.findall(r"\d+", text)
        return tuple(int(p) for p in parts[:3]) if parts else None

    def allows(image, clause):
        match = re.match(r"^(~=|==|!=|>=|<=|>|<)\s*([0-9][0-9.*]*)$", clause)
        if not match:
            return True
        op, raw = match.groups()
        wildcard = raw.endswith(".*")
        target = version(raw.replace(".*", ""))
        if target is None:
            return True
        target = (target + (0, 0, 0))[:3]
        mine = tuple(int(p) for p in image.split("."))
        low, high = mine + (0,), mine + (99,)
        if op == ">=":
            return high >= target
        if op == ">":
            return high > target
        if op == "<":
            return low < target
        if op == "<=":
            return low <= target
        if op == "==":
            return mine == target[:2]
        if op == "!=":
            return not (mine == target[:2] and (wildcard or raw.count(".") == 1))
        if op == "~=":
            return high >= target and mine[0] == target[0]
        return True

    return [image for image in PYTHON_IMAGES if all(allows(image, c) for c in clauses)]


# ---------------------------------------------------------------- recipes (R6)

def _first_group(names):
    found = [n for n in TEST_GROUP_NAMES if n in names]
    if found:
        return found
    return ["dev"] if "dev" in names else []


def python_recipe(show, paths):
    """Returns a recipe dict or raises Reject R6. show(path) reads a file at the base commit."""
    pyproject = show("pyproject.toml") if "pyproject.toml" in paths else None
    tables = toml_tables(pyproject)
    groups = toml_keys(tables, "dependency-groups")
    extras = toml_keys(tables, "project.optional-dependencies")
    for key, raw in tables.get("project", []):
        if key == "optional-dependencies":
            extras = extras + inline_table_keys(raw)
        elif key.startswith("optional-dependencies."):
            extras = extras + [key.split(".", 1)[1]]
    setup_cfg = show("setup.cfg") if "setup.cfg" in paths else None
    cfg_extras, cfg_name = [], None
    if setup_cfg:
        parser = configparser.RawConfigParser(strict=False)
        try:
            parser.read_string(setup_cfg)
            if parser.has_section("options.extras_require"):
                cfg_extras = list(parser.options("options.extras_require"))
            if parser.has_option("metadata", "name"):
                cfg_name = parser.get("metadata", "name").strip()
        except (configparser.Error, ValueError):
            pass
    poetry_groups = sorted({t.split(".")[3] for t in tables if t.startswith("tool.poetry.group.") and len(t.split(".")) >= 4})
    dist = toml_value(tables, "project", "name") or toml_value(tables, "tool.poetry", "name") or cfg_name
    requires = toml_value(tables, "project", "requires-python") or toml_value(tables, "tool.poetry.dependencies", "python")
    if requires and requires.startswith("^"):
        requires = ">=" + requires[1:]
    images = python_versions_allowed(requires)
    if not images:
        raise Reject("R6", "python_version_unsupported", {"requires_python": requires})
    installable = "setup.py" in paths or "project" in tables or "build-system" in tables
    recipe = None
    if "uv.lock" in paths and _first_group(groups):
        recipe = {"kind": "uv", "groups": _first_group(groups)}
    elif "uv.lock" in paths and _first_group(extras):
        recipe = {"kind": "uv-extra", "extra": _first_group(extras)[0]}
    elif "poetry.lock" in paths:
        recipe = {"kind": "poetry", "groups": [g for g in TEST_GROUP_NAMES + ["dev"] if g in poetry_groups]}
    elif pyproject and _first_group(groups):
        recipe = {"kind": "pip-group", "groups": _first_group(groups)}
    elif _first_group(extras) or _first_group(cfg_extras):
        recipe = {"kind": "pip-extra", "extra": (_first_group(extras) or _first_group(cfg_extras))[0]}
    else:
        for name in REQUIREMENT_FILES:
            if name in paths:
                recipe = {"kind": "pip-requirements", "file": name, "base_requirements": "requirements.txt" in paths,
                          "install_project": installable}
                break
    if recipe is None:
        raise Reject("R6", "no_install_recipe", {"language": "Python"})
    nondefault = any(p in paths for p in ("tox.ini", "noxfile.py", "Makefile"))
    nondefault = nondefault or any(t.startswith(("tool.tox", "tool.nox", "tool.hatch.envs", "tool.poe")) for t in tables)
    recipe.update({
        "language": "python",
        "base_image": "python:%s" % images[0],
        "dists": [dist] if dist else [],
        "imports": [re.sub(r"[-.]", "_", dist).lower()] if dist else [],
        "toolchain_nondefault": bool(nondefault),
        "test_command": PY_TEST_COMMAND,
    })
    return recipe


SIMPLE_ENV = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=\S*$")
FORBIDDEN_SHELL = ("&&", "||", ";", "|", ">", "<", "$(", "`", "\n")
WATCH_FLAGS = {"--watch", "--watchAll", "-w", "--watch-all"}


def parse_test_script(script, runner):
    """Return (env_tokens, runner_args) if scripts.test is the single-command form, else None."""
    if not script or any(token in script for token in FORBIDDEN_SHELL):
        return None
    try:
        tokens = shlex.split(script)
    except ValueError:
        return None
    env = []
    while tokens and SIMPLE_ENV.match(tokens[0]):
        env.append(tokens.pop(0))
    if tokens and tokens[0] == "cross-env":
        tokens.pop(0)
        while tokens and SIMPLE_ENV.match(tokens[0]):
            env.append(tokens.pop(0))
    if tokens and tokens[0] == "npx":
        tokens.pop(0)
    if not tokens:
        return None
    if runner == "node-test":
        if tokens[0] != "node" or "--test" not in tokens:
            return None
        args = [t for t in tokens[1:] if t != "--test"]
    else:
        if tokens[0] != runner:
            return None
        args = tokens[1:]
    return env, args


def _drop_reporter_args(args, names):
    out, skip = [], False
    for arg in args:
        if skip:
            skip = False
            continue
        if arg in WATCH_FLAGS:
            continue
        if any(arg == n for n in names):
            skip = True
            continue
        if any(arg.startswith(n + "=") for n in names):
            continue
        out.append(arg)
    return out


def node_test_command(runner, script):
    parsed = parse_test_script(script, runner)
    env, args = parsed if parsed is not None else ([], [])
    env = [e for e in env if not e.startswith("CI=")]
    prefix = "mkdir -p /work/test-results && CI=true "
    quoted_env = " ".join(shlex.quote(e) for e in env)
    if quoted_env:
        prefix += quoted_env + " "
    if runner == "vitest":
        args = _drop_reporter_args(args, ["--reporter", "--outputFile"])
        if args and args[0] in ("watch", "dev"):
            args = args[1:]
        if not args or args[0] != "run":
            args = ["run"] + args
        tail = ["--reporter=default", "--reporter=junit", "--outputFile.junit=" + RESULTS]
        command = "node_modules/.bin/vitest " + " ".join(shlex.quote(a) for a in args + tail)
    elif runner == "jest":
        args = _drop_reporter_args(args, ["--reporters", "--json", "--outputFile"])
        tail = ["--ci", "--watchAll=false", "--reporters=default", "--reporters=/opt/olivium-reporters/node_modules/jest-junit"]
        prefix += ("JEST_JUNIT_OUTPUT_FILE=%s JEST_JUNIT_CLASSNAME='{filepath}' "
                   "JEST_JUNIT_TITLE='{classname} {title}' JEST_JUNIT_ANCESTOR_SEPARATOR=' > ' " % RESULTS)
        command = "node_modules/.bin/jest " + " ".join(shlex.quote(a) for a in args + tail)
    elif runner == "mocha":
        args = _drop_reporter_args(args, ["--reporter", "-R", "--reporter-option", "--reporter-options", "-O"])
        tail = ["--reporter", "xunit", "--reporter-option", "output=" + RESULTS]
        command = "node_modules/.bin/mocha " + " ".join(shlex.quote(a) for a in args + tail)
    elif runner == "node-test":
        args = _drop_reporter_args(args, ["--test-reporter", "--test-reporter-destination"])
        head = ["--test"] + args
        tail = ["--test-reporter=junit", "--test-reporter-destination=" + RESULTS]
        command = "node " + " ".join(shlex.quote(a) for a in head + tail)
    else:
        raise ValueError(runner)
    return prefix + command, parsed is not None


def node_recipe(show, paths):
    raw = show("package.json") if "package.json" in paths else None
    if raw is None:
        raise Reject("R6", "no_install_recipe", {"why": "no root package.json"})
    try:
        package = json.loads(raw)
    except ValueError:
        raise Reject("R6", "no_install_recipe", {"why": "package.json does not parse"})
    if not isinstance(package, dict):
        raise Reject("R6", "no_install_recipe", {"why": "package.json is not an object"})
    manager_field = package.get("packageManager") if isinstance(package.get("packageManager"), str) else ""
    yarnrc = show(".yarnrc.yml") if ".yarnrc.yml" in paths else ""
    recipe = None
    if "package-lock.json" in paths or "npm-shrinkwrap.json" in paths:
        recipe = {"kind": "npm"}
    elif "pnpm-lock.yaml" in paths:
        version = None
        match = re.match(r"^pnpm@(\d+\.\d+\.\d+)", manager_field)
        if match:
            version = match.group(1)
        else:
            lock_head = (show("pnpm-lock.yaml") or "")[:400]
            lock = re.search(r"lockfileVersion:\s*'?\"?(\d+)", lock_head)
            if lock:
                version = PINS["pnpm-by-lock"].get(lock.group(1))
        if not version:
            raise Reject("R6", "no_install_recipe", {"why": "pnpm version unknown"})
        recipe = {"kind": "pnpm", "manager_version": version}
    elif "yarn.lock" in paths:
        head = (show("yarn.lock") or "")[:600]
        if "__metadata:" in head:
            match = re.match(r"^yarn@(\d+\.\d+\.\d+)", manager_field)
            if not match:
                raise Reject("R6", "no_install_recipe", {"why": "yarn berry without packageManager version"})
            if not re.search(r"^\s*nodeLinker:\s*['\"]?node-modules", yarnrc or "", re.MULTILINE):
                raise Reject("R6", "no_install_recipe", {"why": "yarn plug'n'play"})
            recipe = {"kind": "yarn-berry", "manager_version": match.group(1)}
        else:
            recipe = {"kind": "yarn", "manager_version": PINS["yarn-classic"]}
    elif "bun.lock" in paths or "bun.lockb" in paths:
        raise Reject("R6", "no_install_recipe", {"why": "bun lock only"})
    else:
        recipe = {"kind": "npm-nolock"}
    deps = {}
    for field in ("dependencies", "devDependencies"):
        if isinstance(package.get(field), dict):
            deps.update(package[field])
    scripts = package.get("scripts") if isinstance(package.get("scripts"), dict) else {}
    script = scripts.get("test") if isinstance(scripts.get("test"), str) else ""
    runner = None
    for name in ("vitest", "jest", "mocha"):
        if name in deps:
            runner = name
            break
    if runner is None and re.search(r"(^|[\s;&|])node\s+([^&|;]*\s)?--test\b", script or ""):
        runner = "node-test"
    if runner is None:
        raise Reject("R6", "no_install_recipe", {"why": "no junit-capable runner"})
    command, simple = node_test_command(runner, script)
    workspaces = "workspaces" in package or "pnpm-workspace.yaml" in paths
    name = package.get("name") if isinstance(package.get("name"), str) else None
    recipe.update({
        "language": "node",
        "base_image": NODE_IMAGE,
        "runner": runner,
        "dists": [name] if name else [],
        "imports": [name] if name else [],
        "toolchain_nondefault": bool(workspaces or recipe["kind"] not in ("npm", "npm-nolock") or not simple),
        "test_command": command,
    })
    return recipe


def recipe_for(language, show, paths):
    if language == "Python":
        return python_recipe(show, paths)
    if language in ("JavaScript", "TypeScript"):
        return node_recipe(show, paths)
    raise Reject("R1", "language_not_allowed", {"language": language})


# ---------------------------------------------------------------- Dockerfile

def dockerfile(cand, recipe):
    kind = recipe["kind"]
    lines = [
        "FROM %s" % recipe["base_image"],
        'LABEL olivium-bench="1" olivium-bench.kind="deps" olivium-bench.protocol="3" olivium-bench.task="%s"' % cand["task_id"],
        "ENV PYTHONDONTWRITEBYTECODE=1 PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 "
        "NPM_CONFIG_UPDATE_NOTIFIER=false NPM_CONFIG_FUND=false NPM_CONFIG_AUDIT=false",
        "RUN git init -q -b main /work/repo",
        "WORKDIR /work/repo",
        "RUN set -eux; git fetch --quiet --no-tags %s %s; git checkout --quiet -B main FETCH_HEAD; "
        'test "$(git rev-parse HEAD)" = "%s"; rm -f .git/FETCH_HEAD .git/ORIG_HEAD; '
        "git reflog expire --expire=now --all; git gc --quiet --prune=now"
        % (cand["repo_url"], cand["base_sha"], cand["base_sha"]),
    ]
    venv_pip = "/opt/venv/bin/python -m pip install --quiet"
    if kind in ("uv", "uv-extra"):
        lines.append("ENV UV_PROJECT_ENVIRONMENT=/opt/venv UV_CACHE_DIR=/tmp/uv-cache UV_PYTHON_DOWNLOADS=never UV_PYTHON=/usr/local/bin/python3")
        if kind == "uv":
            selector = "--no-default-groups " + " ".join("--group %s" % g for g in recipe["groups"])
        else:
            selector = "--extra %s" % recipe["extra"]
        lines.append("RUN set -eux; pip install --quiet uv; uv --version; uv sync --quiet --frozen %s; "
                     "rm -rf /tmp/uv-cache /root/.cache" % selector)
        add_pytest = "uv pip install --quiet --python /opt/venv/bin/python pytest==%s" % PINS["pytest"]
    elif kind == "poetry":
        with_groups = ("--with %s" % ",".join(recipe["groups"])) if recipe["groups"] else ""
        lines.append(
            "RUN set -eux; python -m venv /opt/poetry; /opt/poetry/bin/pip install --quiet poetry==%s; "
            "python -m venv /opt/venv; export VIRTUAL_ENV=/opt/venv PATH=/opt/venv/bin:$PATH POETRY_VIRTUALENVS_CREATE=false; "
            "/opt/poetry/bin/poetry install --no-interaction --no-ansi %s; rm -rf /root/.cache" % (PINS["poetry"], with_groups)
        )
        add_pytest = "%s pytest==%s" % (venv_pip, PINS["pytest"])
    elif kind in ("pip-group", "pip-extra", "pip-requirements"):
        steps = ["python -m venv /opt/venv", "%s pip==%s" % (venv_pip, PINS["pip"])]
        if kind == "pip-group":
            steps.append("%s -e . %s" % (venv_pip, " ".join("--group %s" % g for g in recipe["groups"])))
        elif kind == "pip-extra":
            steps.append("%s -e '.[%s]'" % (venv_pip, recipe["extra"]))
        else:
            if recipe["base_requirements"]:
                steps.append("%s -r requirements.txt" % venv_pip)
            steps.append("%s -r %s" % (venv_pip, shlex.quote(recipe["file"])))
            if recipe["install_project"]:
                steps.append("%s -e ." % venv_pip)
        lines.append("RUN set -eux; %s; rm -rf /root/.cache" % "; ".join(steps))
        add_pytest = "%s pytest==%s" % (venv_pip, PINS["pytest"])
    elif kind in NODE_KINDS:
        lines.append("ENV COREPACK_HOME=/opt/corepack COREPACK_ENABLE_DOWNLOAD_PROMPT=0")
        if kind == "npm":
            install = "npm ci"
        elif kind == "npm-nolock":
            install = "npm install --no-package-lock"
        elif kind == "pnpm":
            install = "npm install -g --force pnpm@%s; pnpm --version; pnpm install --frozen-lockfile" % recipe["manager_version"]
        elif kind == "yarn":
            install = "npm install -g --force yarn@%s; yarn --version; yarn install --frozen-lockfile --non-interactive" % recipe["manager_version"]
        else:
            install = ("corepack enable; corepack prepare yarn@%s --activate; yarn --version; yarn install --immutable; "
                       "chmod -R a+rX /opt/corepack" % recipe["manager_version"])
        lines.append("RUN set -eux; export CI=true; %s; rm -rf /root/.npm /root/.cache" % install)
        if recipe["runner"] == "jest":
            lines.append(
                "RUN set -eux; mkdir -p /opt/olivium-reporters; cd /opt/olivium-reporters; "
                "printf '{\"name\":\"olivium-reporters\",\"private\":true}' > package.json; "
                "npm install --no-package-lock jest-junit@%s; rm -rf /root/.npm" % PINS["jest-junit"]
            )
        add_pytest = None
    else:
        raise ValueError("unknown recipe kind: %s" % kind)
    if kind in PYTHON_KINDS:
        lines.append("ENV VIRTUAL_ENV=/opt/venv PATH=/opt/venv/bin:$PATH")
        lines.append(
            "RUN set -eux; if ! python -m pytest --version >/dev/null 2>&1; then %s; "
            "echo added > /opt/olivium-pytest-added; fi; python -m pytest --version" % add_pytest
        )
    # Untracked build output is hidden from git so it never enters an agent's patch;
    # a change to a tracked file rejects the candidate.
    lines.append(
        "RUN set -eux; test -z \"$(git status --porcelain --untracked-files=no)\"; "
        "git ls-files --others --exclude-standard --directory | sed 's|^|/|' >> .git/info/exclude; "
        "test -z \"$(git status --porcelain)\""
    )
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------- Docker validation

def docker(*args, **kwargs):
    return v2.run(["docker"] + list(args), **kwargs)


def image_name(task_id):
    return "olivium-bench-deps-%s:v1" % task_id


def remove_image(task_id):
    docker("image", "rm", "-f", image_name(task_id), check=False, timeout=300)


class DockerUnresponsive(RuntimeError):
    """The Docker daemon stopped answering while a build ran: infrastructure, not a rule."""


BUILD_TIMEOUT = 1800
DAEMON_PROBE_EVERY = 60
DAEMON_PROBE_LIMIT = 3


def docker_answers():
    try:
        return v2.run(["docker", "version", "--format", "{{.Server.Version}}"], check=False, timeout=20).returncode == 0
    except subprocess.TimeoutExpired:
        return False


def watched_build(cmd, task_dir, attempt, log):
    """docker build with the protocol's 1800 s limit, stopped early if the Docker daemon stops
    answering for 3 probes in a row (a build that overloads the shared Docker VM).
    Change log of 2026-11-11 (walk safety)."""
    out_path = os.path.join(task_dir, "build-%d.out" % attempt)
    started = time.time()
    misses = 0
    with open(out_path, "w", encoding="utf-8", errors="replace") as sink:
        proc = subprocess.Popen(cmd, stdout=sink, stderr=subprocess.STDOUT, universal_newlines=True)
        while True:
            try:
                code = proc.wait(timeout=DAEMON_PROBE_EVERY)
                break
            except subprocess.TimeoutExpired:
                pass
            if time.time() - started > BUILD_TIMEOUT:
                proc.kill()
                proc.wait()
                code = None
                break
            misses = 0 if docker_answers() else misses + 1
            if misses >= DAEMON_PROBE_LIMIT:
                proc.kill()
                proc.wait()
                log("Docker daemon did not answer %d probes in a row during a build; build stopped" % misses)
                sink.flush()
                os.replace(out_path, os.path.join(task_dir, "build-%d.log" % attempt))
                raise DockerUnresponsive("docker daemon unresponsive during image build (attempt %d, %d s)"
                                         % (attempt, round(time.time() - started)))
    with open(out_path, encoding="utf-8", errors="replace") as handle:
        out = handle.read()
    os.remove(out_path)
    err = "build timed out after %d s" % BUILD_TIMEOUT if code is None else ""
    return code, out, err


def build_image(cand, recipe, task_dir, log):
    text = dockerfile(cand, recipe)
    v2.write_text(os.path.join(task_dir, "Dockerfile"), text)
    context = os.path.join(task_dir, "context")
    os.makedirs(context, exist_ok=True)
    image = image_name(cand["task_id"])
    attempts = []
    for attempt in (1, 2):
        log("building %s (attempt %d)" % (image, attempt))
        started = time.time()
        code, out, err = watched_build(["docker", "build", "--progress=plain", "--label", "olivium-bench=1", "-t", image,
                                        "-f", os.path.join(task_dir, "Dockerfile"), context], task_dir, attempt, log)
        seconds = round(time.time() - started, 1)
        v2.write_text(os.path.join(task_dir, "build-%d.log" % attempt), (out or "") + "\n" + (err or ""))
        attempts.append({"exit": code, "seconds": seconds})
        if code == 0:
            return image, attempts
    raise Reject("T5", "image_build_failed", {"attempts": attempts})


def probe(cand, recipe, image, task_dir):
    probe_recipe = {"kind": "npm" if recipe["language"] == "node" else "python",
                    "dists": recipe["dists"], "imports": recipe["imports"]}
    try:
        facts = v2.probe_image(cand, probe_recipe, image, task_dir)
    except v2.Rejection as exc:
        raise Reject("T5", exc.reason, exc.detail)
    flag = docker("run", "--rm", "--network", "none", "--label", "olivium-bench=1",
                  "--name", "olivium-bench-v3flag-%s" % cand["task_id"], "--entrypoint", "/bin/sh", image,
                  "-c", "test -e /opt/olivium-pytest-added && echo yes || echo no", check=False, timeout=120)
    facts["pytest_added"] = flag.stdout.strip() == "yes"
    return facts


JOB_TEST = v2.JOB_TEST


def run_tests_once(cand, recipe, image, task_dir, side, index):
    run_dir = os.path.join(task_dir, "runs", "%s-%d" % (side, index))
    patch_dir = os.path.join(run_dir, "patches")
    os.makedirs(patch_dir, exist_ok=True)
    shutil.copy(os.path.join(task_dir, "test.patch"), os.path.join(patch_dir, "1-test.patch"))
    if side == "fix":
        shutil.copy(os.path.join(task_dir, "gold.patch"), os.path.join(patch_dir, "2-gold.patch"))
    script = os.path.join(run_dir, "job.sh")
    v2.write_text(script, JOB_TEST)
    command_file = os.path.join(run_dir, "command.txt")
    v2.write_text(command_file, recipe["test_command"])
    result = v2.container_run(
        "olivium-bench-v3val-%s-%s-%d" % (cand["task_id"], side, index), image, script,
        files={patch_dir: "/work/patches", command_file: "/work/command.txt"},
        timeout=TEST_TIMEOUT + 30, results_dir=os.path.join(run_dir, "results"),
    )
    v2.write_text(os.path.join(run_dir, "docker.log"), (result["stdout"] or "") + "\n" + (result["stderr"] or ""))
    outcome = {"side": side, "run": index, "wall_seconds": round(result["wall"], 2), "timed_out": result["timed_out"]}
    if result["timed_out"] or result["wall"] > TEST_TIMEOUT:
        raise Reject("T5", "test_timeout", {"side": side, "run": index})
    if result["exit"] == 99:
        raise Reject("T5", "patch_apply_failed", {"side": side, "run": index})
    if result["exit"] != 0:
        raise Reject("T5", "test_container_failed", {"side": side, "run": index, "exit": result["exit"]})
    code_path = os.path.join(run_dir, "results", "exit_code")
    junit_path = os.path.join(run_dir, "results", "results.xml")
    outcome["exit_code"] = int(open(code_path, encoding="utf-8").read().strip() or -1) if os.path.exists(code_path) else None
    if recipe["language"] == "python" and outcome["exit_code"] not in (0, 1):
        raise Reject("T5", "test_runner_error", {"side": side, "run": index, "exit": outcome["exit_code"]})
    if not os.path.exists(junit_path):
        raise Reject("T5", "no_test_results", {"side": side, "run": index, "exit": outcome["exit_code"]})
    try:
        tests = v2.testids.parse_junit(junit_path)
    except Exception as exc:  # a crashed runner can leave a malformed file
        raise Reject("T5", "no_test_results", {"side": side, "run": index, "error": type(exc).__name__})
    if not tests:
        raise Reject("T5", "no_test_results", {"side": side, "run": index, "error": "empty"})
    counts = collections.Counter(tests.values())
    outcome.update({"passed": counts.get("pass", 0), "failed": counts.get("fail", 0),
                    "skipped": counts.get("skip", 0), "total": len(tests)})
    return outcome, tests


def detect_lint(cand, recipe, image, task_dir, show):
    command = tool = source = None
    if recipe["language"] == "node":
        try:
            scripts = json.loads(show("package.json") or "{}").get("scripts") or {}
        except (ValueError, AttributeError):
            scripts = {}
        if isinstance(scripts, dict) and scripts.get("lint"):
            command, tool, source = "npm run --silent lint", "node_modules/.bin/eslint", "package.json scripts.lint"
    else:
        config = show("pyproject.toml") or ""
        if "[tool.ruff" in config or show("ruff.toml") is not None:
            command, tool, source = "ruff check --no-cache", "ruff", "ruff configuration"
    if command is None:
        return None, {"status": "no_linter_configured"}
    lint_dir = os.path.join(task_dir, "lint")
    patch_dir = os.path.join(lint_dir, "patches")
    os.makedirs(patch_dir, exist_ok=True)
    shutil.copy(os.path.join(task_dir, "test.patch"), os.path.join(patch_dir, "1-test.patch"))
    shutil.copy(os.path.join(task_dir, "gold.patch"), os.path.join(patch_dir, "2-gold.patch"))
    script = os.path.join(lint_dir, "job.sh")
    v2.write_text(script, """#!/bin/bash
set -u
cd /work/repo
if [ ! -x "%s" ] && ! command -v "%s" >/dev/null 2>&1; then echo tool_absent; exit 77; fi
for p in $(ls /work/patches | sort); do git apply --whitespace=nowarn "/work/patches/$p" || exit 99; done
timeout --signal=KILL 300 %s
exit $?
""" % (tool, tool, command))
    result = v2.container_run("olivium-bench-v3lint-%s" % cand["task_id"], image, script,
                              files={patch_dir: "/work/patches"}, timeout=330)
    v2.write_text(os.path.join(lint_dir, "lint.log"), (result["stdout"] or "") + "\n" + (result["stderr"] or ""))
    if result["exit"] == 77:
        return None, {"status": "tool_not_installed", "tool": tool, "source": source}
    if result["exit"] != 0:
        return None, {"status": "fails_with_real_fix", "tool": tool, "source": source, "exit": result["exit"]}
    return command, {"status": "ok", "tool": tool, "source": source, "wall_seconds": round(result["wall"], 2)}


GOLD_GRADE_ATTEMPTS = 2


def _scoring_grader():
    """bench/value/grade/grader.py and lib/common.py, the code that grades scored runs."""
    value_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if value_dir not in sys.path:
        sys.path.append(value_dir)
    from grade import grader  # noqa: E402 - loaded on first use only
    from lib import common, dockerops  # noqa: E402
    return grader, common, dockerops


def gold_grade(task_id, task_dir, grade_task, log):
    """The real fix graded exactly as a scored run is graded. Change log of 2026-11-11
    (gold patch graded, integration 2 repair round).

    task_dir holds test.patch and gold.patch from validate(). grade_task carries the
    task fields the grader reads: test_files, test_command, lint_command, deps_image,
    f2p, p2p. The grader runs grade.sh in a fresh --network none container from the
    dependency image, with protection on and the protocol 3 test limit, with gold.patch
    in place of an agent's patch. Returns the evidence dict; "solved" says whether the
    real fix passes grading. An infrastructure failure is retried once, then raised as
    RuntimeError (the walk records it as infra, as for a network failure).
    """
    grader, common, dockerops = _scoring_grader()
    run_dir = os.path.join(task_dir, "gold-grade")
    ctx = types.SimpleNamespace(tag="v3gold-" + hashlib.sha256(task_id.encode("utf-8")).hexdigest()[:10], paid=False)
    errors = []
    for attempt in range(1, GOLD_GRADE_ATTEMPTS + 1):
        if os.path.isdir(run_dir):
            shutil.rmtree(run_dir)
        os.makedirs(run_dir)
        started = time.time()
        try:
            result = grader.grade(ctx, grade_task, os.path.join(task_dir, "gold.patch"), task_dir, run_dir,
                                  protect=True, test_timeout_s=common.GRADE_TEST_TIMEOUT_V3_S)
        except (dockerops.DockerError, common.BenchError, OSError, ValueError) as exc:
            result = {"status": "infra_error", "error": "%s: %s" % (type(exc).__name__, str(exc)[:300])}
        seconds = round(time.time() - started, 1)
        if result.get("status") == "ok":
            keys = ("solved", "patch_applied", "f2p_passed", "f2p_total", "p2p_total", "p2p_regressions",
                    "p2p_missing", "tests_seen", "restored_paths", "removed_paths", "test_exit", "lint_exit",
                    "lint_ok", "grade_timeout", "test_timeout_seconds", "test_wall_seconds", "results_error")
            evidence = {key: result.get(key) for key in keys if key in result}
            evidence.update({"attempts": attempt, "seconds": seconds, "protected": True,
                             "grader": "bench/value/grade/grader.py grade(), grade.sh"})
            log("%s: gold patch through grade.sh: solved=%s f2p %s/%s, p2p regressions %s, restored %d, test %s s" % (
                task_id, evidence["solved"], evidence.get("f2p_passed"), evidence.get("f2p_total"),
                evidence.get("p2p_regressions"), len(evidence.get("restored_paths") or []), evidence.get("test_wall_seconds")))
            return evidence
        errors.append(result.get("error") or "grade status %s" % result.get("status"))
        log("%s: gold grading attempt %d did not finish: %s" % (task_id, attempt, errors[-1]))
    raise RuntimeError("gold grading did not finish in %d attempts: %s" % (GOLD_GRADE_ATTEMPTS, "; ".join(errors)))


def gold_grade_limit():
    return _scoring_grader()[1].GRADE_TEST_TIMEOUT_V3_S


def gold_grade_task(cand, recipe, validated):
    return {
        "test_files": cand["test_files"],
        "test_command": recipe["test_command"],
        "lint_command": validated["lint_command"],
        "deps_image": image_name(cand["task_id"]),
        "f2p": validated["f2p"],
        "p2p": validated["p2p"],
    }


def check_gold_grade(task_id, task_dir, grade_task, log):
    """Raise Reject('T5', 'gold_not_gradeable') unless the real fix is graded solved."""
    evidence = gold_grade(task_id, task_dir, grade_task, log)
    if not evidence["solved"]:
        raise Reject("T5", "gold_not_gradeable", evidence)
    return evidence


def validate(repo, cand, recipe, work, jobs, log, show):
    """T5. Returns the validated record or raises Reject('T5', ...)."""
    task_dir = os.path.join(work, "tasks", cand["task_id"])
    if os.path.isdir(os.path.join(task_dir, "runs")):
        shutil.rmtree(os.path.join(task_dir, "runs"))
    os.makedirs(task_dir, exist_ok=True)
    v2.write_text(os.path.join(task_dir, "test.patch"), repo.patch(cand["base_sha"], cand["fix_sha"], cand["test_files"]))
    v2.write_text(os.path.join(task_dir, "gold.patch"), repo.patch(cand["base_sha"], cand["fix_sha"], cand["gold_files"]))
    image, build_attempts = build_image(cand, recipe, task_dir, log)
    isolation = probe(cand, recipe, image, task_dir)
    log("isolation ok for %s; 3x base and 3x fix, %d at a time" % (cand["task_id"], jobs))
    side_results = {"base": [None] * REPEATS, "fix": [None] * REPEATS}
    outcomes = []

    def run_batch(batch):
        with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
            futures = {pool.submit(run_tests_once, cand, recipe, image, task_dir, s, i): (s, i) for s, i in batch}
            first_error = None
            for future in concurrent.futures.as_completed(futures):
                side, index = futures[future]
                try:
                    outcome, tests = future.result()
                except concurrent.futures.CancelledError:
                    continue
                except Reject as exc:
                    first_error = first_error or exc
                    for other in futures:
                        other.cancel()
                    continue
                outcomes.append(outcome)
                side_results[side][index - 1] = tests
            if first_error is not None:
                raise first_error

    # One base and one fix run first. Fail-to-pass tests must fail (or be absent) in every
    # base run and pass in every fix run, and pass-to-pass tests must pass in all six, so
    # if this first pair already leaves no possible test of either kind, six runs give the
    # same rejection. The decision is identical; only the wasted runs are skipped.
    run_batch([("base", 1), ("fix", 1)])
    base1, fix1 = side_results["base"][0], side_results["fix"][0]
    possible_f2p = [t for t, o in fix1.items() if o == "pass" and base1.get(t, "absent") in ("fail", "absent")]
    possible_p2p = [t for t, o in fix1.items() if o == "pass" and base1.get(t) == "pass"]
    if not possible_f2p:
        raise Reject("T5", "no_fail_to_pass", {"after_runs": 2, "p2p_possible": len(possible_p2p)})
    if not possible_p2p:
        raise Reject("T5", "no_pass_to_pass", {"after_runs": 2, "f2p_possible": len(possible_f2p)})
    run_batch([("base", i) for i in range(2, REPEATS + 1)] + [("fix", i) for i in range(2, REPEATS + 1)])
    classified = v2.classify(side_results)
    outcomes.sort(key=lambda o: (o["side"], o["run"]))
    log("%s: f2p=%d p2p=%d flaky=%d" % (cand["task_id"], len(classified["f2p"]), len(classified["p2p"]), len(classified["flaky"])))
    if not classified["f2p"]:
        raise Reject("T5", "no_fail_to_pass", {"p2p": len(classified["p2p"]), "flaky": len(classified["flaky"])})
    if not classified["p2p"]:
        raise Reject("T5", "no_pass_to_pass", {"f2p": len(classified["f2p"]), "flaky": len(classified["flaky"])})
    f2p = set(classified["f2p"])
    base_failing = set()
    for results in side_results["base"]:
        base_failing.update(t for t, o in results.items() if o == "fail" and t not in f2p)
    census = {
        "base_failing_outside_f2p": len(base_failing),
        "flaky": len(classified["flaky"]),
        "full_suite_green_at_base": not base_failing and not classified["flaky"],
    }
    lint_command, lint_evidence = detect_lint(cand, recipe, image, task_dir, show)
    gold = check_gold_grade(cand["task_id"], task_dir, gold_grade_task(cand, recipe, {
        "lint_command": lint_command, "f2p": classified["f2p"], "p2p": classified["p2p"]}), log)
    image_id = docker("image", "inspect", "--format", "{{.Id}}", image).stdout.strip()
    return {
        "lint_command": lint_command,
        "f2p": classified["f2p"],
        "p2p": classified["p2p"],
        "pytest_added": isolation.get("pytest_added", False),
        "census": census,
        "evidence": {
            "image": image,
            "image_id": image_id,
            "build_attempts": build_attempts,
            "isolation": isolation,
            "runs": outcomes,
            "f2p_count": len(classified["f2p"]),
            "p2p_count": len(classified["p2p"]),
            "flaky_count": len(classified["flaky"]),
            "both_failing_count": len(classified["both_failing"]),
            "fix_regressions_count": len(classified["fix_regressions"]),
            "lint": lint_evidence,
            "gold_grade": gold,
            "test_wall_seconds": {side: [o["wall_seconds"] for o in outcomes if o["side"] == side] for side in ("base", "fix")},
        },
    }
