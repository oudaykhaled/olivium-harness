"""Derive the trial trace fields from a Claude Code stream-json transcript."""

import json
import os
import re
import shlex

REPO_PREFIX = "/work/repo/"
EDIT_TOOLS = {"Edit", "MultiEdit", "Write", "NotebookEdit"}
READ_TOOLS = {"Read", "NotebookRead"}
READ_COMMANDS = {"cat", "head", "tail", "less", "more", "nl", "sed", "awk", "bat"}
BASH_EDIT_RE = re.compile(r"(\bsed\s+-i|\bperl\s+-i|\btee\b|>>?|\bgit\s+apply\b|\bpatch\s)")
SPLIT_RE = re.compile(r"\|\||&&|;|\n|\|")
# Client tools that reach the web, and the server tools behind them (protocol 2 removes them).
WEB_TOOLS = {"WebSearch", "WebFetch", "web_search", "web_fetch"}


def normalize(path, cwd=REPO_PREFIX.rstrip("/")):
    """Repository-relative path, or None if the path is outside the repository."""
    if not isinstance(path, str) or not path:
        return None
    if not path.startswith("/"):
        path = "%s/%s" % (cwd, path)
    path = os.path.normpath(path)
    if not path.startswith(REPO_PREFIX):
        return None
    return path[len(REPO_PREFIX):]


def _tool_file(name, tool_input):
    if not isinstance(tool_input, dict):
        return None
    key = "notebook_path" if name in ("NotebookRead", "NotebookEdit") else "file_path"
    return normalize(tool_input.get(key))


def _bash_read_paths(command, known_files):
    """Files named by simple cat/head/sed style commands that exist at base_sha.

    A leading `cd DIR` in the same command is followed, so `cd src && cat x`
    resolves. grep, rg, find, pipes into interpreters and scripts are not read
    tracking: see PROTOCOL.md, Trace definitions.
    """
    found = []
    if not isinstance(command, str):
        return found
    cwd = REPO_PREFIX.rstrip("/")
    for segment in SPLIT_RE.split(command):
        try:
            argv = shlex.split(segment, comments=True)
        except ValueError:
            continue
        if argv and argv[0] == "cd" and len(argv) == 2:
            target = argv[1] if argv[1].startswith("/") else "%s/%s" % (cwd, argv[1])
            cwd = os.path.normpath(target)
            continue
        if not argv or os.path.basename(argv[0]) not in READ_COMMANDS:
            continue
        for arg in argv[1:]:
            if arg.startswith("-"):
                continue
            rel = normalize(arg, cwd)
            if rel is not None and rel in known_files:
                found.append(rel)
    return found


def _failed_tool_ids(transcript_path):
    """Ids of tool calls whose result was an error (denied, missing file, no match)."""
    failed = set()
    with open(transcript_path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if event.get("type") != "user":
                continue
            content = (event.get("message") or {}).get("content")
            if not isinstance(content, list):
                continue
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_result" and block.get("is_error"):
                    failed.add(block.get("tool_use_id"))
    return failed


_CHANGELOG_RE = re.compile(r"^(change|history|news|release)", re.I)


def _code_gold(gold_files):
    """Files of the real fix that are not changelogs. An edit to a changelog says
    nothing about having found the bug, so it does not end the 'before first gold
    edit' window. Falls back to every gold file if nothing else is left."""
    code = {
        path for path in gold_files
        if "changelog.d" not in path.lower().split("/")
        and not _CHANGELOG_RE.match(os.path.basename(path))
    }
    return code or set(gold_files)


def analyze(transcript_path, gold_files, known_files=None):
    """Return the trace: counts for the trial row and details for trace.json.

    A tool call that failed (permission denied, file missing, no match) still
    counts in tool_calls but never as a file read or a gold-file edit.

    `turns` counts main-session assistant messages. Turns before the first gold
    edit count every assistant message, subagents included, so work delegated
    to a subagent is not hidden from that metric.
    """
    gold = set(gold_files)
    code_gold = _code_gold(gold_files)
    failed_ids = _failed_tool_ids(transcript_path)
    known = set(known_files or ())
    seen_messages = set()
    seen_all_messages = set()
    seen_tools = set()
    turn = 0
    all_turns = 0
    tool_count = 0
    tool_calls = {}
    files_read = []
    first_gold = None
    init = {}
    result = {}
    malformed = 0
    hook_events = {}
    hook_blocks = 0
    web_tool_uses = 0
    with open(transcript_path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except ValueError:
                malformed += 1
                continue
            kind = event.get("type")
            if kind == "system" and event.get("subtype") == "init":
                init = event
            elif kind == "system" and str(event.get("subtype", "")).startswith("hook"):
                name = str(event.get("subtype"))
                hook_events[name] = hook_events.get(name, 0) + 1
            elif kind == "user":
                # A Stop hook that exits 2 reappears as the next user message to the model.
                message = event.get("message") or {}
                for block in message.get("content") or [] if isinstance(message.get("content"), list) else []:
                    if isinstance(block, dict) and block.get("type") == "text" and "Stop hook" in (block.get("text") or ""):
                        hook_blocks += 1
            elif kind == "result":
                result = event
            elif kind == "assistant":
                message = event.get("message") or {}
                message_id = message.get("id")
                main = event.get("parent_tool_use_id") in (None, "")
                if message_id not in seen_all_messages:
                    seen_all_messages.add(message_id)
                    all_turns += 1
                if main and message_id not in seen_messages:
                    seen_messages.add(message_id)
                    turn += 1
                for block in message.get("content") or []:
                    if isinstance(block, dict) and block.get("type") in ("tool_use", "server_tool_use") \
                            and block.get("name") in WEB_TOOLS and block.get("id") not in seen_tools:
                        web_tool_uses += 1
                    if not isinstance(block, dict) or block.get("type") != "tool_use":
                        continue
                    block_id = block.get("id")
                    if block_id in seen_tools:
                        continue
                    seen_tools.add(block_id)
                    name = block.get("name")
                    tool_input = block.get("input")
                    tool_count += 1
                    tool_calls[name] = tool_calls.get(name, 0) + 1
                    if block_id in failed_ids:
                        continue
                    if name in READ_TOOLS:
                        rel = _tool_file(name, tool_input)
                        if rel:
                            files_read.append(rel)
                    if name == "Bash":
                        files_read.extend(_bash_read_paths((tool_input or {}).get("command"), known))
                    if first_gold is None:
                        edited = None
                        if name in EDIT_TOOLS:
                            rel = _tool_file(name, tool_input)
                            if rel in code_gold:
                                edited = rel
                        elif name == "Bash":
                            command = (tool_input or {}).get("command") or ""
                            if BASH_EDIT_RE.search(command):
                                for path in sorted(code_gold):
                                    if path in command:
                                        edited = path
                                        break
                        if edited is not None:
                            first_gold = {
                                "path": edited, "tool": name,
                                "turns_before": max(all_turns - 1, 0),
                                "tool_calls_before": tool_count - 1,
                            }
    distinct = sorted(set(files_read))
    wasted = [path for path in distinct if path not in gold]
    init_tools = sorted(str(name) for name in (init.get("tools") or []))
    return {
        "turns": turn,
        "tool_calls": tool_calls,
        "tool_calls_total": tool_count,
        "files_read": len(distinct),
        "files_read_list": distinct,
        "wasted_reads": len(wasted),
        "wasted_reads_list": wasted,
        "turns_before_first_gold_edit": first_gold["turns_before"] if first_gold else None,
        "tool_calls_before_first_gold_edit": first_gold["tool_calls_before"] if first_gold else None,
        "first_gold_edit": first_gold,
        "claude_code_version": init.get("claude_code_version"),
        "init_model": init.get("model"),
        "permission_mode": init.get("permissionMode"),
        "permission_denials": len(result.get("permission_denials") or []),
        "permission_denied_tools": sorted({str(item.get("tool_name")) for item in (result.get("permission_denials") or []) if isinstance(item, dict)}),
        "hook_events": hook_events,
        "hook_blocks": hook_blocks,
        "init_tools": init_tools,
        "init_web_tools": [name for name in init_tools if name in WEB_TOOLS],
        "web_tool_uses": web_tool_uses,
        "result": {
            key: result.get(key)
            for key in ("subtype", "is_error", "num_turns", "total_cost_usd", "duration_ms", "stop_reason")
        },
        "malformed_lines": malformed,
    }


def web_guard(trace, rows):
    """Protocol v2: evidence that a web tool reached the session. Empty means none did."""
    problems = []
    if trace.get("init_web_tools"):
        problems.append("Claude Code offered %s" % ",".join(trace["init_web_tools"]))
    refused = sum(1 for item in rows if item.get("status") == "refused_web_tool")
    if refused:
        problems.append("the meter refused %d request(s) offering a web server tool" % refused)
    forwarded = sorted({name for item in rows if item.get("status") != "refused_web_tool" for name in (item.get("web_tools") or [])})
    if forwarded:
        problems.append("the meter served a request offering %s" % ",".join(forwarded))
    return problems


def patch_line_count(patch_text):
    count = 0
    for line in patch_text.splitlines():
        if line.startswith("+++") or line.startswith("---"):
            continue
        if line.startswith("+") or line.startswith("-"):
            count += 1
    return count


CAP_STATUSES = {"cap_run", "cap_total"}
UPSTREAM_PREFIXES = ("upstream_", "stream_error_")
# The benchmark's own plumbing broke, whatever the session reported.
HARD_INFRA_STATUSES = {"log_error", "halted", "unknown_model", "bad_request", "not_found", "meter_error", "usage_missing",
                       # Protocol v2: a web tool got past --disallowedTools and the meter refused it.
                       "refused_web_tool"}
# An API refusal caused by what the agent sent (for example a prompt that grew
# too long). Protocol: runs that fail because of the model are never repeated.
MODEL_CAUSED_UPSTREAM = {"upstream_400", "upstream_413"}


def classify(exit_code, host_timeout, trace, rows):
    """Map an agent session's outcome to a protocol status.

    A transient upstream error that Claude Code retried past is not an
    infrastructure failure: the session finished and its result counts. A
    session that ended abnormally without reaching a limit (exit code not 0 or
    is_error set, for example because the meter or API went away) is.
    """
    statuses = {row.get("status") for row in rows}
    if statuses & CAP_STATUSES:
        return "budget_exhausted"
    if host_timeout or exit_code == 124:
        return "timeout"
    result = trace.get("result") or {}
    if result.get("subtype") == "error_max_turns":
        return "turn_limit"
    if statuses & HARD_INFRA_STATUSES:
        return "infra_error"
    if exit_code is None or result.get("subtype") is None:
        return "infra_error"
    if exit_code == 0 and not result.get("is_error"):
        return "completed"
    upstream = {status for status in statuses if isinstance(status, str) and status.startswith(UPSTREAM_PREFIXES)}
    if upstream and upstream <= MODEL_CAUSED_UPSTREAM:
        return "completed"
    return "infra_error"
