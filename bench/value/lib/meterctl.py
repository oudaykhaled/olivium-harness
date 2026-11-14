"""Lifecycle of the benchmark networks and the meter for one run or prepare."""

import json
import os
import re
import shutil
import tarfile
import tempfile
import threading
import time

from lib.common import BenchError, read_jsonl, write_json_atomic
from lib import dockerops as dk

METER_IMAGE = "olivium-bench-meter:v1"
METER_LOG = "/data/requests.jsonl"
METER_UID = 1002
METER_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "meter")
METER_CAPTURE = "/data/capture"
CAPTURE_RUN_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
CAPTURE_MAX_REQUESTS = 999


class Meter:
    def __init__(self, out_dir, tag, paid, run_cap_usd, total_cap_usd, key_file=None, refuse_web_tools=False,
                 capture=False, total_reserve_usd=None):
        if capture and paid:
            raise BenchError("request capture is mock mode only")
        self.out_dir = out_dir
        # Mock mode only: the meter keeps each Messages request body for copy_capture().
        self.capture = capture
        # Protocol v2: refuse any request offering a web search or fetch server tool.
        self.refuse_web_tools = refuse_web_tools
        self.tag = tag
        self.paid = paid
        self.run_cap_usd = run_cap_usd
        self.total_cap_usd = total_cap_usd
        self.key_file = key_file
        self.name = "olivium-bench-meter-%s" % tag
        self.internal = "olivium-bench-int-%s" % tag
        self.egress = "olivium-bench-egress-%s" % tag
        self.log_path = os.path.join(out_dir, "meter", "requests.jsonl")
        # The meter holds this much per in-flight request against the total cap. None keeps
        # the meter's own default (1.00 live, 0 mock) and passes nothing to it.
        self.explicit_reserve = total_reserve_usd is not None
        self.total_reserve_usd = float(total_reserve_usd) if self.explicit_reserve else (1.0 if paid else 0.0)
        os.makedirs(os.path.dirname(self.log_path), exist_ok=True)
        self._lock = threading.Lock()
        self._up = False

    def up(self):
        self._build_image()
        self._recover_previous_log()
        dk.remove(self.name)
        dk.network_create(self.internal, internal=True)
        if self.paid:
            dk.network_create(self.egress, internal=False)
        args = [
            "--mode", "live" if self.paid else "mock",
            "--run-cap-usd", _usd(self.run_cap_usd),
            "--total-cap-usd", _usd(self.total_cap_usd),
        ]
        if self.explicit_reserve:
            args += ["--total-reserve-usd", _usd(self.total_reserve_usd)]
        if self.refuse_web_tools:
            args.append("--refuse-web-tools")
        if self.capture:
            args += ["--capture-dir", METER_CAPTURE]
        extra = ["--network-alias", "meter"]
        if self.paid:
            # The one permitted bind mount: the meter's read-only key file.
            extra += ["--volume", "%s:/run/secrets/key:ro" % self.key_file]
            args += ["--key-file", "/run/secrets/key"]
        dk.create(self.name, METER_IMAGE, network=self.internal, memory="256m", pids="128",
                  swap_equals_memory=False, extra=extra, command=args)
        if self.paid:
            dk.docker("network", "connect", self.egress, self.name, timeout=60)
        self._restore_log()
        dk.start(self.name)
        self._wait_healthy()
        self._up = True

    def _build_image(self):
        """Build from the checked-out source, so a stale meter or price table cannot be used.

        Docker's layer cache makes this a no-op when meter.py and prices.json are unchanged.
        """
        done = dk.sh(["docker", "build", "--quiet", "-t", METER_IMAGE, METER_DIR], timeout=900)
        if done.returncode != 0:
            raise BenchError("meter image build failed: %s" % done.stderr.decode("utf-8", "replace")[-600:])
        write_json_atomic(
            os.path.join(self.out_dir, "meter", "image.json"),
            {"meter_image": METER_IMAGE, "meter_image_id": dk.image_id(METER_IMAGE)},
        )

    def _recover_previous_log(self):
        """Keep rows a killed runner never synced; removing the old meter would lose them."""
        if dk.docker("container", "inspect", self.name, check=False, timeout=60).returncode != 0:
            return
        handle = tempfile.NamedTemporaryFile(dir=os.path.dirname(self.log_path), suffix=".tar", delete=False)
        handle.close()
        try:
            try:
                dk.cp_out_file(self.name, METER_LOG, handle.name, timeout=120)
                self._install_log_from_tar(handle.name, only_if_longer=True)
            except (dk.DockerError, tarfile.TarError, StopIteration):
                return  # no log in the old container: nothing to recover
        finally:
            os.unlink(handle.name)

    def _install_log_from_tar(self, tar_path, only_if_longer=False):
        with tarfile.open(tar_path, mode="r") as tar:
            member = next(item for item in tar if item.isfile())
            if only_if_longer and os.path.exists(self.log_path) and member.size < os.path.getsize(self.log_path):
                return
            source = tar.extractfile(member)
            tmp = self.log_path + ".tmp"
            with open(tmp, "wb") as target:
                shutil.copyfileobj(source, target)
        os.replace(tmp, self.log_path)

    def _restore_log(self):
        if not os.path.exists(self.log_path) or os.path.getsize(self.log_path) == 0:
            return
        with open(self.log_path, "rb") as handle:
            data = handle.read()
        dk.cp_in(
            self.name, "/data",
            dk.make_tar([("requests.jsonl", data, 0o640)], uid=METER_UID, gid=METER_UID),
            archive=True,
        )

    def _wait_healthy(self):
        code = (
            "import urllib.request as u; "
            "u.urlopen('http://127.0.0.1:8080/healthz', timeout=2)"
        )
        deadline = time.time() + 60
        while time.time() < deadline:
            done = dk.docker("exec", self.name, "python3", "-I", "-c", code, check=False, timeout=30)
            if done.returncode == 0:
                return
            time.sleep(1)
        raise BenchError("meter did not become healthy")

    def sync_log(self):
        """Copy the current request log to OUT/meter/requests.jsonl (atomic)."""
        with self._lock:
            if not self._up:
                return
            handle = tempfile.NamedTemporaryFile(
                dir=os.path.dirname(self.log_path), suffix=".tar", delete=False
            )
            handle.close()
            try:
                dk.cp_out_file(self.name, METER_LOG, handle.name, timeout=120)
                self._install_log_from_tar(handle.name)
            finally:
                os.unlink(handle.name)

    def copy_capture(self, run_id, dest_dir):
        """Copy the captured request bodies of one run to dest_dir/req-NNNN.json (mock only).

        Returns the sorted file names written; an empty list when the run sent nothing.
        """
        if not self.capture or self.paid:
            raise BenchError("request capture is not enabled")
        if not CAPTURE_RUN_RE.match(run_id or ""):
            raise BenchError("invalid run id for capture")
        os.makedirs(dest_dir, exist_ok=True)
        handle = tempfile.NamedTemporaryFile(dir=dest_dir, suffix=".tar", delete=False)
        handle.close()
        try:
            try:
                dk.cp_out_file(self.name, "%s/%s" % (METER_CAPTURE, run_id), handle.name, timeout=300)
            except dk.DockerError:
                return []
            allowed = {"req-%04d.json" % n: "req-%04d.json" % n for n in range(1, CAPTURE_MAX_REQUESTS + 1)}
            return sorted(dk.extract_members(handle.name, allowed, dest_dir, max_member_bytes=64 * (1 << 20)))
        finally:
            os.unlink(handle.name)

    def running(self):
        """False once the meter container has stopped, for example after a crash."""
        done = dk.docker("inspect", "--format", "{{.State.Running}}", self.name, check=False, timeout=60)
        return done.returncode == 0 and done.stdout.decode("ascii", "replace").strip() == "true"

    def rows_for(self, run_id):
        self.sync_log()
        return [row for row in read_jsonl(self.log_path) if row.get("run_id") == run_id]

    def total_cost_usd(self):
        return sum((row.get("cost_nanousd") or 0) for row in read_jsonl(self.log_path)) / 1e9

    def total_cap_reached(self):
        """True when the meter would refuse the next request against the total cap."""
        self.sync_log()
        return self.total_cost_usd() + self.total_reserve_usd >= self.total_cap_usd

    def hit_total_cap(self, run_id):
        return any(row.get("status") == "cap_total" for row in self.rows_for(run_id))

    def down(self):
        if self._up:
            try:
                self.sync_log()
            except BenchError:
                pass
        self._up = False
        dk.remove(self.name)
        dk.network_remove(self.internal)
        if self.paid:
            dk.network_remove(self.egress)


def usage_summary(rows):
    """Token, cost and request totals from meter rows for one run."""
    summed = {"input": 0, "output": 0, "cache_creation": 0, "cache_read": 0}
    cost_nanos = 0
    requests = 0
    for row in rows:
        if row.get("endpoint") != "messages":
            continue
        requests += 1
        summed["input"] += int(row.get("input_tokens") or 0)
        summed["output"] += int(row.get("output_tokens") or 0)
        summed["cache_creation"] += int(row.get("cache_creation_input_tokens") or 0)
        summed["cache_read"] += int(row.get("cache_read_input_tokens") or 0)
        cost_nanos += int(row.get("cost_nanousd") or 0)
    return {"tokens": summed, "cost_usd": round(cost_nanos / 1e9, 9), "requests": requests}


def _usd(value):
    return ("%.6f" % float(value)).rstrip("0").rstrip(".")


def dump_rows(path, rows):
    with open(path, "w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, sort_keys=True) + "\n")


__all__ = ["Meter", "usage_summary", "dump_rows", "METER_IMAGE", "write_json_atomic"]
