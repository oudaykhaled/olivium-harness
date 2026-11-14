#!/usr/bin/env python3
"""Proves the isolation, mock, meter and cap contracts with real runs.

Runs Claude Code in the throwaway agent image against the mock meter only.
Never starts the meter in live mode, never contacts a model API and never
needs a key. Standard library only. Usage:

  python3 bench/value/docker/prove.py --out DIR [--build] [--only NAME[,NAME]] [--keep]

Sections: isolation, e2e, plan, cap_experiment, run_cap, total_cap, fail_closed.
Every container, network and image is olivium-bench-* and labelled; containers
and networks are removed on exit, images are kept.
"""
from __future__ import annotations

import argparse
import base64
import io
import json
import os
import subprocess
import sys
import tarfile
import time

DOCKER_DIR = os.path.dirname(os.path.abspath(__file__))
VALUE_DIR = os.path.dirname(DOCKER_DIR)
SUFFIX = "prove"
NET_INT = f"olivium-bench-int-{SUFFIX}"
NET_EGRESS = f"olivium-bench-egress-{SUFFIX}"
NET_PLAIN = f"olivium-bench-int-plain-{SUFFIX}"
AGENT_IMAGE = "olivium-bench-agent-probe:v1"
METER_IMAGE = "olivium-bench-meter:v1"
DEPS_IMAGE = "olivium-bench-deps-probe:v1"
LABEL = "olivium-bench=1"
DUMMY_KEY = "olivium-bench-dummy-key"
METER_NAME = "olivium-bench-prove-meter"
HARDENING = ["--cap-drop=ALL", "--security-opt=no-new-privileges"]
AGENT_LIMITS = ["--memory=1500m", "--cpus=2", "--pids-limit=512"]

# Written by hand, not imported from meter.py: these are the expected values.
MAIN_EXPECTED = [
    {"input_tokens": 1000, "output_tokens": 50, "cache_creation_input_tokens": 200,
     "cache_read_input_tokens": 0, "cost_nanousd": 3_075_000},
    {"input_tokens": 1100, "output_tokens": 60, "cache_creation_input_tokens": 200,
     "cache_read_input_tokens": 300, "cost_nanousd": 3_405_000},
    {"input_tokens": 1200, "output_tokens": 70, "cache_creation_input_tokens": 200,
     "cache_read_input_tokens": 600, "cost_nanousd": 3_735_000},
]
SESSION_TOTAL_NANOS = 10_215_000
MAX_ACCEPTABLE_CAP_SECONDS = 30
CHOSEN_CAP_STATUS = 402


def sh(args, *, check=True, stdin=None, timeout=300, text=True):
    return subprocess.run(args, check=check, input=stdin, capture_output=True, text=text, timeout=timeout)


def docker(*args, **kwargs):
    return sh(["docker", *args], **kwargs)


def quiet(*args):
    subprocess.run(["docker", *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def remove_containers():
    out = docker("ps", "-aq", "--filter", f"label={LABEL}", "--filter", "name=olivium-bench-prove-", check=False).stdout
    for container in out.split():
        quiet("rm", "-f", container)


def remove_networks():
    for name in (NET_INT, NET_EGRESS, NET_PLAIN):
        quiet("network", "rm", name)


def setup_networks():
    remove_networks()
    # Uses net.sh so the networks proven here are the ones the orchestrator gets.
    sh([os.path.join(DOCKER_DIR, "net.sh"), "up", SUFFIX])
    docker("network", "create", "--internal", "--label", LABEL, NET_PLAIN)


def start_meter(run_cap, total_cap, *extra, name=METER_NAME, egress=True, network=NET_INT):
    quiet("rm", "-f", name)
    args = ["create", "--name", name, "--label", LABEL, "--network", network, "--network-alias", "meter",
            *HARDENING, "--memory=256m", "--pids-limit=128", METER_IMAGE,
            "--mode", "mock", "--run-cap-usd", str(run_cap), "--total-cap-usd", str(total_cap), *extra]
    docker(*args)
    if egress:
        docker("network", "connect", NET_EGRESS, name)
    docker("start", name)
    deadline = time.time() + 20
    while time.time() < deadline:
        if "listening" in docker("logs", name, check=False).stdout:
            return name
        time.sleep(0.2)
    raise RuntimeError(f"meter did not start: {docker('logs', name, check=False).stderr}")


def meter_log(name=METER_NAME):
    raw = docker("cp", f"{name}:/data/requests.jsonl", "-", text=False).stdout
    with tarfile.open(fileobj=io.BytesIO(raw)) as archive:
        content = archive.extractfile("requests.jsonl").read().decode()
    return [json.loads(line) for line in content.splitlines() if line.strip()]


def input_tar(prompt: str, settings=None) -> bytes:
    """Tar stream for `docker cp -a - ctr:/work`, owned by the agent user."""
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as archive:
        for name, data in {"in/prompt.txt": prompt, **({"in/settings.json": settings} if settings else {})}.items():
            blob = data.encode()
            info = tarfile.TarInfo(name)
            info.size, info.uid, info.gid, info.mode = len(blob), 1001, 1001, 0o644
            info.uname = info.gname = "agent"
            archive.addfile(info, io.BytesIO(blob))
    return buffer.getvalue()


def extract_tar(container, path):
    raw = docker("cp", f"{container}:{path}", "-", text=False).stdout
    files = {}
    with tarfile.open(fileobj=io.BytesIO(raw)) as archive:
        for member in archive.getmembers():
            if member.isfile():
                files[member.name] = archive.extractfile(member).read()
    return files


def run_agent(name, run_id, prompt, *, env=(), timeout_s=120, network=NET_INT, keep_files=("sample.txt",)):
    container = f"olivium-bench-prove-agent-{name}"
    quiet("rm", "-f", container)
    args = ["create", "--name", container, "--label", LABEL, "--network", network, *HARDENING, *AGENT_LIMITS,
            "-e", f"ANTHROPIC_BASE_URL=http://meter:8080/run/{run_id}", "-e", f"ANTHROPIC_API_KEY={DUMMY_KEY}",
            "-e", f"BENCH_TIMEOUT_S={timeout_s}", "-e", "BENCH_MAX_TURNS=10"]
    for item in env:
        args += ["-e", item]
    docker(*args, AGENT_IMAGE)
    docker("cp", "-a", "-", f"{container}:/work", stdin=input_tar(prompt), text=False)
    started = time.monotonic()
    timed_out = False
    try:
        docker("start", "-a", container, timeout=timeout_s + 60, check=False)
    except subprocess.TimeoutExpired:
        timed_out = True
    wall = round(time.monotonic() - started, 2)
    out = extract_tar(container, "/work/out")
    repo_files = {}
    for rel in keep_files:
        tree = extract_tar(container, f"/work/repo/{rel}")
        repo_files[rel] = next(iter(tree.values())).decode()
    inspect = json.loads(docker("inspect", container).stdout)[0]
    quiet("rm", "-f", container)
    transcript_raw = out.get("out/transcript.jsonl", b"").decode()
    events = [json.loads(line) for line in transcript_raw.splitlines() if line.strip().startswith("{")]
    exit_code = out.get("out/exit_code", b"").decode().strip()
    result = next((e for e in reversed(events) if e.get("type") == "result"), None)
    return {
        "container": container, "wall_seconds": wall, "timed_out": timed_out,
        "exit_code": int(exit_code) if exit_code.lstrip("-").isdigit() else None,
        "events": events, "result": result,
        "stderr": out.get("out/stderr.log", b"").decode()[:2000],
        "repo_files": repo_files, "inspect": inspect,
        "transcript_bytes": len(transcript_raw),
    }


def tool_uses(events):
    calls = []
    for event in events:
        if event.get("type") != "assistant":
            continue
        for block in event["message"].get("content", []):
            if block.get("type") == "tool_use":
                calls.append({"name": block["name"], "input": block["input"]})
    return calls


def cost(rows):
    return sum(row["cost_nanousd"] for row in rows)


def helper(script, *, network=NET_INT, timeout=60):
    """Runs a short python script in a labelled helper container on the network."""
    return sh(["docker", "run", "--rm", "--name", "olivium-bench-prove-helper", "--label", LABEL, "--network", network,
               *HARDENING, "--memory=128m", "--entrypoint", "python3", AGENT_IMAGE, "-I", "-c", script],
              check=False, timeout=timeout)


def post(path, payload):
    return helper(
        "import json,urllib.request,urllib.error,sys\n"
        f"req=urllib.request.Request('http://meter:8080{path}',data={json.dumps(payload).encode()!r},"
        "headers={'content-type':'application/json'})\n"
        "try:\n r=urllib.request.urlopen(req,timeout=10);print(json.dumps({'status':r.status,'body':r.read().decode()}))\n"
        "except urllib.error.HTTPError as e:\n print(json.dumps({'status':e.code,'headers':{k.lower():v for k,v in e.headers.items()},'body':e.read().decode()}))\n"
    )


class Report:
    def __init__(self, out):
        self.out = out
        self.data = {"generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "sections": {}}

    def section(self, name, **values):
        self.data["sections"].setdefault(name, {}).update(values)
        self.flush()

    def write(self, name, payload):
        with open(os.path.join(self.out, name), "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2)
        return os.path.join(self.out, name)

    def flush(self):
        self.write("proof.json", self.data)


# ----------------------------------------------------------------------------
def section_isolation(report: Report):
    start_meter(5, 50)
    subnet_info = json.loads(docker("network", "inspect", NET_INT).stdout)[0]
    subnet = subnet_info["IPAM"]["Config"][0]["Subnet"]
    prefix = subnet.rsplit(".", 2)[0]
    candidates = f"{prefix}.0.1 {prefix}.0.2 {prefix}.0.254"
    meter_nets = json.loads(docker("inspect", METER_NAME).stdout)[0]["NetworkSettings"]["Networks"]
    agent_flags = ["--label", LABEL, *HARDENING, *AGENT_LIMITS, "-e", "ANTHROPIC_BASE_URL=http://meter:8080/run/probe",
                   "-e", f"ANTHROPIC_API_KEY={DUMMY_KEY}", "--entrypoint", "/usr/local/bin/olivium-probe"]
    probe = sh(["docker", "run", "--rm", "--name", "olivium-bench-prove-probe", "--network", NET_INT, *agent_flags,
                "-e", f"PROBE_GATEWAY_IPS={candidates}", AGENT_IMAGE], check=False, timeout=240)
    probe_json = json.loads(probe.stdout)
    report.write("probe.json", probe_json)

    # Positive control: the same probe on the meter's egress network must see the
    # internet (example.com only; api.anthropic.com is never contacted here).
    control = sh(["docker", "run", "--rm", "--name", "olivium-bench-prove-control", "--network", NET_EGRESS, *agent_flags,
                  "-e", "PROBE_CONTROL=1", AGENT_IMAGE], check=False, timeout=120)
    control_json = json.loads(control.stdout)
    report.write("probe_control_egress.json", control_json)

    # Positive control: an ordinary internal network has a host-side gateway
    # address, and the probe must flag it. The isolated gateway mode removes it.
    plain = json.loads(docker("network", "inspect", NET_PLAIN).stdout)[0]["IPAM"]["Config"][0]
    plain_probe = sh(["docker", "run", "--rm", "--name", "olivium-bench-prove-control2", "--network", NET_PLAIN, *agent_flags,
                      "-e", f"PROBE_GATEWAY_IPS={plain['Gateway']}", AGENT_IMAGE], check=False, timeout=240)
    plain_json = json.loads(plain_probe.stdout)
    report.write("probe_control_plain_internal.json", plain_json)

    probe_agent = docker("run", "--rm", "--name", "olivium-bench-prove-peers", "--label", LABEL, "--network", NET_INT, *HARDENING,
                         "--memory=128m", "--entrypoint", "python3", AGENT_IMAGE, "-I", "-c",
                         "import socket; print(socket.gethostbyname('meter'))", check=False)
    report.section(
        "isolation",
        probe_pass=probe_json["pass"], probe_exit=probe.returncode,
        failed_checks=[k for k, v in probe_json["checks"].items() if not v.get("pass")],
        checks={k: v for k, v in probe_json["checks"].items()},
        internal_network={"internal": subnet_info["Internal"], "options": subnet_info["Options"], "subnet": subnet,
                          "gateway": subnet_info["IPAM"]["Config"][0].get("Gateway", "")},
        meter_networks=sorted(meter_nets), meter_ip_on_internal=probe_agent.stdout.strip(),
        control_egress_detected=control_json.get("control", {}).get("egress_detected"),
        control_plain_gateway={"gateway": plain["Gateway"], "check": plain_json["checks"]["bridge_gateway"],
                               "flagged_reachable": plain_json["checks"]["bridge_gateway"].get("pass") is False},
        control_meter_unreachable_from_plain=plain_json["checks"]["meter_reachable"],
    )
    return probe_json["pass"]


def section_e2e(report: Report):
    start_meter(5, 50)
    run = run_agent("e2e", "e2e-run", "Edit the file. OLIVIUM_MOCK_TARGET=/work/repo/sample.txt\n")
    calls = tool_uses(run["events"])
    rows = meter_log()
    main = [r for r in rows if r.get("mock_kind") == "main"]
    usage_ok = [
        {k: r[k] for k in MAIN_EXPECTED[0]} == expected
        for r, expected in zip(main, MAIN_EXPECTED)
    ]
    report.write("e2e_requests.json", rows)
    report.write("e2e_transcript_events.json", run["events"])
    result = run["result"] or {}
    agent_networks = sorted(run["inspect"]["NetworkSettings"]["Networks"])
    report.section(
        "e2e", exit_code=run["exit_code"], wall_seconds=run["wall_seconds"],
        tool_calls=[c["name"] for c in calls], edit_input=[c["input"] for c in calls if c["name"] == "Edit"],
        file_after=run["repo_files"]["sample.txt"], file_edited="OLIVIUM_MOCK_EDIT" in run["repo_files"]["sample.txt"],
        result_subtype=result.get("subtype"), result_stop_reason=result.get("stop_reason"),
        requests_logged=len(rows), statuses=sorted({r["status"] for r in rows}),
        main_requests=len(main), usage_rows_match_expected=len(main) == 3 and all(usage_ok),
        meter_total_nanousd=cost(rows), expected_total_nanousd=SESSION_TOTAL_NANOS,
        total_matches=cost(rows) == SESSION_TOTAL_NANOS,
        claude_code_total_cost_usd=result.get("total_cost_usd"),
        claude_code_cost_matches_meter=abs(float(result.get("total_cost_usd") or -1) - cost(rows) / 1e9) < 1e-9,
        agent_networks=agent_networks,
        agent_user_uid=run["inspect"]["Config"].get("User"),
        agent_capdrop=run["inspect"]["HostConfig"]["CapDrop"],
        agent_security_opt=run["inspect"]["HostConfig"]["SecurityOpt"],
        agent_mounts=run["inspect"]["Mounts"],
        no_meter_404=not any(r["status"] == "not_found" for r in rows),
    )


def section_plan(report: Report):
    start_meter(5, 50)
    plan = {"steps": [
        {"name": "Read", "input": {"file_path": "/work/repo/sample.txt"}},
        {"name": "Edit", "input": {"file_path": "/work/repo/sample.txt", "old_string": "beta line", "new_string": "beta PLANNED"}},
    ], "final_text": "planned edit finished"}
    encoded = base64.b64encode(json.dumps(plan).encode()).decode()
    run = run_agent("plan", "plan-run", f"Do the planned edit. OLIVIUM_MOCK_PLAN_B64={encoded}\n")
    report.section("plan", tool_calls=[c["name"] for c in tool_uses(run["events"])], exit_code=run["exit_code"],
                   file_after=run["repo_files"]["sample.txt"], planned_edit_applied="beta PLANNED" in run["repo_files"]["sample.txt"])


def cap_stop_run(status, *, header=True, repeat=0):
    extra = ["--cap-status", str(status)] + ([] if header else ["--cap-allow-retry"])
    start_meter(0.002, 50, *extra)
    tag = f"cap{status}-{'h' if header else 'n'}-{repeat}"
    run = run_agent(tag, tag, "Edit it. OLIVIUM_MOCK_TARGET=/work/repo/sample.txt\n", timeout_s=75)
    rows = meter_log()
    refused = [r for r in rows if r["status"] == "cap_run"]
    result = run["result"] or {}
    return {
        "http_status": status, "x_should_retry_false": header, "repeat": repeat,
        "wall_seconds": run["wall_seconds"], "exit_code": run["exit_code"],
        "timed_out_by_runner": run["timed_out"], "requests_total": len(rows), "refused_requests": len(refused),
        "result_subtype": result.get("subtype"), "result_is_error": result.get("is_error"),
        "result_text": str(result.get("result"))[:200], "api_error_status": result.get("api_error_status"),
        "edited_before_stop": "OLIVIUM_MOCK_EDIT" in run["repo_files"]["sample.txt"],
        "stderr_head": run["stderr"][:300],
    }


def section_cap_experiment(report: Report):
    results = []
    for status in (400, 402, 403, 429, 529):
        for header in (True, False):
            results.append(cap_stop_run(status, header=header))
            report.section("cap_experiment", variants=results)
    for repeat in (1, 2):
        results.append(cap_stop_run(CHOSEN_CAP_STATUS, header=True, repeat=repeat))
    chosen = [r for r in results if r["http_status"] == CHOSEN_CAP_STATUS and r["x_should_retry_false"]]
    report.section(
        "cap_experiment", variants=results, chosen_status=CHOSEN_CAP_STATUS,
        chosen_samples=len(chosen),
        chosen_ends_promptly=all(
            not r["timed_out_by_runner"] and r["refused_requests"] == 1 and r["wall_seconds"] <= MAX_ACCEPTABLE_CAP_SECONDS
            and r["exit_code"] not in (None, 0) for r in chosen),
    )
    return results


def section_run_cap(report: Report):
    start_meter(0.0075, 50)
    plan = {"steps": [{"name": "Read", "input": {"file_path": "/work/repo/sample.txt"}},
                      {"name": "Read", "input": {"file_path": "/work/repo/README.md"}},
                      {"name": "Read", "input": {"file_path": "/work/repo/sample.txt"}}], "final_text": "done"}
    encoded = base64.b64encode(json.dumps(plan).encode()).decode()
    capped = run_agent("runcap-a", "runcap-a", f"Read things. OLIVIUM_MOCK_PLAN_B64={encoded}\n", timeout_s=75)
    survivor = run_agent("runcap-b", "runcap-b", "Edit. OLIVIUM_MOCK_TARGET=/work/repo/sample.txt\n", timeout_s=75)
    rows = meter_log()
    a, b = [r for r in rows if r["run_id"] == "runcap-a"], [r for r in rows if r["run_id"] == "runcap-b"]
    report.write("run_cap_requests.json", rows)
    report.section(
        "run_cap", cap_usd=0.0075,
        run_a={"rows": [(r["status"], r["cost_usd"]) for r in a], "spent_nanousd": cost(a),
               "exit_code": capped["exit_code"], "wall_seconds": capped["wall_seconds"],
               "result_subtype": (capped["result"] or {}).get("subtype"), "stopped_by_cap": any(r["status"] == "cap_run" for r in a)},
        run_b={"statuses": [r["status"] for r in b], "spent_nanousd": cost(b), "exit_code": b and survivor["exit_code"],
               "result_subtype": (survivor["result"] or {}).get("subtype"),
               "completed": all(r["status"] == "ok" for r in b) and (survivor["result"] or {}).get("subtype") == "success"},
    )


def section_total_cap(report: Report):
    start_meter(1.0, 0.015)
    first = run_agent("total-a", "total-a", "Edit. OLIVIUM_MOCK_TARGET=/work/repo/sample.txt\n", timeout_s=75)
    second = run_agent("total-b", "total-b", "Edit. OLIVIUM_MOCK_TARGET=/work/repo/sample.txt\n", timeout_s=75)
    third = run_agent("total-c", "total-c", "Edit. OLIVIUM_MOCK_TARGET=/work/repo/sample.txt\n", timeout_s=75)
    before_restart = meter_log()
    docker("stop", "-t", "2", METER_NAME)
    docker("start", METER_NAME)
    deadline = time.time() + 20
    while time.time() < deadline and "listening" not in docker("logs", METER_NAME, check=False).stdout:
        time.sleep(0.2)
    time.sleep(0.3)
    after = run_agent("total-d", "total-d", "Edit. OLIVIUM_MOCK_TARGET=/work/repo/sample.txt\n", timeout_s=75)
    rows = meter_log()
    report.write("total_cap_requests.json", rows)
    by = lambda run_id: [r["status"] for r in rows if r["run_id"] == run_id]
    report.section(
        "total_cap", cap_usd=0.015,
        total_a_completed=by("total-a") == ["ok"] * 3 and (first["result"] or {}).get("subtype") == "success",
        statuses={run_id: by(run_id) for run_id in ("total-a", "total-b", "total-c", "total-d")},
        total_c_wall_seconds=third["wall_seconds"], total_c_exit_code=third["exit_code"],
        total_d_after_restart_exit_code=after["exit_code"],
        spend_preserved_across_restart=by("total-d") == ["cap_total"] and len(before_restart) < len(rows),
        spent_nanousd_total=cost(rows),
        overshoot_nanousd=cost(rows) - round(0.015 * 1e9),
        bound_note="overshoot bounded by the cost of requests already in flight when the cap was reached",
    )


def section_fail_closed(report: Report):
    start_meter(5, 50)
    unknown = json.loads(post("/run/fc1/v1/messages", {"model": "claude-not-a-real-model", "max_tokens": 16,
                                                       "messages": [{"role": "user", "content": "x"}]}).stdout)
    no_prefix = json.loads(post("/v1/messages", {"model": "claude-sonnet-5-5"}).stdout)
    bad_path = json.loads(post("/run/fc1/v1/complete", {"model": "claude-sonnet-5-5"}).stdout)
    rows = meter_log()
    # Unwritable log: flip the file read-only inside the running meter.
    docker("exec", METER_NAME, "chmod", "444", "/data/requests.jsonl")
    stopped = json.loads(post("/run/fc2/v1/messages", {"model": "claude-sonnet-5-5", "max_tokens": 16, "stream": False,
                                                       "messages": [{"role": "user", "content": "x"}]}).stdout)
    docker("exec", METER_NAME, "chmod", "644", "/data/requests.jsonl")
    still_stopped = json.loads(post("/run/fc3/v1/messages", {"model": "claude-sonnet-5-5", "max_tokens": 16, "stream": False,
                                                             "messages": [{"role": "user", "content": "x"}]}).stdout)
    # Log directory that cannot be created: the meter must refuse to start.
    no_log = sh(["docker", "run", "--rm", "--name", "olivium-bench-prove-nostart", "--label", LABEL, *HARDENING,
                 "--memory=128m", "--network", "none", METER_IMAGE, "--mode", "mock", "--run-cap-usd", "1", "--total-cap-usd", "1",
                 "--log", "/nonexistent/dir/requests.jsonl"], check=False, timeout=30)
    no_caps = sh(["docker", "run", "--rm", "--name", "olivium-bench-prove-nostart2", "--label", LABEL, *HARDENING,
                  "--memory=128m", "--network", "none", METER_IMAGE, "--mode", "mock"], check=False, timeout=30)
    key_in_mock = sh(["docker", "run", "--rm", "--name", "olivium-bench-prove-nostart3", "--label", LABEL, *HARDENING,
                      "--memory=128m", "--network", "none", METER_IMAGE, "--mode", "mock", "--run-cap-usd", "1",
                      "--total-cap-usd", "1", "--key-file", "/etc/hostname"], check=False, timeout=30)
    logs = docker("logs", METER_NAME, check=False).stderr
    report.section(
        "fail_closed",
        unknown_model={"http": unknown["status"], "body": unknown["body"][:120], "should_retry_header": unknown.get("headers", {}).get("x-should-retry")},
        no_run_prefix_http=no_prefix["status"], non_messages_path_http=bad_path["status"],
        rows_before=[(r["run_id"], r["status"]) for r in rows],
        unwritable_log={"http": stopped["status"], "body": stopped["body"][:120]},
        stays_closed_after_log_restored={"http": still_stopped["status"], "body": still_stopped["body"][:120]},
        meter_stderr_tail=logs[-200:],
        missing_log_dir_refuses_start={"exit": no_log.returncode, "stderr": no_log.stderr[-200:]},
        missing_caps_refuses_start={"exit": no_caps.returncode, "stderr": no_caps.stderr[-160:]},
        key_file_in_mock_refuses_start={"exit": key_in_mock.returncode, "stderr": key_in_mock.stderr[-160:]},
    )


SECTIONS = ("isolation", "e2e", "plan", "cap_experiment", "run_cap", "total_cap", "fail_closed")


def build():
    sh(["docker", "build", "-q", "--label", LABEL, "-t", METER_IMAGE, os.path.join(VALUE_DIR, "meter")], timeout=600)
    sh(["docker", "build", "-q", "--label", LABEL, "-f", os.path.join(DOCKER_DIR, "agent.Dockerfile"),
        "--build-arg", f"DEPS_IMAGE={DEPS_IMAGE}", "-t", AGENT_IMAGE, DOCKER_DIR], timeout=900)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", required=True)
    parser.add_argument("--build", action="store_true")
    parser.add_argument("--only", default=",".join(SECTIONS))
    parser.add_argument("--keep", action="store_true", help="leave containers and networks for inspection")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    report = Report(args.out)
    wanted = [name for name in args.only.split(",") if name]
    for name in wanted:
        if name not in SECTIONS:
            parser.error(f"unknown section {name}")
    if args.build:
        build()
    remove_containers()
    setup_networks()
    failure = 0
    try:
        for name in wanted:
            started = time.monotonic()
            try:
                globals()[f"section_{name}"](report)
                report.section(name, section_ok=True, section_seconds=round(time.monotonic() - started, 1))
            except Exception as exc:  # noqa: BLE001 - record and continue so the report is complete
                failure = 1
                report.section(name, section_ok=False, error=f"{type(exc).__name__}: {exc}")
    finally:
        if not args.keep:
            remove_containers()
            remove_networks()
    print(json.dumps({"report": os.path.join(args.out, "proof.json"), "failure": failure}))
    return failure


if __name__ == "__main__":
    sys.exit(main())
