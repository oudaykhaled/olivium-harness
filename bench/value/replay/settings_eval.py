"""Claude Code permission rules from a settings.json, evaluated on a tool call as text.

An emulation, not Claude Code. It covers what the generated solo settings use:
bare tool rules (`Bash`, `Task`), legacy prefix rules (`Bash(git push:*)`), exact
and wildcard Bash rules, and gitignore-style path rules for `Read(...)` and
`Edit(...)` (Edit rules also cover Write, MultiEdit and NotebookEdit). Order: deny,
then ask, then allow; with no match, `defaultMode` decides, and in headless `-p`
mode an "ask" is a refusal.

What it does not model: Claude Code's own command-safety checks that apply when a
Bash command is not allowed by a rule (backslash-escaped whitespace, `cd` combined
with a write, unparseable input). They are approximated by `ask_heuristics()` only
when the bare `Bash` tool is not allowed; every solo export since 2026-11-10 allows
it, and in the 135 recorded calls of the fix run those checks refused nothing.
"""

import fnmatch
import posixpath
import re

from calls import PROJECT, command_words, norm, split_segments, strip_heredocs, under

EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
READ_TOOLS = {"Read", "Grep", "Glob", "NotebookRead"}
RULE_RE = re.compile(r"^([A-Za-z0-9_]+)(?:\((.*)\))?$", re.S)


def parse_rule(text):
    match = RULE_RE.match(text or "")
    if not match:
        return None
    return match.group(1), match.group(2)


class Settings:
    def __init__(self, data, extra_deny=()):
        permissions = data.get("permissions") or {}
        self.default_mode = permissions.get("defaultMode") or "default"
        self.rules = {}
        for kind in ("deny", "ask", "allow"):
            parsed = []
            items = list(permissions.get(kind) or [])
            if kind == "deny":
                items += [name for name in extra_deny if name not in items]
            for item in items:
                rule = parse_rule(item)
                if rule is not None:
                    parsed.append((item, rule[0], rule[1]))
            self.rules[kind] = parsed
        self.hooks = data.get("hooks") or {}

    def bare(self, kind, tool):
        return any(name == tool and spec is None for _text, name, spec in self.rules[kind])

    def pretool_hooks(self, tool):
        """Commands of the PreToolUse hooks whose matcher selects this tool."""
        out = []
        for entry in self.hooks.get("PreToolUse") or []:
            matcher = entry.get("matcher") or ""
            if matcher and matcher != "*" and not _matcher_hits(matcher, tool):
                continue
            for hook in entry.get("hooks") or []:
                if hook.get("type") == "command" and isinstance(hook.get("command"), str):
                    out.append(hook["command"])
        return out


def _matcher_hits(matcher, tool):
    if re.match(r"^[A-Za-z0-9_|]+$", matcher):
        return tool in matcher.split("|")
    try:
        return re.fullmatch(matcher, tool) is not None
    except re.error:
        return False


# --------------------------------------------------------------------------- Bash rules
def bash_rule_hits(spec, piece_words):
    """A Bash rule specifier against one piece's command words."""
    text = " ".join(piece_words)
    if spec.endswith(":*"):
        prefix = spec[:-2].strip()
        return text == prefix or text.startswith(prefix + " ")
    if "*" in spec:
        pattern = re.escape(spec).replace(r"\*", ".*")
        return re.fullmatch(pattern, text, re.S) is not None
    return text == spec.strip()


def bash_pieces(command):
    return [command_words(piece) for piece, _sep in split_segments(command) if command_words(piece)]


# --------------------------------------------------------------------------- path rules
def path_rule_hits(spec, path, project=PROJECT):
    """gitignore-style: a pattern without a slash matches the name at any depth;
    otherwise it matches the project-relative path ('**' spans directories)."""
    if not isinstance(path, str) or not path:
        return False
    absolute = norm(path if path.startswith("/") else posixpath.join(project, path))
    if spec.startswith("//"):
        return _glob(spec[1:], absolute)
    if spec.startswith("~/"):
        return _glob("/home/agent/" + spec[2:], absolute)
    anchored = spec.startswith("./") or spec.startswith("/")
    pattern = spec[2:] if spec.startswith("./") else spec
    if not anchored and "/" not in pattern.rstrip("/"):
        return any(_glob(pattern, part) for part in absolute.split("/") if part)
    if not under(absolute, project):
        return False
    relative = absolute[len(project):].lstrip("/")
    return _glob(pattern.lstrip("/"), relative)


def _glob(pattern, text):
    regex = ""
    index = 0
    while index < len(pattern):
        if pattern.startswith("**/", index):
            regex += "(?:.*/)?"
            index += 3
        elif pattern.startswith("**", index):
            regex += ".*"
            index += 2
        elif pattern[index] == "*":
            regex += "[^/]*"
            index += 1
        elif pattern[index] == "?":
            regex += "[^/]"
            index += 1
        else:
            regex += re.escape(pattern[index])
            index += 1
    return re.fullmatch(regex, text) is not None


# --------------------------------------------------------------------------- decision
ASK_REASONS = (
    ("command_substitution", re.compile(r"\$\(|`")),
    ("backslash_whitespace", re.compile(r"\\[ \t]")),
)


def ask_heuristics(command):
    """Approximate Claude Code checks that ask before a Bash command no rule allows.

    Run on the command without here-document bodies (they are data). A
    here-document alone is not a trigger: on the first Olivium run's own settings
    it predicted 3 recorded refusals and 24 calls that were not refused.
    """
    command = strip_heredocs(command)
    found = [name for name, regex in ASK_REASONS if regex.search(command)]
    pieces = bash_pieces(command)
    has_cd = any(p[:1] == ["cd"] for p in pieces)
    if has_cd and (re.search(r"(?<![0-9&])>>?\s*[^&\s]", command) or any(p[:1] in (["git"], ["rm"], ["mv"], ["cp"], ["sed"]) for p in pieces)):
        found.append("cd_with_write_or_git")
    return found


def decide(settings, tool, tool_input, cwd=PROJECT, project=PROJECT):
    """(decision, rule, detail): decision is allow, deny or ask."""
    tool_input = tool_input if isinstance(tool_input, dict) else {}
    for kind in ("deny", "ask"):
        hit = _first_hit(settings, kind, tool, tool_input, cwd, project)
        if hit:
            return kind, hit, None
    hit = _first_hit(settings, "allow", tool, tool_input, cwd, project)
    if tool == "Bash" and not settings.bare("allow", "Bash"):
        command = tool_input.get("command") if isinstance(tool_input.get("command"), str) else ""
        allowed = [spec for _text, name, spec in settings.rules["allow"] if name == "Bash" and spec is not None]
        unmatched = [" ".join(p)[:80] for p in bash_pieces(command) if not any(bash_rule_hits(spec, p) for spec in allowed)]
        reasons = ask_heuristics(command)
        if settings.default_mode == "bypassPermissions":
            return "allow", "defaultMode bypassPermissions", None
        if unmatched or reasons:
            return "ask", None, {"unmatched": unmatched[:5], "checks": reasons}
        return "allow", "Bash(...) rules for every piece", None
    if hit:
        return "allow", hit, None
    if settings.default_mode == "bypassPermissions":
        return "allow", "defaultMode bypassPermissions", None
    if tool in READ_TOOLS:
        return "allow", "read-only tool", None
    if tool in EDIT_TOOLS and settings.default_mode == "acceptEdits":
        return "allow", "defaultMode acceptEdits", None
    return "ask", None, {"unmatched": [tool], "checks": []}


def _first_hit(settings, kind, tool, tool_input, cwd, project):
    for text, name, spec in settings.rules[kind]:
        if spec is None:
            if name == tool:
                return text
            continue
        if name == "Bash" and tool == "Bash":
            command = tool_input.get("command")
            if isinstance(command, str) and any(bash_rule_hits(spec, p) for p in bash_pieces(command)):
                if kind == "allow":
                    # An allow rule covers a compound command only through decide(); here it marks a hit.
                    return text
                return text
        elif name == "Edit" and tool in EDIT_TOOLS:
            if path_rule_hits(spec, tool_input.get("file_path") or tool_input.get("notebook_path"), project):
                return text
        elif name == "Read" and tool in READ_TOOLS:
            if path_rule_hits(spec, tool_input.get("file_path") or tool_input.get("path"), project):
                return text
        elif name == tool and spec in ("*", ""):
            return text
    return None
