"""Run a candidate export's hook commands on many hook inputs, in Docker or on the host.

Docker (the only mode for recorded calls): one container per batch from the task's
agent image, `--network none`, all capabilities dropped, the candidate harness
installed into /work/repo as bench/value/arms/entry.sh does, then
hook_driver.sh runs each hook command with one JSON input on stdin.

Host (synthetic inputs only): the same driver with `sh`, in a fresh scratch
copy of the export. The inputs are fixed synthetic strings shipped in this
directory; nothing from a task repository or a transcript reaches the host shell.

Docker resources: olivium-bench-replay-* containers, labelled olivium-bench=1,
removed after each batch.
"""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
VALUE_DIR = os.path.dirname(HERE)
if VALUE_DIR not in sys.path:
    sys.path.insert(0, VALUE_DIR)

from lib import dockerops as dk  # noqa: E402  (read-only use of the shared Docker helpers)

DRIVER = os.path.join(HERE, "hook_driver.sh")
AGENT_UID = 1001


class RunError(Exception):
    pass


def export_entries(export_dir):
    """(relative path, bytes, mode) of every regular file of an export."""
    entries = []
    for root, dirs, files in os.walk(export_dir):
        dirs.sort()
        for name in sorted(files):
            path = os.path.join(root, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            rel = os.path.relpath(path, export_dir)
            with open(path, "rb") as handle:
                entries.append((rel, handle.read(), 0o644))
    return entries


def _layout(items):
    """payloads.tsv text and the hook files, one file per distinct command."""
    names = {}
    hooks = {}
    lines = []
    for command, payload in items:
        name = names.get(command)
        if name is None:
            name = "h%03d-%s" % (len(names) + 1, hashlib.sha256(command.encode("utf-8")).hexdigest()[:12])
            names[command] = name
            hooks[name] = command.encode("utf-8")
        line = json.dumps(payload, ensure_ascii=True, separators=(",", ":"))
        if "\n" in line or "\t" in line:
            raise RunError("a hook input did not serialize to one line")
        lines.append("%s\t%s" % (name, line))
    return ("\n".join(lines) + "\n").encode("ascii"), hooks


def _parse_results(read_member, count):
    results = []
    for index in range(1, count + 1):
        code_text = (read_member("r/%d.code" % index) or b"").decode("ascii", "replace").strip()
        results.append({
            "code": int(code_text) if code_text.lstrip("-").isdigit() else None,
            "out": (read_member("r/%d.out" % index) or b"").decode("utf-8", "replace")[:4000],
            "err": (read_member("r/%d.err" % index) or b"").decode("utf-8", "replace")[:4000],
        })
    return results


def run_docker(items, export_dir, image, label, timeout=1800):
    if not items:
        return []
    if dk.image_id(image) is None:
        raise RunError("image %s is missing" % image)
    payloads, hooks = _layout(items)
    with open(DRIVER, "rb") as handle:
        driver = handle.read()
    entries = [("in/hook_driver.sh", driver, 0o755), ("in/payloads.tsv", payloads, 0o644)]
    entries += [("in/hooks/%s" % name, data, 0o644) for name, data in sorted(hooks.items())]
    entries += [("in/arm/%s" % rel, data, mode) for rel, data, mode in export_entries(export_dir)]
    name = "olivium-bench-replay-%s" % label
    dk.remove(name)
    try:
        dk.create(
            name, image, network="none", memory="1g", pids="256",
            env={"GATE_IN": "/work/in", "GATE_OUT": "/work/out", "GATE_PROJECT": "/work/repo", "GATE_INSTALL_ARM": "1"},
            command=["/work/in/hook_driver.sh"], extra=["--entrypoint", "/bin/sh"],
        )
        dk.cp_in(name, "/work", dk.make_tar(entries, uid=AGENT_UID, gid=AGENT_UID), archive=True)
        dk.start(name)
        code = dk.wait(name, timeout=timeout)
        if code is None:
            raise RunError("replay container did not finish within %d s" % timeout)
        handle = tempfile.NamedTemporaryFile(suffix=".tar", delete=False)
        handle.close()
        try:
            dk.cp_out_file(name, "/work/out", handle.name)
            members = {}
            with tarfile.open(handle.name, mode="r") as tar:
                for member in tar:
                    if member.isfile() and member.size <= 1 << 20:
                        rel = member.name.split("/", 1)[1] if "/" in member.name else member.name
                        members[rel] = tar.extractfile(member).read()
        finally:
            os.unlink(handle.name)
        if code != 0:
            raise RunError("replay driver exited %s in %s" % (code, image))
        return _parse_results(members.get, len(items))
    finally:
        dk.remove(name)


def run_host(items, export_dir, scratch, timeout=900):
    """Synthetic inputs only. scratch must not exist; it is created and kept for inspection."""
    if os.path.exists(scratch):
        raise RunError("host scratch directory must be fresh: %s" % scratch)
    if not items:
        return []
    project = os.path.join(scratch, "project")
    gate_in = os.path.join(scratch, "in")
    gate_out = os.path.join(scratch, "out")
    shutil.copytree(export_dir, project, symlinks=True)
    os.makedirs(os.path.join(gate_in, "hooks"))
    payloads, hooks = _layout(items)
    with open(os.path.join(gate_in, "payloads.tsv"), "wb") as handle:
        handle.write(payloads)
    for name, data in hooks.items():
        with open(os.path.join(gate_in, "hooks", name), "wb") as handle:
            handle.write(data)
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": scratch, "LC_ALL": "C",
           "GATE_IN": gate_in, "GATE_OUT": gate_out, "GATE_PROJECT": project}
    done = subprocess.run(["/bin/sh", DRIVER], env=env, cwd=project, capture_output=True, timeout=timeout)
    if done.returncode != 0:
        raise RunError("host replay driver exited %d: %s" % (done.returncode, done.stderr.decode("utf-8", "replace")[:300]))

    def read_member(rel):
        path = os.path.join(gate_out, rel)
        if not os.path.isfile(path):
            return None
        with open(path, "rb") as handle:
            return handle.read()

    return _parse_results(read_member, len(items))


def pretool_verdict(result):
    """(refused, reason) from one PreToolUse hook run, as Claude Code reads it."""
    code = result.get("code")
    if code == 2:
        return True, ("exit 2: " + result.get("err", "").strip())[:300]
    if code == 0:
        for line in result.get("out", "").splitlines():
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                data = json.loads(line)
            except ValueError:
                continue
            specific = data.get("hookSpecificOutput") or {}
            decision = specific.get("permissionDecision") or data.get("decision")
            if decision in ("deny", "block", "ask"):
                return True, str(specific.get("permissionDecisionReason") or data.get("reason") or decision)[:300]
    return False, None

