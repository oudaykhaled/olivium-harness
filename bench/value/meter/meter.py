#!/usr/bin/env python3
"""Value benchmark meter: a metering reverse proxy for the Anthropic Messages API.

Standard library only. The agent container reaches the API solely through
http://meter:8080/run/<run_id>/... ; the meter strips the prefix, attributes the
usage to <run_id>, appends to requests.jsonl and enforces USD caps.

Modes
  mock  scripted Messages responses, no upstream connection is ever constructed.
  live  forwards to https://api.anthropic.com, injecting the key from --key-file.

Fail-closed rules
  * unknown model, unwritable log, unreadable price table: nothing is forwarded;
  * a 200 upstream response without readable usage halts the meter;
  * caps are required arguments and survive a restart (the log is replayed);
  * with --refuse-web-tools, a Messages request that offers a web search or web
    fetch server tool is refused (403, no retry) and logged as refused_web_tool.

The log never contains headers, request bodies or the key. Each Messages record
carries "shape": sizes only (characters of system text, tool definitions and
messages), never their content.

Request capture (mock mode only): --capture-dir DIR writes each Messages request
body, without headers, to DIR/<run_id>/req-NNNN.json, so the fixed prefix of a
setup can be measured without a model. Live mode refuses the flag.
"""
from __future__ import annotations

import argparse
import base64
import binascii
import http.client
import json
import os
import re
import signal
import ssl
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

RUN_PATH = re.compile(r"^/run/([A-Za-z0-9][A-Za-z0-9._-]{0,127})(/.*)$")
ALLOWED_API_PATHS = {"/v1/messages", "/v1/messages/count_tokens"}
MAX_BODY_BYTES = 32 * 1024 * 1024
MAX_SSE_EVENT_BYTES = 8 * 1024 * 1024
UPSTREAM_HOST = "api.anthropic.com"
ERROR_TYPES = {
    400: "invalid_request_error", 401: "authentication_error", 402: "billing_error",
    403: "permission_error", 404: "not_found_error", 411: "invalid_request_error",
    413: "request_too_large", 429: "rate_limit_error", 500: "api_error",
    502: "api_error", 503: "api_error", 529: "overloaded_error",
}
# Chosen by experiment (docker/prove.py, section cap_experiment): 402 ends a
# Claude Code session after one refused request; 400 is re-sent up to six times.
DEFAULT_CAP_STATUS = 402
FORWARD_REQUEST_HEADERS = ("anthropic-", "x-stainless-")
FORWARD_REQUEST_EXACT = {"x-app", "user-agent", "content-type", "accept"}
DROP_RESPONSE_HEADERS = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te",
    "trailer", "transfer-encoding", "upgrade", "content-length", "content-encoding",
    "set-cookie",
}
USAGE_FIELDS = (
    "input_tokens", "output_tokens",
    "cache_creation_input_tokens", "cache_read_input_tokens",
)


class SecretKey:
    """Holds the API key; every printable form is redacted."""

    __slots__ = ("_value",)

    def __init__(self, value: str):
        self._value = value

    def reveal(self) -> str:
        return self._value

    def __repr__(self) -> str:
        return "SecretKey(<redacted>)"

    __str__ = __repr__


def load_key(path: str) -> SecretKey:
    with open(path, encoding="utf-8") as handle:
        value = handle.read().strip()
    if not value or "\n" in value:
        raise ValueError("key file must contain exactly one non-empty line")
    return SecretKey(value)


# --------------------------------------------------------------------------
# Prices
# --------------------------------------------------------------------------
class UnknownModel(Exception):
    pass


RATE_NAMES = ("input", "output", "cache_write_5m", "cache_write_1h", "cache_read")


def _nanos_per_token(rate) -> int:
    """USD/MTok to integer nano-USD per token. Rejects sub-nano precision."""
    if isinstance(rate, bool) or not isinstance(rate, (int, float)) or rate < 0:
        raise ValueError(f"invalid rate: {rate!r}")
    scaled = rate * 1000
    rounded = round(scaled)
    if abs(scaled - rounded) > 1e-9:
        raise ValueError(f"rate has sub-nano precision: {rate!r}")
    return int(rounded)


class Prices:
    def __init__(self, table: dict):
        self.rates: dict[str, dict] = {}
        models = table.get("models")
        if not isinstance(models, dict) or not models:
            raise ValueError("prices: models missing")
        for model, entry in models.items():
            if entry.get("unverified") is not False:
                raise ValueError(f"prices: {model} is not marked verified")
            parsed = {name: _nanos_per_token(entry[name]) for name in RATE_NAMES}
            tier = entry.get("over_prompt_tokens")
            if tier is not None:
                parsed["tier_threshold"] = int(tier["threshold"])
                parsed["tier"] = {name: _nanos_per_token(tier[name]) for name in RATE_NAMES}
            self.rates[model] = parsed
        aliases = table.get("aliases", {})
        for alias, target in aliases.items():
            if target not in self.rates:
                raise ValueError(f"prices: alias {alias} -> unknown {target}")
        self.aliases = dict(aliases)

    @classmethod
    def load(cls, path: str) -> "Prices":
        with open(path, encoding="utf-8") as handle:
            return cls(json.load(handle))

    def known(self, model) -> bool:
        return isinstance(model, str) and (model in self.rates or model in self.aliases)

    def _entry(self, model: str) -> dict:
        canonical = self.aliases.get(model, model)
        if canonical not in self.rates:
            raise UnknownModel(model)
        return self.rates[canonical]

    def most_expensive(self) -> dict:
        return max(self.rates.values(), key=lambda entry: entry["output"])

    def cost_nanos(self, model: str, usage: "UsageTracker", *, fallback=False) -> int:
        entry = self.most_expensive() if fallback else self._entry(model)
        cache_5m, cache_1h = usage.cache_split()
        values = usage.values
        prompt_tokens = (
            values["input_tokens"] + values["cache_read_input_tokens"]
            + values["cache_creation_input_tokens"]
        )
        rates = entry
        if "tier" in entry and prompt_tokens > entry["tier_threshold"]:
            rates = entry["tier"]
        return (
            values["input_tokens"] * rates["input"]
            + values["output_tokens"] * rates["output"]
            + cache_5m * rates["cache_write_5m"]
            + cache_1h * rates["cache_write_1h"]
            + values["cache_read_input_tokens"] * rates["cache_read"]
        )


# --------------------------------------------------------------------------
# Usage parsing
# --------------------------------------------------------------------------
class UsageTracker:
    """Accumulates the usage block from message_start, message_delta or a body."""

    def __init__(self) -> None:
        self.values = dict.fromkeys(USAGE_FIELDS, 0)
        self.seen = False
        self.delta_seen = False
        self.cache_5m = None
        self.cache_1h = None
        self.model = None
        self.stop_reason = None
        self.error_type = None

    def apply(self, usage) -> None:
        if not isinstance(usage, dict):
            return
        self.seen = True
        for field in USAGE_FIELDS:
            value = usage.get(field)
            if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
                self.values[field] = value
        split = usage.get("cache_creation")
        if isinstance(split, dict):
            for attr, key in (("cache_5m", "ephemeral_5m_input_tokens"), ("cache_1h", "ephemeral_1h_input_tokens")):
                value = split.get(key)
                if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
                    setattr(self, attr, value)

    def cache_split(self):
        total = self.values["cache_creation_input_tokens"]
        if self.cache_5m is None and self.cache_1h is None:
            return total, 0
        five, hour = self.cache_5m or 0, self.cache_1h or 0
        if five + hour < total:
            five += total - five - hour
        return five, hour

    def on_event(self, name: str, data: dict) -> None:
        if name == "message_start":
            message = data.get("message") or {}
            self.model = message.get("model") or self.model
            self.apply(message.get("usage"))
        elif name == "message_delta":
            self.delta_seen = True
            self.apply(data.get("usage"))
            self.stop_reason = (data.get("delta") or {}).get("stop_reason") or self.stop_reason
        elif name == "error":
            self.error_type = (data.get("error") or {}).get("type", "unknown")

    def on_body(self, data: dict) -> None:
        self.model = data.get("model") or self.model
        self.stop_reason = data.get("stop_reason") or self.stop_reason
        self.apply(data.get("usage"))
        self.delta_seen = True


class SSEParser:
    """Incremental SSE parser. Observes bytes; the relay never depends on it."""

    BOUNDARY = re.compile(rb"\r?\n\r?\n")

    def __init__(self, tracker: UsageTracker) -> None:
        self.tracker = tracker
        self.buffer = b""
        self.overflowed = False

    def feed(self, chunk: bytes) -> None:
        self.buffer += chunk
        while True:
            match = self.BOUNDARY.search(self.buffer)
            if match is None:
                break
            raw, self.buffer = self.buffer[: match.start()], self.buffer[match.end() :]
            self._event(raw)
        if len(self.buffer) > MAX_SSE_EVENT_BYTES:
            self.overflowed = True
            self.buffer = b""

    def _event(self, raw: bytes) -> None:
        name = None
        data_lines = []
        for line in raw.split(b"\n"):
            line = line.rstrip(b"\r")
            if line.startswith(b"event:"):
                name = line[6:].strip().decode("utf-8", "replace")
            elif line.startswith(b"data:"):
                data_lines.append(line[5:].lstrip())
        if not data_lines:
            return
        try:
            data = json.loads(b"\n".join(data_lines))
        except (ValueError, UnicodeDecodeError):
            return
        if not isinstance(data, dict):
            return
        self.tracker.on_event(name or data.get("type") or "", data)


# --------------------------------------------------------------------------
# Ledger: caps and the request log
# --------------------------------------------------------------------------
class Ledger:
    """Per-run and total spend in integer nano-USD, plus the append-only log."""

    def __init__(self, log_path: str, run_cap: int, total_cap: int, reserve: int) -> None:
        self.log_path = log_path
        self.run_cap = run_cap
        self.total_cap = total_cap
        self.reserve = reserve
        self.lock = threading.Lock()
        self.run_spent: dict[str, int] = {}
        self.run_seq: dict[str, int] = {}
        self.total_spent = 0
        self.inflight = 0
        self.log_ok = True
        self.halted = False
        self._replay()
        self.fd = os.open(log_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)

    def _replay(self) -> None:
        try:
            handle = open(self.log_path, encoding="utf-8")
        except FileNotFoundError:
            return
        with handle:
            for number, line in enumerate(handle, 1):
                if not line.strip():
                    continue
                try:
                    record = json.loads(line)
                    run_id, cost = record["run_id"], int(record["cost_nanousd"])
                except (ValueError, KeyError, TypeError) as exc:
                    raise ValueError(f"unreadable log line {number}") from exc
                self.run_spent[run_id] = self.run_spent.get(run_id, 0) + cost
                self.run_seq[run_id] = self.run_seq.get(run_id, 0) + 1
                self.total_spent += cost

    def _log_writable(self) -> bool:
        try:
            fd = os.open(self.log_path, os.O_WRONLY | os.O_APPEND)
        except OSError:
            return False
        os.close(fd)
        return True

    def _next_seq(self, run_id: str) -> int:
        self.run_seq[run_id] = self.run_seq.get(run_id, 0) + 1
        return self.run_seq[run_id]

    def admit(self, run_id: str):
        """Returns (refusal_status or None, seq)."""
        with self.lock:
            seq = self._next_seq(run_id)
            if self.halted:
                return "halted", seq
            if not self.log_ok or not self._log_writable():
                self.log_ok = False
                return "log_error", seq
            if self.run_spent.get(run_id, 0) >= self.run_cap:
                return "cap_run", seq
            if self.total_spent + (self.inflight + 1) * self.reserve >= self.total_cap:
                return "cap_total", seq
            self.inflight += 1
            return None, seq

    def _write(self, record: dict) -> None:
        line = json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n"
        try:
            os.write(self.fd, line.encode("utf-8"))
        except OSError:
            self.log_ok = False
            print("meter: request log write failed; refusing further requests", file=sys.stderr, flush=True)

    def settle(self, record: dict, *, admitted: bool) -> None:
        with self.lock:
            if admitted:
                self.inflight -= 1
            cost = record["cost_nanousd"]
            self.run_spent[record["run_id"]] = self.run_spent.get(record["run_id"], 0) + cost
            self.total_spent += cost
            self._write(record)

    def note(self, record: dict) -> None:
        """Log a request that was never admitted and has no run attribution."""
        with self.lock:
            self._write(record)

    def halt(self) -> None:
        with self.lock:
            self.halted = True


# --------------------------------------------------------------------------
# Mock model
# --------------------------------------------------------------------------
BACKGROUND_USAGE = {
    "input_tokens": 10, "output_tokens": 5,
    "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0,
}
TARGET_MARKER = re.compile(r"OLIVIUM_MOCK_TARGET=(\S+)")
PLAN_MARKER = re.compile(r"OLIVIUM_MOCK_PLAN_B64=([A-Za-z0-9+/=_-]+)")
WEB_TOOL = re.compile(r"^web_(search|fetch)(_|$)")
READ_LINE = re.compile(r"^\s*\d+[\t→](.*)$")
MOCK_WORKDIR = "/work/repo"
MOCK_EDIT_SUFFIX = " OLIVIUM_MOCK_EDIT"


def main_turn_usage(step: int) -> dict:
    """Deterministic usage for scripted main-session turn `step` (0-based)."""
    return {
        "input_tokens": 1000 + 100 * step,
        "output_tokens": 50 + 10 * step,
        "cache_creation_input_tokens": 200,
        "cache_read_input_tokens": 300 * step,
        "cache_creation": {"ephemeral_5m_input_tokens": 150, "ephemeral_1h_input_tokens": 50},
    }


def server_tool_types(body: dict) -> list:
    """`type` of every offered tool that is not a plain client tool (server and
    Anthropic-defined tools carry a versioned type, for example web_search_20250305)."""
    tools = body.get("tools")
    if not isinstance(tools, list):
        return []
    return sorted({tool["type"] for tool in tools
                   if isinstance(tool, dict) and isinstance(tool.get("type"), str) and tool["type"] != "custom"})


def web_tools(body: dict) -> list:
    """Web search or web fetch server tools offered in a request, by type or name."""
    tools = body.get("tools")
    if not isinstance(tools, list):
        return []
    found = set()
    for tool in tools:
        if not isinstance(tool, dict):
            continue
        for value in (tool.get("type"), tool.get("name")):
            if isinstance(value, str) and WEB_TOOL.match(value):
                found.add(value)
    return sorted(found)


def _block_texts(content) -> list:
    if isinstance(content, str):
        return [content]
    texts = []
    if isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text" and isinstance(block.get("text"), str):
                texts.append(block["text"])
    return texts


def _first_user_text(messages) -> str:
    for message in messages:
        if isinstance(message, dict) and message.get("role") == "user":
            return "\n".join(_block_texts(message.get("content")))
    return ""


def _content_chars(content) -> int:
    """Characters the model reads from a content field: text blocks as text, others as JSON."""
    if isinstance(content, str):
        return len(content)
    total = 0
    if isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text" and isinstance(block.get("text"), str):
                total += len(block["text"])
            else:
                total += len(json.dumps(block, ensure_ascii=False))
    return total


def request_shape(body: dict) -> dict:
    """Sizes of what a Messages request carries. Numbers only: no text leaves this function."""
    system = body.get("system")
    if isinstance(system, str):
        system_chars = len(system)
    elif isinstance(system, list):
        system_chars = sum(len(b.get("text", "")) for b in system if isinstance(b, dict) and isinstance(b.get("text"), str))
    else:
        system_chars = 0
    tools = [t for t in body.get("tools") or [] if isinstance(t, dict)]
    tools_chars = sum(len(json.dumps(t, ensure_ascii=False)) for t in tools)
    messages = [m for m in body.get("messages") or [] if isinstance(m, dict)]
    message_chars = [_content_chars(m.get("content")) for m in messages]
    first_user = next((n for m, n in zip(messages, message_chars) if m.get("role") == "user"), 0)
    return {"system_chars": system_chars, "tools": len(tools), "tools_chars": tools_chars,
            "messages": len(messages), "messages_chars": sum(message_chars), "first_user_chars": first_user,
            "total_chars": system_chars + tools_chars + sum(message_chars)}


def _last_tool_result(messages):
    """(text, is_error) of the newest tool_result, or (None, True)."""
    for message in reversed(messages):
        content = message.get("content") if isinstance(message, dict) else None
        if not isinstance(content, list):
            continue
        for block in reversed(content):
            if isinstance(block, dict) and block.get("type") == "tool_result":
                texts = _block_texts(block.get("content"))
                return "\n".join(texts), bool(block.get("is_error"))
    return None, True


def edit_from_read_result(result_text: str, target: str):
    """Builds Edit input from Read output: the first line unique in the file."""
    lines = []
    for raw in result_text.splitlines():
        match = READ_LINE.match(raw)
        if match:
            lines.append(match.group(1))
    for line in lines:
        if line.strip() and sum(1 for other in lines if line in other) == 1:
            return {"file_path": target, "old_string": line, "new_string": line + MOCK_EDIT_SUFFIX}
    return None


def _decode_plan(text: str):
    match = PLAN_MARKER.search(text)
    if not match:
        return None
    try:
        plan = json.loads(base64.b64decode(match.group(1), validate=False))
    except (binascii.Error, ValueError):
        return {"steps": [], "final_text": "mock: invalid plan"}
    if not isinstance(plan, dict) or not isinstance(plan.get("steps"), list):
        return {"steps": [], "final_text": "mock: invalid plan"}
    return plan


def mock_turn(body: dict, plan_any_tools: bool = False) -> dict:
    """Picks the scripted turn from the request alone (no server-side state).

    A main session offers Read and Edit. With plan_any_tools, a request with any tool list whose first user text
    carries a plan follows it too: a subagent with a restricted tool list (for example Read, Grep, Glob), driven by a
    plan nested in the prompt the main plan gives it."""
    tools = body.get("tools")
    names = {tool.get("name") for tool in tools if isinstance(tool, dict)} if isinstance(tools, list) else set()
    messages = body.get("messages") if isinstance(body.get("messages"), list) else []
    planned = plan_any_tools and bool(names) and _decode_plan(_first_user_text(messages)) is not None
    if not {"Read", "Edit"} <= names and not planned:
        return {"kind": "background", "usage": BACKGROUND_USAGE, "text": "OK", "tool": None, "step": 0}
    step = sum(
        1 for message in messages
        if isinstance(message, dict) and message.get("role") == "assistant"
        and isinstance(message.get("content"), list)
        and any(isinstance(b, dict) and b.get("type") == "tool_use" for b in message["content"])
    )
    usage = main_turn_usage(step)
    prompt = _first_user_text(messages)
    plan = _decode_plan(prompt)
    if plan is not None:
        steps = plan["steps"]
        if step < len(steps) and isinstance(steps[step], dict) and isinstance(steps[step].get("name"), str):
            call = steps[step]
            return {"kind": "main", "usage": usage, "step": step, "text": f"Mock step {step}.",
                    "tool": (call["name"], call.get("input") or {})}
        return {"kind": "main", "usage": usage, "step": step, "tool": None,
                "text": str(plan.get("final_text") or "Mock plan complete.")}
    marker = TARGET_MARKER.search(prompt)
    target = marker.group(1) if marker else "README.md"
    if not target.startswith("/"):
        target = f"{MOCK_WORKDIR}/{target}"
    if step == 0:
        return {"kind": "main", "usage": usage, "step": step, "text": "Reading the file.",
                "tool": ("Read", {"file_path": target})}
    if step == 1:
        result_text, is_error = _last_tool_result(messages)
        edit = None if is_error or result_text is None else edit_from_read_result(result_text, target)
        if edit is not None:
            return {"kind": "main", "usage": usage, "step": step, "text": "Editing the file.",
                    "tool": ("Edit", edit)}
    return {"kind": "main", "usage": usage, "step": step, "tool": None, "text": "Mock session complete."}


def _sse(event: str, data: dict) -> bytes:
    return f"event: {event}\ndata: {json.dumps(data, separators=(',', ':'))}\n\n".encode()


def _content_blocks(turn: dict, tool_id: str) -> list:
    blocks = [{"type": "text", "text": turn["text"]}]
    if turn["tool"] is not None:
        blocks.append({"type": "tool_use", "id": tool_id, "name": turn["tool"][0], "input": turn["tool"][1]})
    return blocks


def mock_message(turn: dict, model: str, run_id: str, seq: int) -> dict:
    return {
        "id": f"msg_mock_{run_id}_{seq}", "type": "message", "role": "assistant", "model": model,
        "content": _content_blocks(turn, f"toolu_mock_{run_id}_{seq}"),
        "stop_reason": "tool_use" if turn["tool"] is not None else "end_turn",
        "stop_sequence": None, "usage": turn["usage"],
    }


def mock_stream(turn: dict, model: str, run_id: str, seq: int):
    """Yields one SSE event at a time, matching the Messages streaming shape."""
    final = mock_message(turn, model, run_id, seq)
    start_usage = dict(turn["usage"], output_tokens=1)
    yield _sse("message_start", {"type": "message_start", "message": {
        **{k: final[k] for k in ("id", "type", "role", "model")},
        "content": [], "stop_reason": None, "stop_sequence": None, "usage": start_usage}})
    yield _sse("ping", {"type": "ping"})
    for index, block in enumerate(final["content"]):
        if block["type"] == "text":
            yield _sse("content_block_start", {"type": "content_block_start", "index": index,
                                               "content_block": {"type": "text", "text": ""}})
            text = block["text"]
            cut = max(1, len(text) // 2)
            for piece in (text[:cut], text[cut:]):
                if piece:
                    yield _sse("content_block_delta", {"type": "content_block_delta", "index": index,
                                                       "delta": {"type": "text_delta", "text": piece}})
        else:
            yield _sse("content_block_start", {"type": "content_block_start", "index": index, "content_block": {
                "type": "tool_use", "id": block["id"], "name": block["name"], "input": {}}})
            encoded = json.dumps(block["input"], separators=(",", ":"))
            cut = max(1, len(encoded) // 2)
            for piece in (encoded[:cut], encoded[cut:]):
                if piece:
                    yield _sse("content_block_delta", {"type": "content_block_delta", "index": index,
                                                       "delta": {"type": "input_json_delta", "partial_json": piece}})
        yield _sse("content_block_stop", {"type": "content_block_stop", "index": index})
    yield _sse("message_delta", {"type": "message_delta",
                                 "delta": {"stop_reason": final["stop_reason"], "stop_sequence": None},
                                 "usage": {"output_tokens": turn["usage"]["output_tokens"]}})
    yield _sse("message_stop", {"type": "message_stop"})


# --------------------------------------------------------------------------
# Application
# --------------------------------------------------------------------------
def default_connection_factory():
    return http.client.HTTPSConnection(UPSTREAM_HOST, 443, timeout=900, context=ssl.create_default_context())


def filtered_request_headers(headers, key: SecretKey) -> dict:
    """Allowlist only; the client's dummy credentials never leave the meter."""
    out = {}
    for name, value in headers.items():
        lower = name.lower()
        if lower in FORWARD_REQUEST_EXACT or lower.startswith(FORWARD_REQUEST_HEADERS):
            out[lower] = value
    out["x-api-key"] = key.reveal()
    out["accept-encoding"] = "identity"
    return out


class App:
    def __init__(self, *, mode, prices, ledger, cap_status=DEFAULT_CAP_STATUS, key=None,
                 connection_factory=None, cap_allow_retry=False, refuse_web_tools=False, capture_dir=None,
                 plan_any_tools=False):
        if mode not in ("mock", "live"):
            raise ValueError("mode must be mock or live")
        if capture_dir is not None and mode != "mock":
            raise ValueError("request capture is mock mode only")
        if plan_any_tools and mode != "mock":
            raise ValueError("plan_any_tools is mock mode only")
        if mode == "mock" and key is not None:
            raise ValueError("mock mode must not hold a key")
        if mode == "live" and key is None:
            raise ValueError("live mode requires a key")
        self.mode = mode
        self.prices = prices
        self.ledger = ledger
        self.cap_status = cap_status
        self.cap_allow_retry = cap_allow_retry
        self.refuse_web_tools = refuse_web_tools
        self.key = key
        self.capture_dir = capture_dir
        self.plan_any_tools = bool(plan_any_tools)
        self.connection_factory = connection_factory or default_connection_factory

    # Record helpers -------------------------------------------------------
    def base_record(self, run_id, seq, endpoint, model, stream, max_tokens) -> dict:
        record = {
            "ts": round(time.time(), 3), "mode": self.mode, "run_id": run_id, "seq": seq,
            "endpoint": endpoint, "model": model, "stream": stream, "max_tokens": max_tokens,
            "status": "", "http_status": 0, "stop_reason": None, "cost_usd": 0.0, "cost_nanousd": 0,
            "cache_creation_5m": 0, "cache_creation_1h": 0, "duration_ms": 0,
        }
        for field in USAGE_FIELDS:
            record[field] = 0
        return record

    def fill_usage(self, record: dict, tracker: UsageTracker, request_model: str) -> None:
        for field in USAGE_FIELDS:
            record[field] = tracker.values[field]
        record["cache_creation_5m"], record["cache_creation_1h"] = tracker.cache_split()
        record["stop_reason"] = tracker.stop_reason
        response_model = tracker.model or request_model
        if self.prices.known(response_model):
            nanos = self.prices.cost_nanos(response_model, tracker)
            record["price_model"] = response_model
        elif (self.prices.known(request_model) and isinstance(response_model, str)
              and response_model.startswith(f"{request_model}-")):
            # A dated snapshot of the model the client asked for (for example the
            # response names claude-haiku-5-5-20261001): the requested price applies.
            nanos = self.prices.cost_nanos(request_model, tracker)
            record["price_model"] = request_model
            record["response_model"] = response_model
        else:
            nanos = self.prices.cost_nanos(request_model, tracker, fallback=True)
            record["price_model"] = "fallback_most_expensive"
            record["response_model"] = response_model
        record["cost_nanousd"] = nanos
        record["cost_usd"] = round(nanos / 1e9, 9)

    # HTTP entry point -----------------------------------------------------
    def handle_post(self, handler: "Handler") -> None:
        started = time.monotonic()
        split = urlsplit(handler.path)
        length = handler.headers.get("content-length")
        if length is None or not length.isdigit():
            handler.send_error_json(411, "content-length required")
            return
        length = int(length)
        if length > MAX_BODY_BYTES:
            handler.close_connection = True
            handler.send_error_json(413, "request too large")
            return
        raw_body = handler.rfile.read(length)
        match = RUN_PATH.match(split.path)
        if match is None or match.group(2) not in ALLOWED_API_PATHS:
            run_id = match.group(1) if match else "unattributed"
            self.ledger.note({**self.base_record(run_id, 0, match.group(2) if match else "invalid", None, False, None),
                              "status": "not_found", "http_status": 404})
            handler.send_error_json(404, "only /run/<run_id>/v1/messages is served", no_retry=True)
            return
        run_id, api_path = match.group(1), match.group(2)
        endpoint = "count_tokens" if api_path.endswith("count_tokens") else "messages"
        query = f"?{split.query}" if split.query else ""
        try:
            body = json.loads(raw_body)
            if not isinstance(body, dict):
                raise ValueError("body must be an object")
        except ValueError:
            self.ledger.note({**self.base_record(run_id, 0, endpoint, None, False, None),
                              "status": "bad_request", "http_status": 400})
            handler.send_error_json(400, "body must be JSON object", no_retry=True)
            return
        model = body.get("model")
        stream = bool(body.get("stream")) if endpoint == "messages" else False
        max_tokens = body.get("max_tokens") if isinstance(body.get("max_tokens"), int) else None
        if not self.prices.known(model):
            self.ledger.note({**self.base_record(run_id, 0, endpoint, model if isinstance(model, str) else None,
                                                 stream, max_tokens),
                              "status": "unknown_model", "http_status": 400})
            handler.send_error_json(400, "model not in price table", no_retry=True)
            return
        offered_web = web_tools(body)
        if self.refuse_web_tools and endpoint == "messages" and offered_web:
            # Fail closed: the search would run on the API side, outside the
            # container's isolation, and its fee is not in the price table.
            self.ledger.note({**self.base_record(run_id, 0, endpoint, model, stream, max_tokens),
                              "status": "refused_web_tool", "http_status": 403, "web_tools": offered_web})
            handler.send_error_json(403, "olivium-bench meter: web tools are not allowed in this benchmark",
                                    no_retry=True)
            return
        refusal, seq = self.ledger.admit(run_id)
        record = self.base_record(run_id, seq, endpoint, model, stream, max_tokens)
        server_tools = server_tool_types(body)
        if server_tools:
            record["server_tools"] = server_tools
        if offered_web:
            record["web_tools"] = offered_web
        if endpoint == "messages":
            record["shape"] = request_shape(body)
        if refusal is not None:
            status = self.cap_status
            record.update(status=refusal, http_status=status)
            record["duration_ms"] = round((time.monotonic() - started) * 1000)
            self.ledger.settle(record, admitted=False)
            handler.send_error_json(status, f"olivium-bench meter stop: {refusal}", no_retry=not self.cap_allow_retry)
            return
        settled = False

        def finish() -> None:
            """Settles once. Called before the client can see the end of the response,
            so its next request is always judged against this request's cost."""
            nonlocal settled
            if settled:
                return
            settled = True
            record["duration_ms"] = round((time.monotonic() - started) * 1000)
            self.ledger.settle(record, admitted=True)

        try:
            if self.mode == "mock":
                self._serve_mock(handler, record, body, run_id, seq, model, stream, endpoint, finish)
            else:
                self._serve_live(handler, record, raw_body, api_path + query, model, endpoint, finish)
        except (BrokenPipeError, ConnectionResetError):
            record["status"] = record["status"] or "client_aborted"
        except Exception:  # noqa: BLE001 - a failure must never lose the ledger entry
            record["status"] = record["status"] or "meter_error"
            handler.close_connection = True
            print("meter: internal error while serving a request", file=sys.stderr, flush=True)
        finally:
            finish()

    # Mock ------------------------------------------------------------------
    def _capture(self, run_id, seq, body) -> None:
        """Mock mode only (checked again here): the request body, never headers."""
        if self.mode != "mock" or self.capture_dir is None:
            return
        directory = os.path.join(self.capture_dir, run_id)
        os.makedirs(directory, exist_ok=True)
        path = os.path.join(directory, f"req-{seq:04d}.json")
        with open(path + ".part", "w", encoding="utf-8") as handle:
            json.dump({"run_id": run_id, "seq": seq, "body": body}, handle, ensure_ascii=False)
        os.replace(path + ".part", path)

    def _serve_mock(self, handler, record, body, run_id, seq, model, stream, endpoint, finish) -> None:
        if endpoint == "messages":
            try:
                self._capture(run_id, seq, body)
                record["captured"] = self.capture_dir is not None
            except OSError:
                record["captured"] = False
                print("meter: request capture failed", file=sys.stderr, flush=True)
        if endpoint == "count_tokens":
            record.update(status="ok", http_status=200)
            finish()
            handler.send_json(200, {"input_tokens": 42})
            return
        turn = mock_turn(body, self.plan_any_tools)
        record["mock_kind"] = turn["kind"]
        record["mock_step"] = turn["step"]
        tracker = UsageTracker()
        if stream:
            handler.begin_chunked(200, {"content-type": "text/event-stream; charset=utf-8", "cache-control": "no-cache",
                                        "request-id": f"req_mock_{seq}"})
            parser = SSEParser(tracker)
            chunks = list(mock_stream(turn, model, run_id, seq))
            for chunk in chunks[:-1]:
                parser.feed(chunk)
                handler.send_chunk(chunk)
            parser.feed(chunks[-1])
            self.fill_usage(record, tracker, model)
            record.update(status="ok", http_status=200)
            finish()
            handler.send_chunk(chunks[-1])
            handler.end_chunked()
        else:
            message = mock_message(turn, model, run_id, seq)
            tracker.on_body(message)
            self.fill_usage(record, tracker, model)
            record.update(status="ok", http_status=200)
            finish()
            handler.send_json(200, message, extra={"request-id": f"req_mock_{seq}"})

    # Live ------------------------------------------------------------------
    def _serve_live(self, handler, record, raw_body, target, model, endpoint, finish) -> None:
        connection = self.connection_factory()
        try:
            try:
                connection.request("POST", target, body=raw_body,
                                   headers=filtered_request_headers(handler.headers, self.key))
                response = connection.getresponse()
            except (OSError, http.client.HTTPException):
                record.update(status="upstream_unreachable", http_status=502)
                finish()
                handler.send_error_json(502, "upstream unreachable")
                return
            code = response.status
            content_type = (response.getheader("content-type") or "").lower()
            headers = {name.lower(): value for name, value in response.getheaders()
                       if name.lower() not in DROP_RESPONSE_HEADERS}
            record["http_status"] = code
            if endpoint == "count_tokens" or code != 200:
                payload = response.read()
                record["status"] = "ok" if code == 200 else f"upstream_{code}"
                finish()
                handler.send_bytes(code, payload, headers)
                return
            tracker = UsageTracker()
            if "text/event-stream" in content_type:
                self._relay_stream(handler, response, headers, tracker, record, model, finish)
            else:
                payload = response.read()
                try:
                    tracker.on_body(json.loads(payload))
                except ValueError:
                    pass
                record["status"] = "ok"
                self._account(record, tracker, model)
                finish()
                handler.send_bytes(code, payload, headers)
        finally:
            connection.close()

    def _relay_stream(self, handler, response, headers, tracker, record, model, finish) -> None:
        """Relays upstream bytes. The newest chunk is held back so the request is
        settled before the client can see the end of the stream."""
        parser = SSEParser(tracker)
        handler.begin_chunked(200, headers)
        status = "ok"
        client_gone = False
        held = None
        try:
            while True:
                chunk = response.read1(65536)
                if not chunk:
                    break
                parser.feed(chunk)
                if held is not None:
                    try:
                        handler.send_chunk(held)
                    except (BrokenPipeError, ConnectionResetError):
                        held = None
                        client_gone = True
                        break
                held = chunk
        except (OSError, http.client.HTTPException):
            status = "upstream_stream_failed"
        if client_gone:
            status = "client_aborted"
        if tracker.error_type is not None:
            status = f"stream_error_{tracker.error_type}"
        record["status"] = status
        self._account(record, tracker, model)
        if not tracker.delta_seen:
            record["usage_incomplete"] = True
        finish()
        if client_gone:
            return
        try:
            if held is not None:
                handler.send_chunk(held)
            handler.end_chunked()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _account(self, record, tracker, model) -> None:
        self.fill_usage(record, tracker, model)
        if not tracker.seen:
            # A successful response without usage would otherwise be free.
            record["status"] = "usage_missing"
            print("meter: 200 response without usage; halting", file=sys.stderr, flush=True)
            self.ledger.halt()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "olivium-bench-meter"
    sys_version = ""
    timeout = None

    def log_message(self, *args) -> None:
        return  # headers and paths never reach stdout

    @property
    def app(self) -> App:
        return self.server.app  # type: ignore[attr-defined]

    def do_GET(self) -> None:
        if self.path == "/healthz":
            self.send_json(200, {"ok": True, "mode": self.app.mode})
        else:
            self.send_error_json(404, "not found", no_retry=True)

    def do_POST(self) -> None:
        self.app.handle_post(self)

    def send_json(self, code: int, payload: dict, extra=None) -> None:
        headers = {"content-type": "application/json"}
        if extra:
            headers.update(extra)
        self.send_bytes(code, json.dumps(payload).encode(), headers)

    def send_bytes(self, code: int, payload: bytes, headers: dict) -> None:
        self.send_response(code)
        for name, value in headers.items():
            self.send_header(name, value)
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        self.wfile.flush()

    def send_error_json(self, code: int, message: str, no_retry: bool = False) -> None:
        payload = {"type": "error", "error": {"type": ERROR_TYPES.get(code, "api_error"), "message": message}}
        extra = {"x-should-retry": "false"} if no_retry else None
        self.send_json(code, payload, extra=extra)

    def begin_chunked(self, code: int, headers: dict) -> None:
        self.send_response(code)
        for name, value in headers.items():
            self.send_header(name, value)
        self.send_header("transfer-encoding", "chunked")
        self.end_headers()
        self.wfile.flush()

    def send_chunk(self, data: bytes) -> None:
        self.wfile.write(b"%x\r\n" % len(data) + data + b"\r\n")
        self.wfile.flush()

    def end_chunked(self) -> None:
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, app: App):
        super().__init__(address, Handler)
        self.app = app


def usd_to_nanos(text: str) -> int:
    value = float(text)
    if value < 0:
        raise argparse.ArgumentTypeError("must be non-negative")
    return round(value * 1e9)


def parse_args(argv=None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--mode", required=True, choices=["mock", "live"])
    parser.add_argument("--run-cap-usd", required=True, type=usd_to_nanos)
    parser.add_argument("--total-cap-usd", required=True, type=usd_to_nanos)
    parser.add_argument("--total-reserve-usd", type=usd_to_nanos, default=None,
                        help="held per in-flight request against the total cap (default: 0 in mock, 1.00 in live)")
    parser.add_argument("--prices", default="/app/prices.json")
    parser.add_argument("--log", default="/data/requests.jsonl")
    parser.add_argument("--key-file", default=None, help="live mode only")
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--cap-status", type=int, default=DEFAULT_CAP_STATUS, choices=sorted(ERROR_TYPES))
    parser.add_argument("--cap-allow-retry", action="store_true",
                        help="experiments only: omit x-should-retry: false from cap refusals")
    parser.add_argument("--refuse-web-tools", action="store_true",
                        help="refuse (403, no retry) any Messages request offering a web search or fetch server tool")
    parser.add_argument("--capture-dir", default=None,
                        help="mock mode only: write each Messages request body to DIR/<run_id>/req-NNNN.json")
    parser.add_argument("--plan-any-tools", action="store_true",
                        help="mock mode only: a request with any tool list (a subagent) follows a plan in its first user text")
    return parser.parse_args(argv)


def build_app(args: argparse.Namespace) -> App:
    if args.capture_dir and args.mode != "mock":
        raise ValueError("--capture-dir is accepted in mock mode only")
    if args.plan_any_tools and args.mode != "mock":
        raise ValueError("--plan-any-tools is accepted in mock mode only")
    prices = Prices.load(args.prices)
    if args.mode == "mock" and args.key_file:
        raise ValueError("--key-file is not accepted in mock mode")
    reserve = args.total_reserve_usd
    if reserve is None:
        reserve = 0 if args.mode == "mock" else 1_000_000_000
    key = load_key(args.key_file) if args.mode == "live" else None
    ledger = Ledger(args.log, args.run_cap_usd, args.total_cap_usd, reserve)
    return App(mode=args.mode, prices=prices, ledger=ledger, cap_status=args.cap_status, key=key,
               cap_allow_retry=args.cap_allow_retry, refuse_web_tools=args.refuse_web_tools,
               capture_dir=args.capture_dir or None, plan_any_tools=args.plan_any_tools)


def main(argv=None) -> int:
    args = parse_args(argv)
    try:
        app = build_app(args)
    except (OSError, ValueError, KeyError) as exc:
        print(f"meter: refusing to start: {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
        return 2
    server = Server((args.bind, args.port), app)
    stop = threading.Event()

    def _stop(*_):
        stop.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    print(f"meter: listening mode={app.mode} port={args.port}", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
