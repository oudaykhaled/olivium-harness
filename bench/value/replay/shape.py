#!/usr/bin/env python3
"""Request shape: what each setup adds to the first model request, from mock-meter captures.

Input: one capture directory per setup, as the meter writes them with --capture-dir
(DIR/req-NNNN.json, one per request; `run.py --mock-scenario shape|envcheck` and
`shape_run.py` copy them to OUT/meter/capture/<run_id>/). The first request that
offers both Read and Edit is the main agent's first request; background requests are
skipped.

Sizes are characters of the JSON the model reads. Tokens are an ESTIMATE: characters /
2.775, the ratio calibrated on the recorded run expressjs-express-7366.none.r1, whose
first request was metered at 17,179 tokens with the same prompt, image and Claude Code
2.1.311. Differences between setups are what this measures; the absolute token number is
only as good as that calibration.

  python3 bench/value/replay/shape.py --setup none=CAP_A --setup lean=CAP_B \\
      [--expect-lean lean] [--expect-standard std --root-price 148] \\
      [--expect-env env --env-line 'Type checking is not available here: ...'] \\
      [--expect-silent env-silent:none] [--same none:none-again] --out FILE.json

Checks (each optional; exit 1 when any fails):
  --expect-lean S          S's estimate is at least 10,000 tokens below none's
  --expect-standard S      S's estimate is at most none + --root-price + 100
  --expect-env S           S's first request carries every --env-line in the SessionStart hook text
  --expect-silent S:T      S and T send the same first request apart from metadata.user_id
                           (an environment check that has nothing to say adds nothing)
  --same S:T               the same, for two runs of one setup (the capture is repeatable)
"""

import argparse
import json
import os
import re
import sys

CHARS_PER_TOKEN = 2.775
HOOK_RE = re.compile(r"(SessionStart:startup|UserPromptSubmit) hook success: (.*?)(?=\n\n|\Z)", re.S)


def captured(directory):
    out = []
    for name in sorted(os.listdir(directory)):
        if re.match(r"^req-\d+\.json$", name):
            with open(os.path.join(directory, name), "r", encoding="utf-8") as handle:
                out.append(json.load(handle))
    return out


def main_request(directory):
    for record in captured(directory):
        body = record.get("body") or {}
        names = {tool.get("name") for tool in body.get("tools") or [] if isinstance(tool, dict)}
        if {"Read", "Edit"} <= names:
            return body
    return None


def _text(content):
    if isinstance(content, str):
        return content
    return "".join(block.get("text", "") if block.get("type") == "text" else json.dumps(block, ensure_ascii=False)
                   for block in content or [] if isinstance(block, dict))


def shape(body):
    system = body.get("system")
    system_chars = len(system) if isinstance(system, str) else sum(len(b.get("text", "")) for b in system or [] if isinstance(b, dict))
    tools = {tool.get("name"): len(json.dumps(tool, ensure_ascii=False)) for tool in body.get("tools") or [] if isinstance(tool, dict)}
    messages = [{"role": m.get("role"), "chars": len(_text(m.get("content")))} for m in body.get("messages") or []]
    hooks = []
    for message in body.get("messages") or []:
        for match in HOOK_RE.finditer(_text(message.get("content"))):
            hooks.append({"event": match.group(1).split(":")[0], "text": match.group(2)})
    total = system_chars + sum(tools.values()) + sum(m["chars"] for m in messages)
    return {"system_chars": system_chars, "tools": tools, "tools_chars": sum(tools.values()), "tool_count": len(tools),
            "messages": messages, "messages_chars": sum(m["chars"] for m in messages), "hook_output": hooks,
            "total_chars": total, "est_tokens": round(total / CHARS_PER_TOKEN)}


def without_user_id(body):
    body = json.loads(json.dumps(body))
    metadata = body.get("metadata")
    if isinstance(metadata, dict):
        metadata.pop("user_id", None)
    return body


def first_difference(a, b, where="body"):
    if type(a) is not type(b):
        return where
    if isinstance(a, dict):
        for key in sorted(set(a) | set(b)):
            if key not in a or key not in b:
                return "%s.%s" % (where, key)
            found = first_difference(a[key], b[key], "%s.%s" % (where, key))
            if found:
                return found
        return None
    if isinstance(a, list):
        if len(a) != len(b):
            return "%s (length %d vs %d)" % (where, len(a), len(b))
        for index, (x, y) in enumerate(zip(a, b)):
            found = first_difference(x, y, "%s[%d]" % (where, index))
            if found:
                return found
        return None
    return None if a == b else where


def pair(text):
    if ":" not in text:
        raise argparse.ArgumentTypeError("expected A:B")
    return tuple(text.split(":", 1))


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--setup", action="append", required=True, help="NAME=CAPTURE_DIR; 'none' is the baseline")
    parser.add_argument("--baseline", default="none")
    parser.add_argument("--expect-lean", action="append", default=[])
    parser.add_argument("--expect-standard", action="append", default=[])
    parser.add_argument("--root-price", type=int, help="est. tokens per request of the setup's CLAUDE.md (provenance file)")
    parser.add_argument("--expect-env", action="append", default=[])
    parser.add_argument("--env-line", action="append", default=[])
    parser.add_argument("--expect-silent", action="append", default=[], type=pair)
    parser.add_argument("--same", action="append", default=[], type=pair)
    parser.add_argument("--out")
    args = parser.parse_args(argv)
    bodies, shapes = {}, {}
    for item in args.setup:
        name, _, directory = item.partition("=")
        body = main_request(directory)
        if body is None:
            print("%s: no main request in %s" % (name, directory), file=sys.stderr)
            return 2
        bodies[name] = body
        shapes[name] = shape(body)
    base = shapes.get(args.baseline)
    for name, item in shapes.items():
        if base:
            item["delta_tokens_vs_baseline"] = item["est_tokens"] - base["est_tokens"]
            item["tools_removed_vs_baseline"] = sorted(set(base["tools"]) - set(item["tools"]))
            item["tools_added_vs_baseline"] = sorted(set(item["tools"]) - set(base["tools"]))
    checks = []

    def check(name, ok, detail):
        checks.append({"check": name, "pass": bool(ok), "detail": detail})

    for name in args.expect_lean:
        delta = shapes[name]["est_tokens"] - base["est_tokens"]
        check("lean %s at least 10,000 tokens below %s" % (name, args.baseline), delta <= -10000, "delta %+d" % delta)
    for name in args.expect_standard:
        if args.root_price is None:
            parser.error("--expect-standard needs --root-price")
        delta = shapes[name]["est_tokens"] - base["est_tokens"]
        check("standard %s at most %s + %d + 100" % (name, args.baseline, args.root_price), delta <= args.root_price + 100,
              "delta %+d" % delta)
    for name in args.expect_env:
        texts = [hook["text"] for hook in shapes[name]["hook_output"] if hook["event"] == "SessionStart"]
        lines = [line for text in texts for line in text.splitlines()]
        missing = [line for line in args.env_line if line not in lines]
        check("env check %s in the first request" % name, texts and not missing,
              {"session_start_text": texts, "missing": missing})
    for label, pairs in (("silent", args.expect_silent), ("same", args.same)):
        for a, b in pairs:
            diff = first_difference(without_user_id(bodies[a]), without_user_id(bodies[b]))
            check("%s: %s and %s identical apart from metadata.user_id" % (label, a, b), diff is None, diff or "identical")
    report = {"schema": "olivium-request-shape/1", "chars_per_token": CHARS_PER_TOKEN,
              "note": "token numbers are estimates from characters; differences between setups are the measurement",
              "baseline": args.baseline, "setups": shapes, "checks": checks,
              "passed": all(item["pass"] for item in checks)}
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            json.dump(report, handle, indent=2, sort_keys=True)
            handle.write("\n")
    print("%-16s %8s %8s %6s %9s %9s %8s %8s" % ("setup", "system", "tools", "ntools", "messages", "total", "est_tok", "delta"))
    for name, item in shapes.items():
        print("%-16s %8d %8d %6d %9d %9d %8d %+8d" % (name, item["system_chars"], item["tools_chars"], item["tool_count"],
              item["messages_chars"], item["total_chars"], item["est_tokens"], item.get("delta_tokens_vs_baseline", 0)))
        for hook in item["hook_output"]:
            print("    %s hook text: %s" % (hook["event"], hook["text"].replace("\n", " | ")[:300]))
    for item in checks:
        print("%s  %s  (%s)" % ("PASS" if item["pass"] else "FAIL", item["check"], json.dumps(item["detail"])[:300]))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
