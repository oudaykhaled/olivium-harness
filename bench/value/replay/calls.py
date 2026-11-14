"""Recorded tool calls from benchmark transcripts, and shell-text helpers.

Shared by the replay gate (gate.py) and the counterfactual cost model
(counterfactual.py). Everything here reads text. Nothing from a transcript is
executed, expanded or evaluated: commands are strings that are split and
pattern-matched.

A source is LABEL=DIR, where DIR holds one directory per trial named
<task_id>.<arm>.r<repeat>[.a<attempt>] with a transcript.jsonl (the layout
bench/value/run.py writes under OUT/trials). The setup of a trial is
"<LABEL>:<arm>", for example "v2:none" or "fix:olivium".
"""

import json
import os
import posixpath
import re

PROJECT = "/work/repo"
TRANSCRIPTS = "/home/agent/.claude/projects/-work-repo"
RUN_DIR_RE = re.compile(r"^(?P<task>[A-Za-z0-9][A-Za-z0-9_.-]*?)\.(?P<arm>none-lean|none|generic|olivium)\.r(?P<repeat>[0-9]+)(?:\.a(?P<attempt>[0-9]+))?$")


# --------------------------------------------------------------------------- sources
def parse_source(text):
    if "=" not in text:
        raise ValueError("a source is LABEL=DIR, got %r" % text)
    label, path = text.split("=", 1)
    if not re.match(r"^[A-Za-z0-9_-]{1,32}$", label):
        raise ValueError("source label must be 1-32 letters, digits, - or _: %r" % label)
    path = os.path.realpath(os.path.expanduser(path))
    if not os.path.isdir(path):
        raise ValueError("source directory does not exist: %s" % path)
    return label, path


def trial_dirs(source_dir):
    found = []
    for name in sorted(os.listdir(source_dir)):
        match = RUN_DIR_RE.match(name)
        path = os.path.join(source_dir, name)
        if match and os.path.isfile(os.path.join(path, "transcript.jsonl")):
            found.append((name, match.group("task"), match.group("arm"), int(match.group("repeat")), path))
    return found


# --------------------------------------------------------------------------- transcripts
def _content_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(block.get("text", "") for block in content if isinstance(block, dict) and isinstance(block.get("text"), str))
    return ""


def read_transcript(path):
    """Tool calls in order, with their results and whether they were refused.

    Returns (calls, info). Each call: id, turn (1-based main-session assistant
    message), name, input, refused (bool), refusal (text or None), is_error,
    result (first 2,000 characters), result_chars (full length), main (bool).
    """
    order = []
    calls = []
    seen = set()
    results = {}
    denied = {}
    info = {"init": {}, "result": {}, "malformed": 0}
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except ValueError:
                info["malformed"] += 1
                continue
            kind = event.get("type")
            if kind == "system" and event.get("subtype") == "init":
                info["init"] = event
            elif kind == "system" and event.get("subtype") == "permission_denied":
                denied[event.get("tool_use_id")] = str(event.get("decision_reason") or event.get("message") or "")
            elif kind == "result":
                info["result"] = event
                for item in event.get("permission_denials") or []:
                    if isinstance(item, dict):
                        denied.setdefault(item.get("tool_use_id"), "")
            elif kind == "assistant":
                message = event.get("message") or {}
                main = event.get("parent_tool_use_id") in (None, "")
                message_id = message.get("id")
                if main and message_id not in order:
                    order.append(message_id)
                for block in message.get("content") or []:
                    if not isinstance(block, dict) or block.get("type") != "tool_use" or block.get("id") in seen:
                        continue
                    seen.add(block.get("id"))
                    calls.append({
                        "id": block.get("id"),
                        "turn": (order.index(message_id) + 1) if message_id in order else None,
                        "name": str(block.get("name") or ""),
                        "input": block.get("input") if isinstance(block.get("input"), dict) else {},
                        "main": main,
                    })
            elif kind == "user":
                content = (event.get("message") or {}).get("content")
                if not isinstance(content, list):
                    continue
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "tool_result":
                        text = _content_text(block.get("content"))
                        results[block.get("tool_use_id")] = {
                            "is_error": bool(block.get("is_error")),
                            "text": text[:2000],
                            "chars": len(text),
                        }
    for call in calls:
        result = results.get(call["id"], {"is_error": False, "text": "", "chars": 0})
        call["is_error"] = result["is_error"]
        call["result"] = result["text"]
        call["result_chars"] = result["chars"]
        call["refused"] = call["id"] in denied
        call["refusal"] = (denied.get(call["id"]) or result["text"][:300]) if call["refused"] else None
    info["turns"] = len(order)
    return calls, info


def load_runs(sources, tasks=None):
    """Every trial of every source, with its calls and an estimated cwd per call."""
    runs = []
    for label, directory in sources:
        for name, task, arm, repeat, path in trial_dirs(directory):
            if tasks and task not in tasks:
                continue
            calls, info = read_transcript(os.path.join(path, "transcript.jsonl"))
            track_cwd(calls)
            runs.append({
                "run_id": name, "source": label, "setup": "%s:%s" % (label, arm), "task": task,
                "arm": arm, "repeat": repeat, "dir": path, "calls": calls, "info": info,
            })
    return runs


# --------------------------------------------------------------------------- shell text
def words(text):
    """Shell-like words of one command piece as (word, quoted) pairs.

    quoted is True when any part of the word was inside quotes. Backslash escapes
    are kept literal outside quotes (the character after the backslash is taken).
    Nothing is expanded.
    """
    out = []
    current = []
    quoted = False
    opened = False
    quote = None
    index = 0
    while index < len(text):
        char = text[index]
        if quote:
            if char == quote:
                quote = None
            elif char == "\\" and quote == '"' and index + 1 < len(text):
                index += 1
                current.append(text[index])
            else:
                current.append(char)
            index += 1
            continue
        if char in "'\"":
            quote = char
            quoted = True
            opened = True
        elif char == "\\" and index + 1 < len(text):
            index += 1
            current.append(text[index])
            opened = True
        elif char in " \t\n":
            if opened:
                out.append(("".join(current), quoted))
            current, quoted, opened = [], False, False
        else:
            current.append(char)
            opened = True
        index += 1
    if opened:
        out.append(("".join(current), quoted))
    return out


HEREDOC_RE = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_.-]*)\1")


def strip_heredocs(command):
    """The command without here-document bodies (they are data, not commands)."""
    lines = command.split("\n")
    kept = []
    pending = []
    for line in lines:
        if pending:
            tag, strip = pending[0]
            candidate = line.lstrip("\t") if strip else line
            if candidate == tag:
                pending.pop(0)
            continue
        kept.append(line)
        shape = _unquoted_shape(line)
        for match in re.finditer(r"(?<!<)<<(?!<)", shape):
            # The shape blanks quoted text, so the tag itself is read from the line.
            tag = HEREDOC_RE.match(line, match.start())
            if tag:
                pending.append((tag.group(2), line[match.start():match.start() + 3] == "<<-"))
    return "\n".join(kept)


def _unquoted_shape(line):
    """The line with quoted text blanked, so a << inside quotes is not a here-document."""
    out = []
    quote = None
    for char in line:
        if quote:
            out.append(" " if char != quote else char)
            if char == quote:
                quote = None
        elif char in "'\"":
            quote = char
            out.append(char)
        else:
            out.append(char)
    return "".join(out)


def split_segments(command, keep_heredocs=False):
    """Top-level pieces of a command line: split at unquoted ;, &, |, &&, ||, newlines,
    ( ) and { }, after removing here-document bodies (unless keep_heredocs). Text
    inside $( ) and backticks is returned as pieces of its own as well.
    Returns [(piece, separator_before)]."""
    text = command if keep_heredocs else strip_heredocs(command)
    pieces = []
    current = []
    quote = None
    separator = ""
    index = 0
    subs = []
    while index < len(text):
        char = text[index]
        if quote:
            current.append(char)
            if char == quote:
                quote = None
            elif char == "\\" and quote == '"' and index + 1 < len(text):
                current.append(text[index + 1])
                index += 1
            index += 1
            continue
        if char in "'\"":
            quote = char
            current.append(char)
            index += 1
            continue
        if char == "\\" and index + 1 < len(text):
            current.append(text[index:index + 2])
            index += 2
            continue
        if text.startswith("$(", index) and not text.startswith("$((", index):
            depth, end = 1, index + 2
            while end < len(text) and depth:
                if text[end] == "(":
                    depth += 1
                elif text[end] == ")":
                    depth -= 1
                end += 1
            subs.append(text[index + 2:end - 1])
            current.append("$(...)")
            index = end
            continue
        if char == "`":
            end = text.find("`", index + 1)
            end = len(text) if end < 0 else end
            subs.append(text[index + 1:end])
            current.append("`...`")
            index = end + 1
            continue
        if text.startswith("${", index):
            end = text.find("}", index)
            end = len(text) if end < 0 else end + 1
            current.append(text[index:end])
            index = end
            continue
        if char in "{}":
            # Only a standalone brace is a group; a{b,c} and find's {} stay in the word.
            before = text[index - 1:index]
            after = text[index + 1:index + 2]
            if (before in ("", " ", "\t", "\n", ";")) and (after in ("", " ", "\t", "\n", ";")):
                pieces.append(("".join(current), separator))
                current, separator = [], char
            else:
                current.append(char)
            index += 1
            continue
        two = text[index:index + 2]
        if two in ("&&", "||", ";;"):
            pieces.append(("".join(current), separator))
            current, separator = [], two
            index += 2
            continue
        if char in ";|&\n()":
            # >& and &> are redirections, not separators.
            if char == "&" and (text[index - 1:index] in (">", "<") or text[index + 1:index + 2] == ">"):
                current.append(char)
                index += 1
                continue
            if char == "|" and text[index - 1:index] == ">":
                current.append(char)
                index += 1
                continue
            pieces.append(("".join(current), separator))
            current, separator = [], char
            index += 1
            continue
        current.append(char)
        index += 1
    pieces.append(("".join(current), separator))
    out = [(piece.strip(), sep) for piece, sep in pieces if piece.strip()]
    for sub in subs:
        out.extend((piece, "$(") for piece, _sep in split_segments(sub, keep_heredocs=True))
    return out


ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
WRAPPERS = {"time", "nice", "nohup", "stdbuf", "command", "builtin", "exec", "env"}


def command_words(piece):
    """The words of a piece from its command name on: assignments, redirections and
    simple wrappers (timeout N, time, nice, nohup, stdbuf, env) are skipped."""
    items = [word for word, _quoted in words(piece)]
    index = 0
    while index < len(items):
        word = items[index]
        if ASSIGNMENT_RE.match(word):
            index += 1
        elif re.match(r"^[0-9]*(<|>|>>|<<<|<>|>\|)$", word):
            index += 2
        elif re.match(r"^[0-9]*[<>]", word):
            index += 1
        elif word == "timeout":
            index += 1
            while index < len(items) and items[index].startswith("-"):
                index += 1
            index += 1
        elif word in WRAPPERS:
            index += 1
            while index < len(items) and items[index].startswith("-"):
                index += 1
        else:
            break
    return items[index:]


def norm(path):
    normal = posixpath.normpath(path)
    return "/" + normal.lstrip("/") if normal.startswith("/") else normal


def resolve(cwd, path):
    if path.startswith("/"):
        return norm(path)
    return norm(posixpath.join(cwd, path))


def under(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


def track_cwd(calls, project=PROJECT):
    """Annotate each call with the shell's working directory before it ran.

    Claude Code keeps the Bash tool's directory between calls. Only a top-level
    `cd DIR` chained with && or ; is followed, from calls that were not refused;
    a directory outside the project resets to the project, as Claude Code does.
    Anything the tracker cannot follow ($VAR, wildcards, cd in a subshell) leaves
    the directory unchanged. This is an estimate and is reported as one.
    """
    cwd = project
    for call in calls:
        call["cwd"] = cwd
        if call["name"] != "Bash" or call["refused"]:
            continue
        command = (call["input"] or {}).get("command")
        if not isinstance(command, str):
            continue
        here = cwd
        depth = 0
        for piece, separator in split_segments(command):
            if separator == "(":
                depth += 1
            elif separator == ")":
                depth = max(0, depth - 1)
            if depth or separator in ("|", "$("):
                continue
            items = command_words(piece)
            if items[:1] == ["cd"] and len(items) == 2:
                target = items[1]
                if re.search(r"[$`*?\[~]", target) or target == "-":
                    continue
                here = resolve(here, target)
        cwd = here if under(here, project) else project
    return calls
