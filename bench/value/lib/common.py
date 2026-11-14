"""Shared constants and helpers for the value benchmark runner.

Host-side code uses the Python standard library only. Modules are imported as
lib.common and so on, with bench/value (the directory of run.py) on sys.path.
bench/value/corpus is never put on sys.path: select.py there shadows a standard
library module.
"""

import hashlib
import importlib.util
import json
import os
import re
import threading

VALUE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_ROOT = os.path.dirname(os.path.dirname(VALUE_DIR))
MANIFEST_PATH = os.path.join(VALUE_DIR, "corpus", "manifest.json")
MANIFEST_V2_PATH = os.path.join(VALUE_DIR, "corpus", "manifest-v2.json")
# Protocol 3 (benchmark v3). Lane B writes it; the runner only loads it, as data.
MANIFEST_V3_PATH = os.path.join(VALUE_DIR, "corpus", "manifest-v3.json")
TESTIDS_PATH = os.path.join(VALUE_DIR, "corpus", "testids.py")
PRICES_PATH = os.path.join(VALUE_DIR, "meter", "prices.json")
DOCKER_DIR = os.path.join(VALUE_DIR, "docker")
ARMS_DIR = os.path.join(VALUE_DIR, "arms")
GRADE_DIR = os.path.join(VALUE_DIR, "grade")

# Protocol constants. --paid never changes these.
MODEL = "claude-sonnet-5-5"
CLAUDE_CODE_VERSION = "2.1.311"
MAX_TURNS = 60
TIMEOUT_S = 1200
CONCURRENCY = 2
DEFAULT_SEED = 20261108
DEFAULT_REPEATS = 3
ARMS = ("none", "generic", "olivium")
# Protocol 2 only, never in the default selection: run only when named with --arms.
# none-lean is the none arm plus only the lean trim of the task's olivium export.
NONE_LEAN = "none-lean"
OPTIONAL_ARMS = (NONE_LEAN,)
# v4 development arms (contract-v4.md, lane D): protocol 2 only, never protocol 1 or 3,
# and only when named with --arms. olivium-ai is the lean-ai export plus its learned
# bundle; olivium-det is the same export from a bundle made without cloud learning.
OLIVIUM_AI = "olivium-ai"
OLIVIUM_DET = "olivium-det"
V4_OPTIONAL_ARMS = (OLIVIUM_AI, OLIVIUM_DET)
# v5 development arm (v5 contract.md, lane C): protocol 2 only, never protocol 1 or 3,
# and only when named with --arms. olivium-x is none-lean plus the lean-x export's
# PreToolUse hooks (guard, Bash output shaper) and output style (arms/olivium_x.py).
OLIVIUM_X = "olivium-x"
V5_OPTIONAL_ARMS = (OLIVIUM_X,)
# v2r arm (PROTOCOL-v2r.md): protocol 2 only, never protocol 1 or 3, and only when named
# with --arms. olivium-nn is the olivium export of the same snapshot with --native none
# (no generated skills or subagents), run as exported in olivium's permission mode.
OLIVIUM_NN = "olivium-nn"
V2R_OPTIONAL_ARMS = (OLIVIUM_NN,)
# Arms whose exported .claude/settings.json is passed with --settings, byte for byte.
EXPORTED_SETTINGS_ARMS = ("olivium", OLIVIUM_NN)
# Arms that install no file into the repository: the agent gets settings only.
FILELESS_ARMS = ("none", NONE_LEAN)
PROMPT_SUFFIX = "Fix this issue in the repository in the current directory."
# Removed from every arm before arm files are installed (PROTOCOL.md, Arms).
INSTRUCTION_PATHS = ("CLAUDE.md", "AGENTS.md", ".claude", ".cursor", ".github/copilot-instructions.md")
GENERIC_PROMPT = "/init\n"

# Agent container limits, shared by every agent session.
AGENT_LIMITS = {"memory": "1500m", "cpus": "2", "pids": "512"}
# Grading limits used for the corpus validation (corpus report).
GRADE_LIMITS = {"memory": "1800m", "cpus": "2", "pids": "2048"}
GRADE_COMMAND_TIMEOUT_S = 300
# Protocol 3 grades with twice the selection limit (T5: every validation run within
# 300 s), so host load cannot turn a solved run into a test-command timeout.
# PROTOCOL-v3.md, change log, grading time limit.
GRADE_TEST_TIMEOUT_V3_S = 600
MAX_ATTEMPTS = 3

RUN_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


class BenchError(Exception):
    """A clear, non-traceback failure reported to the operator."""


class SetupFailed(BenchError):
    """A setup step failed after it may already have spent money.

    fields carries cost_usd, cost_upper_bound_usd and tokens for the failed
    setup record, so a failed step still reduces the budget and shows in the
    report instead of disappearing.
    """

    def __init__(self, message, fields):
        BenchError.__init__(self, message)
        self.fields = fields


def out_tag(out_dir):
    """A short stable suffix that scopes docker names to one output directory."""
    return hashlib.sha256(os.path.realpath(out_dir).encode("utf-8")).hexdigest()[:8]


def manifest_checksum(manifest):
    return hashlib.sha256(
        json.dumps(
            {"selection": manifest["selection"], "tasks": manifest["tasks"]},
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
        ).encode("utf-8")
    ).hexdigest()


def load_manifest(path=MANIFEST_PATH):
    with open(path, "r", encoding="utf-8") as handle:
        manifest = json.load(handle)
    if manifest_checksum(manifest) != manifest.get("checksum"):
        raise BenchError("manifest checksum mismatch: %s" % path)
    return manifest


def select_tasks(manifest, wanted):
    """Tasks in manifest order; wanted is a comma-separated string or None."""
    tasks = manifest["tasks"]
    if not wanted:
        return list(tasks)
    names = [item.strip() for item in wanted.split(",") if item.strip()]
    known = {task["task_id"]: task for task in tasks}
    unknown = [name for name in names if name not in known]
    if unknown:
        raise BenchError("unknown task id(s): %s" % ", ".join(unknown))
    return [task for task in tasks if task["task_id"] in names]


def run_id_for(task_id, arm, repeat, attempt=1):
    base = "%s.%s.r%d" % (task_id, arm, repeat)
    return base if attempt == 1 else "%s.a%d" % (base, attempt)


def read_jsonl(path):
    if not os.path.exists(path):
        return []
    rows = []
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except ValueError:
                # A torn final line from an interrupted write is not a record.
                continue
    return rows


_append_lock = threading.Lock()


def append_jsonl(path, record):
    line = json.dumps(record, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    with _append_lock:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(line + "\n")
            handle.flush()
            os.fsync(handle.fileno())


def write_json_atomic(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, sort_keys=True, ensure_ascii=False)
        handle.write("\n")
    os.replace(tmp, path)


def read_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tree_files(root):
    """Sorted relative paths of the regular files under root (symlinks skipped)."""
    found = []
    for directory, subdirs, names in os.walk(root, followlinks=False):
        subdirs.sort()
        for name in sorted(names):
            path = os.path.join(directory, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            found.append(os.path.relpath(path, root))
    return sorted(found)


def tree_digest(root):
    digest = hashlib.sha256()
    for rel in tree_files(root):
        digest.update(rel.encode("utf-8") + b"\0")
        digest.update(sha256_file(os.path.join(root, rel)).encode("ascii") + b"\0")
    return digest.hexdigest()


def tree_bytes(root):
    return sum(os.path.getsize(os.path.join(root, rel)) for rel in tree_files(root))


def load_parse_junit():
    """Load corpus/testids.py by file path; its directory never enters sys.path."""
    spec = importlib.util.spec_from_file_location("olivium_bench_testids", TESTIDS_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.parse_junit


def sonnet_cost_usd(input_tokens, output_tokens):
    """Cost from the verified price table, for the app's non-cached proposal calls."""
    prices = read_json(PRICES_PATH)
    rate = prices["models"][MODEL]
    return (input_tokens * rate["input"] + output_tokens * rate["output"]) / 1_000_000.0
