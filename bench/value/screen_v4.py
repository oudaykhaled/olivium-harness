#!/usr/bin/env python3
"""v4 development rehearsal: the P2 difficulty screen (PROTOCOL-v4dev.md). Standard library only.

    python3 -I bench/value/screen_v4.py --out P2_OUT --manifest MANIFEST --dest DIR [--min-requests 7]

Reads the `none-lean` runs of a P2 OUT (one paid run per task, made before the rehearsal and never
reused by it) and keeps a task if that run used at least --min-requests requests or did not solve it
(design.md section 7). Writes, into DIR (which must not exist yet):

- `manifest-v4dev-screened.json`: the input manifest with only the kept tasks, the screen recorded in
  `selection.screen`, and a new checksum (same formula as `lib/common.py`);
- `manifest-v4dev-screened.sha256`: the file sha256 and the checksum;
- `screen.json`: one row per task with its requests, solved and kept.

It refuses (exit 1, nothing written) when a task has no scored `none-lean` run, when a run was stopped
by a budget, or when the OUT holds mock meter rows (unless --allow-mock, for $0 dry runs, which marks
the screen `mock` so a paid rehearsal can see it). Reads data only; executes nothing.
"""

import argparse
import hashlib
import json
import os
import sys
from datetime import datetime, timezone

SCREEN_ID = "screen-v4/1"


def read_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def read_jsonl(path):
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            if line.strip():
                rows.append(json.loads(line))
    return rows


def manifest_checksum(manifest):
    """The same formula as bench/value/lib/common.py manifest_checksum."""
    payload = {"selection": manifest["selection"], "tasks": manifest["tasks"]}
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def is_mock(out):
    for row in read_jsonl(os.path.join(out, "meter", "requests.jsonl")):
        if row.get("mode") == "mock" or "mock_kind" in row:
            return True
    return False


def scored_none_lean(out):
    """task_id -> the scored none-lean row (repeat 1, the last attempt that is not infra_error)."""
    chosen = {}
    for row in read_jsonl(os.path.join(out, "trials.jsonl")):
        if row.get("arm") == "none-lean" and row.get("repeat") == 1 and row.get("status") != "infra_error":
            chosen[row.get("task_id")] = row
    return chosen


def screen(out, manifest, min_requests):
    """(rows, problems): one row per manifest task, and why the screen cannot be used."""
    chosen = scored_none_lean(out)
    rows, problems = [], []
    for task in manifest["tasks"]:
        task_id = task["task_id"]
        row = chosen.get(task_id)
        if row is None:
            problems.append("%s: no scored none-lean run" % task_id)
            continue
        if row.get("status") == "budget_exhausted":
            problems.append("%s: the none-lean run was stopped by a budget" % task_id)
            continue
        requests = int(row.get("requests") or 0)
        solved = bool(row.get("solved"))
        rows.append({"task_id": task_id, "run_id": row.get("run_id"), "status": row.get("status"),
                     "requests": requests, "solved": solved,
                     "kept": requests >= min_requests or not solved})
    return rows, problems


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", required=True, help="the P2 OUT (none-lean, 1 repeat)")
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--dest", required=True, help="a directory that does not exist yet")
    parser.add_argument("--min-requests", type=int, default=7)
    parser.add_argument("--allow-mock", action="store_true", help="dry runs only: screen a mock OUT, marked mock")
    args = parser.parse_args(argv)
    if os.path.exists(args.dest):
        print("refusing: %s already exists (a screen is written once)" % args.dest, file=sys.stderr)
        return 1
    manifest = read_json(args.manifest)
    if manifest_checksum(manifest) != manifest.get("checksum"):
        print("refusing: manifest checksum mismatch: %s" % args.manifest, file=sys.stderr)
        return 1
    mock = is_mock(args.out)
    if mock and not args.allow_mock:
        print("refusing: %s holds mock meter rows; a screen needs paid runs" % args.out, file=sys.stderr)
        return 1
    rows, problems = screen(args.out, manifest, args.min_requests)
    if problems:
        print("refusing: the screen is incomplete:\n  " + "\n  ".join(problems), file=sys.stderr)
        return 1
    kept_ids = [row["task_id"] for row in rows if row["kept"]]
    screened = dict(manifest)
    screened["frozen_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    screened["selection"] = dict(manifest["selection"])
    screened["selection"]["screen"] = {
        "screen": SCREEN_ID,
        "rule": "keep a task if its one none-lean run used at least %d requests or did not solve it" % args.min_requests,
        "source_manifest_checksum": manifest["checksum"],
        "p2_out": os.path.basename(os.path.normpath(args.out)),
        "mock": mock,
        "rows": rows,
    }
    screened["tasks"] = [task for task in manifest["tasks"] if task["task_id"] in kept_ids]
    screened["checksum"] = manifest_checksum(screened)
    os.makedirs(args.dest)
    path = os.path.join(args.dest, "manifest-v4dev-screened.json")
    data = (json.dumps(screened, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    with open(path, "wb") as handle:
        handle.write(data)
    with open(os.path.join(args.dest, "manifest-v4dev-screened.sha256"), "w", encoding="ascii") as handle:
        handle.write("%s  manifest-v4dev-screened.json\nchecksum %s\n" % (hashlib.sha256(data).hexdigest(), screened["checksum"]))
    with open(os.path.join(args.dest, "screen.json"), "w", encoding="utf-8") as handle:
        json.dump({"screen": SCREEN_ID, "mock": mock, "min_requests": args.min_requests, "rows": rows,
                   "kept": kept_ids, "checksum": screened["checksum"]}, handle, indent=2, sort_keys=True)
        handle.write("\n")
    for row in rows:
        print("%-28s requests=%-3d solved=%-5s %s" % (row["task_id"], row["requests"], row["solved"],
                                                       "kept" if row["kept"] else "screened out"))
    print("%s%d of %d tasks kept; checksum %s" % ("MOCK: " if mock else "", len(kept_ids), len(rows), screened["checksum"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
