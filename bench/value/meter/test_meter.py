#!/usr/bin/env python3
"""Unit tests for the meter. Standard library only: python3 -I test_meter.py

The mock server tests bind 127.0.0.1 only. The forwarding tests call the
forwarding functions directly with in-memory fakes; they never start a server
in live mode, never open a network connection and use no real key.
"""
import http.client
import json
import os
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import meter  # noqa: E402

PRICES = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "prices.json"), encoding="utf-8"))
NANOS = 1_000_000_000


def tracker_for(**values):
    tracker = meter.UsageTracker()
    tracker.apply(values)
    return tracker


class PriceTests(unittest.TestCase):
    def setUp(self):
        self.prices = meter.Prices(PRICES)

    def test_sonnet_rates_match_official_table(self):
        self.assertEqual(self.prices.rates["claude-sonnet-5-5"]["input"], 2000)
        self.assertEqual(self.prices.rates["claude-sonnet-5-5"]["output"], 10000)
        self.assertEqual(self.prices.rates["claude-sonnet-5-5"]["cache_write_5m"], 2500)
        self.assertEqual(self.prices.rates["claude-sonnet-5-5"]["cache_write_1h"], 4000)
        self.assertEqual(self.prices.rates["claude-sonnet-5-5"]["cache_read"], 100)

    def test_cost_with_split_cache_write(self):
        tracker = tracker_for(input_tokens=1000, output_tokens=50, cache_creation_input_tokens=200,
                              cache_read_input_tokens=300,
                              cache_creation={"ephemeral_5m_input_tokens": 150, "ephemeral_1h_input_tokens": 50})
        self.assertEqual(self.prices.cost_nanos("claude-sonnet-5-5", tracker),
                         1000 * 2000 + 50 * 10000 + 150 * 2500 + 50 * 4000 + 300 * 100)

    def test_cost_without_split_uses_5m_rate(self):
        tracker = tracker_for(input_tokens=0, output_tokens=0, cache_creation_input_tokens=100)
        self.assertEqual(self.prices.cost_nanos("claude-sonnet-5-5", tracker), 100 * 2500)

    def test_haiku_tier_above_threshold(self):
        small = tracker_for(input_tokens=100_000, output_tokens=10)
        large = tracker_for(input_tokens=100_001, output_tokens=10)
        self.assertEqual(self.prices.cost_nanos("claude-haiku-5-5", small), 100_000 * 100 + 10 * 500)
        self.assertEqual(self.prices.cost_nanos("claude-haiku-5-5", large), 100_001 * 500 + 10 * 2500)

    def test_haiku_tier_counts_cache_tokens(self):
        tracker = tracker_for(input_tokens=1000, output_tokens=0, cache_read_input_tokens=100_000)
        self.assertEqual(self.prices.cost_nanos("claude-haiku-5-5", tracker), 1000 * 500 + 100_000 * 50)

    def test_unknown_model_raises(self):
        self.assertFalse(self.prices.known("claude-unknown"))
        with self.assertRaises(meter.UnknownModel):
            self.prices.cost_nanos("claude-unknown", tracker_for(input_tokens=1))

    def test_unverified_price_refused(self):
        bad = json.loads(json.dumps(PRICES))
        bad["models"]["claude-sonnet-5-5"]["unverified"] = True
        with self.assertRaises(ValueError):
            meter.Prices(bad)

    def test_only_two_models_priced(self):
        self.assertEqual(sorted(PRICES["models"]), ["claude-haiku-5-5", "claude-sonnet-5-5"])


class DatedResponseModelTests(unittest.TestCase):
    def fill(self, request_model, response_model):
        app = meter.App(mode="mock", prices=meter.Prices(PRICES), ledger=None)
        tracker = tracker_for(input_tokens=1000, output_tokens=100)
        tracker.model = response_model
        record = {"status": ""}
        app.fill_usage(record, tracker, request_model)
        return record

    def test_dated_snapshot_uses_requested_model_price(self):
        record = self.fill("claude-haiku-5-5", "claude-haiku-5-5-20261001")
        self.assertEqual(record["price_model"], "claude-haiku-5-5")
        self.assertEqual(record["cost_nanousd"], 1000 * 100 + 100 * 500)

    def test_genuinely_different_model_still_uses_most_expensive(self):
        record = self.fill("claude-haiku-5-5", "claude-other-9-9")
        self.assertEqual(record["price_model"], "fallback_most_expensive")


class SSETests(unittest.TestCase):
    STREAM = (
        b'event: message_start\ndata: {"type":"message_start","message":{"model":"claude-sonnet-5-5",'
        b'"usage":{"input_tokens":11,"output_tokens":1,"cache_creation_input_tokens":3,"cache_read_input_tokens":4}}}\n\n'
        b'event: ping\ndata: {"type":"ping"}\n\n'
        b'event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}\n\n'
        b'event: message_delta\ndata: {"type":"message_delta","delta":{},"usage":{"output_tokens":99,"input_tokens":12}}\n\n'
        b'event: message_stop\ndata: {"type":"message_stop"}\n\n'
    )

    def check(self, tracker):
        self.assertEqual(tracker.values["input_tokens"], 12)
        self.assertEqual(tracker.values["output_tokens"], 99)
        self.assertEqual(tracker.values["cache_creation_input_tokens"], 3)
        self.assertEqual(tracker.values["cache_read_input_tokens"], 4)
        self.assertEqual(tracker.model, "claude-sonnet-5-5")
        self.assertEqual(tracker.stop_reason, "end_turn")
        self.assertTrue(tracker.delta_seen)

    def test_whole_stream(self):
        tracker = meter.UsageTracker()
        meter.SSEParser(tracker).feed(self.STREAM)
        self.check(tracker)

    def test_every_chunk_boundary(self):
        for cut in range(1, len(self.STREAM)):
            tracker = meter.UsageTracker()
            parser = meter.SSEParser(tracker)
            parser.feed(self.STREAM[:cut])
            parser.feed(self.STREAM[cut:])
            self.check(tracker)

    def test_one_byte_at_a_time(self):
        tracker = meter.UsageTracker()
        parser = meter.SSEParser(tracker)
        for index in range(len(self.STREAM)):
            parser.feed(self.STREAM[index:index + 1])
        self.check(tracker)

    def test_crlf(self):
        tracker = meter.UsageTracker()
        meter.SSEParser(tracker).feed(self.STREAM.replace(b"\n", b"\r\n"))
        self.check(tracker)

    def test_error_event_recorded(self):
        tracker = meter.UsageTracker()
        meter.SSEParser(tracker).feed(b'event: error\ndata: {"type":"error","error":{"type":"overloaded_error"}}\n\n')
        self.assertEqual(tracker.error_type, "overloaded_error")


class LedgerTests(unittest.TestCase):
    def ledger(self, run_cap=1000, total_cap=5000, reserve=0, path=None):
        directory = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(directory, True))
        return meter.Ledger(path or os.path.join(directory, "requests.jsonl"), run_cap, total_cap, reserve), directory

    def record(self, run_id, cost):
        return {"run_id": run_id, "cost_nanousd": cost, "status": "ok"}

    def test_run_cap_stops_only_that_run(self):
        ledger, _ = self.ledger(run_cap=100)
        self.assertEqual(ledger.admit("a")[0], None)
        ledger.settle(self.record("a", 100), admitted=True)
        self.assertEqual(ledger.admit("a")[0], "cap_run")
        self.assertEqual(ledger.admit("b")[0], None)

    def test_total_cap(self):
        ledger, _ = self.ledger(run_cap=10_000, total_cap=150)
        ledger.admit("a")
        ledger.settle(self.record("a", 150), admitted=True)
        self.assertEqual(ledger.admit("b")[0], "cap_total")

    def test_total_reserve_counts_in_flight(self):
        ledger, _ = self.ledger(run_cap=10_000, total_cap=100, reserve=60)
        self.assertEqual(ledger.admit("a")[0], None)
        # A second concurrent request would hold 120 > 100.
        self.assertEqual(ledger.admit("b")[0], "cap_total")
        ledger.settle(self.record("a", 0), admitted=True)
        self.assertEqual(ledger.admit("b")[0], None)

    def test_replay_after_restart(self):
        directory = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(directory, True))
        path = os.path.join(directory, "requests.jsonl")
        first = meter.Ledger(path, 100, 1000, 0)
        first.admit("a")
        first.settle(self.record("a", 100), admitted=True)
        second = meter.Ledger(path, 100, 1000, 0)
        self.assertEqual(second.admit("a")[0], "cap_run")
        self.assertEqual(second.total_spent, 100)

    def test_corrupt_log_refuses_start(self):
        directory = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(directory, True))
        path = os.path.join(directory, "requests.jsonl")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("not json\n")
        with self.assertRaises(ValueError):
            meter.Ledger(path, 100, 1000, 0)

    def test_unwritable_log_is_sticky(self):
        ledger, directory = self.ledger()
        path = ledger.log_path
        os.chmod(path, 0o444)
        self.addCleanup(lambda: os.path.exists(path) and os.chmod(path, 0o644))
        self.assertEqual(ledger.admit("a")[0], "log_error")
        os.chmod(path, 0o644)
        self.assertEqual(ledger.admit("a")[0], "log_error")


class MockServerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(self.directory, True))
        self.log = os.path.join(self.directory, "requests.jsonl")

        def no_network():
            raise AssertionError("mock mode must not create an upstream connection")

        ledger = meter.Ledger(self.log, 2 * NANOS, 3 * NANOS, 0)
        self.app = meter.App(mode="mock", prices=meter.Prices(PRICES), ledger=ledger, connection_factory=no_network)
        self.server = meter.Server(("127.0.0.1", 0), self.app)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def request(self, path, payload):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=10)
        connection.request("POST", path, body=json.dumps(payload), headers={"content-type": "application/json"})
        response = connection.getresponse()
        body = response.read()
        connection.close()
        return response.status, response.getheader("x-should-retry"), body

    def rows(self):
        with open(self.log, encoding="utf-8") as handle:
            return [json.loads(line) for line in handle]

    def test_stream_usage_and_turn_order(self):
        tools = [{"name": "Read"}, {"name": "Edit"}]
        status, _, body = self.request("/run/r1/v1/messages?beta=true", {
            "model": "claude-sonnet-5-5", "stream": True, "tools": tools,
            "messages": [{"role": "user", "content": "go OLIVIUM_MOCK_TARGET=/x/y.txt"}]})
        self.assertEqual(status, 200)
        text = body.decode()
        self.assertIn('"name":"Read"', text)
        self.assertIn("message_stop", text)
        row = self.rows()[0]
        self.assertEqual((row["input_tokens"], row["output_tokens"]), (1000, 50))
        self.assertEqual(row["cost_nanousd"], 3_075_000)
        self.assertEqual(row["run_id"], "r1")

    def test_edit_turn_built_from_read_result(self):
        tools = [{"name": "Read"}, {"name": "Edit"}]
        messages = [
            {"role": "user", "content": "go OLIVIUM_MOCK_TARGET=/x/y.txt"},
            {"role": "assistant", "content": [{"type": "tool_use", "id": "t1", "name": "Read", "input": {}}]},
            {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1",
                                          "content": "1\talpha\n2\tbeta\n3\talpha"}]},
        ]
        _, _, body = self.request("/run/r2/v1/messages", {"model": "claude-sonnet-5-5", "stream": False,
                                                          "tools": tools, "messages": messages})
        tool = [b for b in json.loads(body)["content"] if b["type"] == "tool_use"][0]
        self.assertEqual(tool["name"], "Edit")
        self.assertEqual(tool["input"]["old_string"], "beta")

    def test_background_and_count_tokens(self):
        status, _, body = self.request("/run/r3/v1/messages", {"model": "claude-haiku-5-5", "max_tokens": 1,
                                                               "messages": [{"role": "user", "content": "hi"}]})
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["usage"]["input_tokens"], 10)
        status, _, body = self.request("/run/r3/v1/messages/count_tokens", {"model": "claude-haiku-5-5"})
        self.assertEqual(json.loads(body)["input_tokens"], 42)
        rows = self.rows()
        self.assertEqual(rows[1]["endpoint"], "count_tokens")
        self.assertEqual(rows[1]["cost_nanousd"], 0)

    def test_next_request_always_sees_previous_cost(self):
        """The client's next request must be judged against the previous response."""
        self.app.ledger.run_cap = 3 * 3_075_000
        tools = [{"name": "Read"}, {"name": "Edit"}]
        payload = {"model": "claude-sonnet-5-5", "stream": True, "tools": tools,
                   "messages": [{"role": "user", "content": "x"}]}
        for attempt in range(40):
            codes = [self.request(f"/run/stress{attempt}/v1/messages", payload)[0] for _ in range(4)]
            self.assertEqual(codes, [200, 200, 200, 402], f"attempt {attempt}")

    def test_refusals(self):
        self.assertEqual(self.request("/v1/messages", {"model": "claude-sonnet-5-5"})[0], 404)
        self.assertEqual(self.request("/run/r/v1/complete", {"model": "claude-sonnet-5-5"})[0], 404)
        self.assertEqual(self.request("/run/../v1/messages", {"model": "claude-sonnet-5-5"})[0], 404)
        status, retry, body = self.request("/run/r/v1/messages", {"model": "nope"})
        self.assertEqual((status, retry), (400, "false"))
        self.assertIn(b"price table", body)

    def test_cap_refusal_is_402_and_no_retry(self):
        ledger = self.app.ledger
        ledger.run_cap = 1
        tools = [{"name": "Read"}, {"name": "Edit"}]
        payload = {"model": "claude-sonnet-5-5", "tools": tools, "messages": [{"role": "user", "content": "x"}]}
        self.assertEqual(self.request("/run/c/v1/messages", payload)[0], 200)
        status, retry, body = self.request("/run/c/v1/messages", payload)
        self.assertEqual((status, retry), (402, "false"))
        self.assertIn(b"cap_run", body)
        self.assertEqual(json.loads(body)["error"]["type"], "billing_error")
        self.assertEqual(self.rows()[-1]["status"], "cap_run")


WEB_SEARCH_TOOL = {"type": "web_search_20250305", "name": "web_search", "max_uses": 8}


class WebToolGuardTests(MockServerTests):
    """Protocol v2: a request offering a web server tool is refused, fail-closed, before any upstream call."""

    def setUp(self):
        super().setUp()
        self.app.refuse_web_tools = True

    def test_web_search_request_refused_without_retry(self):
        payload = {"model": "claude-sonnet-5-5", "max_tokens": 64, "tools": [WEB_SEARCH_TOOL],
                   "messages": [{"role": "user", "content": "search"}]}
        status, retry, body = self.request("/run/w1/v1/messages", payload)
        self.assertEqual((status, retry), (403, "false"))
        self.assertIn(b"web tools", body)
        row = self.rows()[-1]
        self.assertEqual((row["status"], row["http_status"], row["cost_nanousd"]), ("refused_web_tool", 403, 0))
        self.assertEqual(row["web_tools"], ["web_search", "web_search_20250305"])

    def test_web_fetch_by_name_refused_and_plain_tools_pass(self):
        fetch = {"model": "claude-sonnet-5-5", "tools": [{"type": "web_fetch_20250910", "name": "web_fetch"}],
                 "messages": [{"role": "user", "content": "x"}]}
        self.assertEqual(self.request("/run/w2/v1/messages", fetch)[0], 403)
        plain = {"model": "claude-sonnet-5-5", "tools": [{"name": "Read"}, {"name": "Edit"}, {"name": "WebSearch"}],
                 "messages": [{"role": "user", "content": "x"}]}
        self.assertEqual(self.request("/run/w2/v1/messages", plain)[0], 200)
        self.assertNotIn("server_tools", self.rows()[-1])

    def test_count_tokens_is_not_refused(self):
        payload = {"model": "claude-sonnet-5-5", "tools": [WEB_SEARCH_TOOL], "messages": []}
        self.assertEqual(self.request("/run/w3/v1/messages/count_tokens", payload)[0], 200)
        self.assertEqual(self.rows()[-1]["server_tools"], ["web_search_20250305"])

    def test_off_by_default_but_logged(self):
        self.app.refuse_web_tools = False
        payload = {"model": "claude-sonnet-5-5", "tools": [WEB_SEARCH_TOOL],
                   "messages": [{"role": "user", "content": "x"}]}
        self.assertEqual(self.request("/run/w4/v1/messages", payload)[0], 200)
        row = self.rows()[-1]
        self.assertEqual((row["status"], row["server_tools"], row["web_tools"]),
                         ("ok", ["web_search_20250305"], ["web_search", "web_search_20250305"]))

    def test_live_mode_refuses_before_any_upstream_connection(self):
        def no_upstream():
            raise AssertionError("a refused web request must never reach the upstream")

        ledger = meter.Ledger(os.path.join(self.directory, "live.jsonl"), NANOS, NANOS, 0)
        app = meter.App(mode="live", prices=meter.Prices(PRICES), ledger=ledger,
                        key=meter.SecretKey("sk-fake-unit-test-value"), connection_factory=no_upstream,
                        refuse_web_tools=True)
        raw = json.dumps({"model": "claude-sonnet-5-5", "tools": [WEB_SEARCH_TOOL],
                          "messages": [{"role": "user", "content": "x"}]}).encode()
        handler = FakeHandler({"content-length": str(len(raw))})
        handler.path = "/run/w5/v1/messages"
        handler.rfile = __import__("io").BytesIO(raw)
        app.handle_post(handler)
        self.assertEqual(handler.sent[0], 403)
        with open(os.path.join(self.directory, "live.jsonl"), encoding="utf-8") as handle:
            self.assertEqual(json.loads(handle.readline())["status"], "refused_web_tool")

    def test_parse_args_flag(self):
        args = meter.parse_args(["--mode", "mock", "--run-cap-usd", "1", "--total-cap-usd", "2", "--refuse-web-tools"])
        self.assertTrue(args.refuse_web_tools)
        self.assertFalse(meter.parse_args(["--mode", "mock", "--run-cap-usd", "1", "--total-cap-usd", "2"]).refuse_web_tools)


class RequestShapeTests(MockServerTests):
    """Sizes in the log (never content); full bodies only in mock mode with --capture-dir."""

    BODY = {"model": "claude-sonnet-5-5", "stream": False,
            "system": [{"type": "text", "text": "abc"}, {"type": "text", "text": "defgh"}],
            "tools": [{"name": "Read"}, {"name": "Edit"}],
            "messages": [{"role": "user", "content": [{"type": "text", "text": "SECRET-PROMPT-TEXT"}]},
                         {"role": "user", "content": "hook said hello"}]}

    def test_shape_is_sizes_only(self):
        self.assertEqual(self.request("/run/s1/v1/messages", self.BODY)[0], 200)
        row = self.rows()[0]
        tools_chars = len(json.dumps({"name": "Read"})) + len(json.dumps({"name": "Edit"}))
        self.assertEqual(row["shape"], {"system_chars": 8, "tools": 2, "tools_chars": tools_chars, "messages": 2,
                                        "messages_chars": 18 + 15, "first_user_chars": 18,
                                        "total_chars": 8 + tools_chars + 33})
        with open(self.log, encoding="utf-8") as handle:
            self.assertNotIn("SECRET-PROMPT-TEXT", handle.read())
        self.assertFalse(row["captured"])

    def test_capture_writes_body_per_request(self):
        self.app.capture_dir = os.path.join(self.directory, "capture")
        self.request("/run/s2/v1/messages", self.BODY)
        self.request("/run/s2/v1/messages/count_tokens", {"model": "claude-sonnet-5-5"})
        self.request("/run/s2/v1/messages", self.BODY)
        names = sorted(os.listdir(os.path.join(self.app.capture_dir, "s2")))
        self.assertEqual(names, ["req-0001.json", "req-0003.json"])
        with open(os.path.join(self.app.capture_dir, "s2", "req-0001.json"), encoding="utf-8") as handle:
            saved = json.load(handle)
        self.assertEqual((saved["run_id"], saved["seq"], saved["body"]), ("s2", 1, self.BODY))
        self.assertTrue(self.rows()[0]["captured"])

    def test_capture_refused_in_live_mode(self):
        ledger = meter.Ledger(os.path.join(self.directory, "live.jsonl"), NANOS, NANOS, 0)
        with self.assertRaises(ValueError):
            meter.App(mode="live", prices=meter.Prices(PRICES), ledger=ledger,
                      key=meter.SecretKey("sk-fake-unit-test-value"), capture_dir=self.directory)
        args = meter.parse_args(["--mode", "live", "--run-cap-usd", "1", "--total-cap-usd", "2",
                                 "--capture-dir", self.directory, "--key-file", "/nonexistent"])
        with self.assertRaises(ValueError):
            meter.build_app(args)


class PlanAnyToolsTests(unittest.TestCase):
    """--plan-any-tools: a subagent request (restricted tools, a plan nested in its prompt) follows the plan."""

    @staticmethod
    def plan(steps, final="done"):
        import base64
        return "OLIVIUM_MOCK_PLAN_B64=" + base64.b64encode(json.dumps({"steps": steps, "final_text": final}).encode()).decode()

    def body(self, tools, text, messages=()):
        return {"tools": [{"name": n} for n in tools], "messages": [{"role": "user", "content": text}, *messages]}

    def test_subagent_tools_follow_the_plan_only_with_the_flag(self):
        body = self.body(["Read", "Grep", "Glob"], "Find it. " + self.plan([{"name": "Grep", "input": {"pattern": "x"}}]))
        self.assertEqual(meter.mock_turn(body)["kind"], "background")
        turn = meter.mock_turn(body, plan_any_tools=True)
        self.assertEqual((turn["kind"], turn["tool"]), ("main", ("Grep", {"pattern": "x"})))
        after = self.body(["Read", "Grep", "Glob"], body["messages"][0]["content"], [
            {"role": "assistant", "content": [{"type": "tool_use", "id": "t1", "name": "Grep", "input": {}}]},
            {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "a.py:1"}]}])
        final = meter.mock_turn(after, plan_any_tools=True)
        self.assertEqual((final["tool"], final["text"]), (None, "done"))

    def test_no_plan_or_no_tools_stays_background(self):
        self.assertEqual(meter.mock_turn(self.body(["Read", "Grep"], "no plan here"), plan_any_tools=True)["kind"], "background")
        self.assertEqual(meter.mock_turn(self.body([], "x " + self.plan([])), plan_any_tools=True)["kind"], "background")

    def test_main_session_unchanged(self):
        body = self.body(["Read", "Edit", "Bash"], self.plan([{"name": "Bash", "input": {"command": "ls"}}]))
        self.assertEqual(meter.mock_turn(body), meter.mock_turn(body, plan_any_tools=True))

    def test_refused_in_live_mode(self):
        directory = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(directory, True))
        ledger = meter.Ledger(os.path.join(directory, "live.jsonl"), NANOS, NANOS, 0)
        with self.assertRaises(ValueError):
            meter.App(mode="live", prices=meter.Prices(PRICES), ledger=ledger,
                      key=meter.SecretKey("sk-fake-unit-test-value"), plan_any_tools=True)
        args = meter.parse_args(["--mode", "live", "--run-cap-usd", "1", "--total-cap-usd", "2",
                                 "--plan-any-tools", "--key-file", "/nonexistent"])
        with self.assertRaises(ValueError):
            meter.build_app(args)
        args = meter.parse_args(["--mode", "mock", "--run-cap-usd", "1", "--total-cap-usd", "2", "--plan-any-tools",
                                 "--log", os.path.join(directory, "mock.jsonl"),
                                 "--prices", os.path.join(os.path.dirname(os.path.abspath(__file__)), "prices.json")])
        self.assertTrue(meter.build_app(args).plan_any_tools)


class FakeResponse:
    def __init__(self, status, headers, chunks=(), body=b""):
        self.status = status
        self._headers = headers
        self._chunks = list(chunks)
        self._body = body

    def getheader(self, name):
        return dict((k.lower(), v) for k, v in self._headers).get(name.lower())

    def getheaders(self):
        return list(self._headers)

    def read1(self, _size):
        return self._chunks.pop(0) if self._chunks else b""

    def read(self):
        return self._body


class FakeConnection:
    def __init__(self, response):
        self.response = response
        self.sent = None
        self.closed = False

    def request(self, method, target, body=None, headers=None):
        self.sent = {"method": method, "target": target, "body": body, "headers": dict(headers)}

    def getresponse(self):
        return self.response

    def close(self):
        self.closed = True


class FakeHandler:
    """Implements only the response surface used by App._serve_live."""

    def __init__(self, headers):
        self.headers = headers
        self.chunks = []
        self.begun = None
        self.ended = False
        self.sent = None
        self.finished_before_end = None

    def begin_chunked(self, code, headers):
        self.begun = (code, headers)

    def send_chunk(self, data):
        self.chunks.append(data)

    def end_chunked(self):
        self.ended = True

    def send_bytes(self, code, payload, headers):
        self.sent = (code, payload, headers)

    def send_error_json(self, code, message, no_retry=False):
        self.sent = (code, message.encode(), {})


class ForwardingTests(unittest.TestCase):
    """Direct calls with in-memory fakes. No live-mode server is ever started."""

    FAKE_KEY = "sk-fake-unit-test-value"

    def setUp(self):
        self.finish_calls = 0

    def finish(self):
        self.finish_calls += 1

    def build(self, response):
        directory = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(directory, True))
        ledger = meter.Ledger(os.path.join(directory, "requests.jsonl"), 5 * NANOS, 50 * NANOS, 0)
        connection = FakeConnection(response)
        app = meter.App(mode="live", prices=meter.Prices(PRICES), ledger=ledger, key=meter.SecretKey(self.FAKE_KEY),
                        connection_factory=lambda: connection)
        record = app.base_record("r1", 1, "messages", "claude-sonnet-5-5", True, 64000)
        return app, connection, record

    INCOMING = {"X-Api-Key": "dummy-from-agent", "Authorization": "Bearer dummy", "Anthropic-Version": "2023-06-01",
                "Anthropic-Beta": "foo", "User-Agent": "claude-cli", "X-Stainless-Os": "Linux", "Cookie": "c=1",
                "Content-Type": "application/json", "Host": "meter:8080"}

    def test_key_injected_and_dummy_dropped(self):
        stream = (b'event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":5,"output_tokens":1}}}\n\n'
                  b'event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":9}}\n\n')
        app, connection, record = self.build(FakeResponse(
            200, [("content-type", "text/event-stream"), ("set-cookie", "x=1"), ("request-id", "req_1")],
            chunks=[stream[:30], stream[30:]]))
        handler = FakeHandler(self.INCOMING)
        app._serve_live(handler, record, b"{}", "/v1/messages?beta=true", "claude-sonnet-5-5", "messages", self.finish)
        sent = connection.sent["headers"]
        self.assertEqual(connection.sent["target"], "/v1/messages?beta=true")
        self.assertEqual(sent["x-api-key"], self.FAKE_KEY)
        self.assertNotIn("authorization", sent)
        self.assertNotIn("cookie", sent)
        self.assertNotIn("host", sent)
        self.assertEqual(sent["accept-encoding"], "identity")
        self.assertEqual(sent["anthropic-beta"], "foo")
        self.assertEqual(b"".join(handler.chunks), stream)
        self.assertTrue(handler.ended)
        self.assertNotIn("set-cookie", handler.begun[1])
        self.assertEqual((record["input_tokens"], record["output_tokens"], record["status"]), (5, 9, "ok"))
        self.assertTrue(connection.closed)
        self.assertEqual(self.finish_calls, 1)

    def test_settled_before_last_chunk_reaches_client(self):
        order = []
        stream = [b'event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":5,"output_tokens":1}}}\n\n',
                  b'event: message_delta\ndata: {"type":"message_delta","delta":{},"usage":{"output_tokens":9}}\n\n',
                  b'event: message_stop\ndata: {"type":"message_stop"}\n\n']
        app, _, record = self.build(FakeResponse(200, [("content-type", "text/event-stream")], chunks=list(stream)))
        handler = FakeHandler(self.INCOMING)
        handler.send_chunk = lambda data: order.append(("chunk", data))
        handler.end_chunked = lambda: order.append(("end", None))
        app._serve_live(handler, record, b"{}", "/v1/messages", "claude-sonnet-5-5", "messages",
                        lambda: order.append(("finish", record["output_tokens"], record["status"])))
        self.assertEqual([item[0] for item in order], ["chunk", "chunk", "finish", "chunk", "end"])
        self.assertEqual(order[2], ("finish", 9, "ok"))
        self.assertEqual(order[3], ("chunk", stream[2]))

    def test_key_never_appears_in_record_or_repr(self):
        app, _, record = self.build(FakeResponse(200, [("content-type", "text/event-stream")], chunks=[]))
        self.assertNotIn(self.FAKE_KEY, json.dumps(record))
        self.assertNotIn(self.FAKE_KEY, repr(app.key))
        self.assertNotIn(self.FAKE_KEY, str(app.key))

    def test_upstream_error_passes_through(self):
        app, _, record = self.build(FakeResponse(429, [("content-type", "application/json"), ("retry-after", "3")],
                                                 body=b'{"type":"error"}'))
        handler = FakeHandler(self.INCOMING)
        app._serve_live(handler, record, b"{}", "/v1/messages", "claude-sonnet-5-5", "messages", self.finish)
        self.assertEqual(handler.sent[0], 429)
        self.assertEqual(record["status"], "upstream_429")
        self.assertEqual(record["cost_nanousd"], 0)

    def test_200_without_usage_halts(self):
        app, _, record = self.build(FakeResponse(200, [("content-type", "text/event-stream")], chunks=[b"event: ping\ndata: {}\n\n"]))
        app._serve_live(FakeHandler(self.INCOMING), record, b"{}", "/v1/messages", "claude-sonnet-5-5", "messages", self.finish)
        self.assertEqual(record["status"], "usage_missing")
        self.assertEqual(app.ledger.admit("r1")[0], "halted")

    def test_stream_without_delta_flagged_incomplete(self):
        stream = b'event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":5,"output_tokens":1}}}\n\n'
        app, _, record = self.build(FakeResponse(200, [("content-type", "text/event-stream")], chunks=[stream]))
        app._serve_live(FakeHandler(self.INCOMING), record, b"{}", "/v1/messages", "claude-sonnet-5-5", "messages", self.finish)
        self.assertTrue(record.get("usage_incomplete"))
        self.assertEqual(record["input_tokens"], 5)

    def test_key_file_handling(self):
        with tempfile.NamedTemporaryFile("w", suffix=".key", delete=False) as handle:
            handle.write("  sk-fake-file-value\n")
        self.addCleanup(os.unlink, handle.name)
        key = meter.load_key(handle.name)
        self.assertEqual(key.reveal(), "sk-fake-file-value")
        with tempfile.NamedTemporaryFile("w", suffix=".key", delete=False) as handle:
            handle.write("")
        self.addCleanup(os.unlink, handle.name)
        with self.assertRaises(ValueError):
            meter.load_key(handle.name)


if __name__ == "__main__":
    unittest.main(verbosity=1)
