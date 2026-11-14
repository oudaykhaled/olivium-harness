"""Thin, name-checked wrappers around the docker CLI.

Every name this module creates is olivium-bench-* and labelled olivium-bench=1.
Host subprocesses are limited to docker, git and the mix launcher, and nothing
from a container is ever executed or expanded on the host. Archives coming out
of a container are read member by member through allow-lists.
"""

import io
import os
import subprocess
import tarfile
import time

from lib.common import BenchError

ALLOWED_EXECUTABLES = {"docker", "git", "mix"}
LABEL = "olivium-bench=1"
PREFIX = "olivium-bench-"


class DockerError(BenchError):
    """Docker failed or timed out; callers score the run as infra_error."""


def _check_exe(cmd):
    if cmd[0] not in ALLOWED_EXECUTABLES:
        raise BenchError("refusing host subprocess: %s" % cmd[0])


def sh(cmd, timeout=300, input_bytes=None):
    _check_exe(cmd)
    try:
        return subprocess.run(
            cmd,
            input=input_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise DockerError("timed out after %ss: %s" % (timeout, " ".join(cmd[:4]))) from exc


def docker(*args, timeout=300, input_bytes=None, check=True):
    done = sh(["docker"] + list(args), timeout=timeout, input_bytes=input_bytes)
    if check and done.returncode != 0:
        raise DockerError(
            "docker %s failed (%d): %s"
            % (" ".join(args[:3]), done.returncode, done.stderr.decode("utf-8", "replace")[:400])
        )
    return done


def require_name(name):
    if not name.startswith(PREFIX):
        raise BenchError("docker name outside the olivium-bench namespace: %s" % name)
    return name


def create(name, image, network=None, memory=None, cpus=None, pids=None, env=None,
           command=None, harden=True, swap_equals_memory=True, extra=None):
    require_name(name)
    cmd = ["create", "--name", name, "--label", LABEL]
    if network:
        cmd += ["--network", network]
    if harden:
        cmd += ["--cap-drop=ALL", "--security-opt=no-new-privileges"]
    if memory:
        cmd += ["--memory", memory]
        if swap_equals_memory:
            cmd += ["--memory-swap", memory]
    if cpus:
        cmd += ["--cpus", cpus]
    if pids:
        cmd += ["--pids-limit", pids]
    for key, value in (env or {}).items():
        cmd += ["--env", "%s=%s" % (key, value)]
    cmd += list(extra or [])
    cmd.append(image)
    cmd += list(command or [])
    docker(*cmd, timeout=180)


def remove(name):
    require_name(name)
    docker("rm", "-f", name, check=False, timeout=180)


def network_create(name, internal=False):
    require_name(name)
    if docker("network", "inspect", name, check=False, timeout=60).returncode == 0:
        return
    cmd = ["network", "create", "--label", LABEL]
    if internal:
        # The same flags as docker/net.sh: no host-side gateway, no default route.
        cmd += ["--internal", "-o", "com.docker.network.bridge.gateway_mode_ipv4=isolated"]
    cmd.append(name)
    docker(*cmd, timeout=120)


def network_remove(name):
    require_name(name)
    docker("network", "rm", name, check=False, timeout=120)


def cp_in(name, dest_dir, tar_bytes, archive=True):
    """docker cp a tar stream into dest_dir of a created or running container."""
    require_name(name)
    args = ["cp"] + (["-a"] if archive else []) + ["-", "%s:%s" % (name, dest_dir)]
    docker(*args, input_bytes=tar_bytes, timeout=240)


def cp_out_file(name, src_path, tar_path, timeout=600):
    """docker cp a path out as a tar archive into a file on the host."""
    require_name(name)
    with open(tar_path, "wb") as handle:
        try:
            done = subprocess.run(
                ["docker", "cp", "%s:%s" % (name, src_path), "-"],
                stdout=handle,
                stderr=subprocess.PIPE,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired as exc:
            raise DockerError("docker cp out timed out") from exc
    if done.returncode != 0:
        raise DockerError("docker cp out failed: %s" % done.stderr.decode("utf-8", "replace")[:400])


def cp_between(src_name, src_path, dst_name, dst_dir, max_bytes=3 * (1 << 30), timeout=900):
    """Stream a directory tar from one container into another without host unpack."""
    require_name(src_name)
    require_name(dst_name)
    src = subprocess.Popen(
        ["docker", "cp", "%s:%s" % (src_name, src_path), "-"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    dst = subprocess.Popen(
        ["docker", "cp", "-a", "-", "%s:%s" % (dst_name, dst_dir)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    total = 0
    deadline = time.time() + timeout
    failed = None
    try:
        while True:
            chunk = src.stdout.read(1 << 20)
            if not chunk:
                break
            total += len(chunk)
            if total > max_bytes:
                failed = "repository archive larger than %d bytes" % max_bytes
                break
            if time.time() > deadline:
                failed = "repository copy timed out"
                break
            dst.stdin.write(chunk)
        dst.stdin.close()
    except BrokenPipeError:
        failed = "repository copy pipe closed"
    if failed:
        src.kill()
        dst.kill()
    src_err = src.stderr.read()
    dst_err = dst.stderr.read()
    src.wait(timeout=60)
    dst.wait(timeout=60)
    if failed:
        raise DockerError(failed)
    if src.returncode != 0 or dst.returncode != 0:
        raise DockerError(
            "repository copy failed: %s %s"
            % (src_err.decode("utf-8", "replace")[:300], dst_err.decode("utf-8", "replace")[:300])
        )


def start(name):
    require_name(name)
    docker("start", name, timeout=120)


def wait(name, timeout):
    """Exit code of a started container, or None when the host-side limit elapsed."""
    require_name(name)
    try:
        done = sh(["docker", "wait", name], timeout=timeout)
    except DockerError:
        return None
    if done.returncode != 0:
        raise DockerError("docker wait failed: %s" % done.stderr.decode("utf-8", "replace")[:300])
    return int(done.stdout.decode("ascii", "replace").strip() or "-1")


def kill(name):
    require_name(name)
    docker("kill", name, check=False, timeout=120)


def image_id(reference):
    done = docker("image", "inspect", "--format", "{{.Id}}", reference, check=False, timeout=60)
    if done.returncode != 0:
        return None
    return done.stdout.decode("ascii", "replace").strip()


def image_label(reference, label):
    done = docker(
        "image", "inspect", "--format", '{{index .Config.Labels "%s"}}' % label,
        reference, check=False, timeout=60,
    )
    if done.returncode != 0:
        return None
    return done.stdout.decode("ascii", "replace").strip()


def leftover_names(tag, kinds):
    """Containers from an earlier interrupted invocation of this output directory."""
    done = docker(
        "ps", "-a", "--filter", "label=olivium-bench=1",
        "--format", "{{.Names}}", check=False, timeout=60,
    )
    if done.returncode != 0:
        return []
    names = done.stdout.decode("utf-8", "replace").split()
    return [
        name for name in names
        if any(name.startswith("olivium-bench-%s-%s" % (kind, tag)) for kind in kinds)
    ]


def _tar_parents(arcname, seen, uid, gid, tar):
    parts = arcname.split("/")[:-1]
    for index in range(1, len(parts) + 1):
        directory = "/".join(parts[:index])
        if directory in seen:
            continue
        seen.add(directory)
        info = tarfile.TarInfo(directory)
        info.type = tarfile.DIRTYPE
        info.mode = 0o755
        info.uid = uid
        info.gid = gid
        info.mtime = 1
        tar.addfile(info)


def make_tar(entries, uid=0, gid=0):
    """In-memory tar. entries: (arcname, data bytes, mode) or (arcname, None, mode) for a dir."""
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.GNU_FORMAT) as tar:
        seen = set()
        for arcname, data, mode in entries:
            _tar_parents(arcname, seen, uid, gid, tar)
            if data is None:
                if arcname in seen:
                    continue
                seen.add(arcname)
                info = tarfile.TarInfo(arcname)
                info.type = tarfile.DIRTYPE
                info.mode = mode
                info.uid = uid
                info.gid = gid
                info.mtime = 1
                tar.addfile(info)
                continue
            info = tarfile.TarInfo(arcname)
            info.size = len(data)
            info.mode = mode
            info.uid = uid
            info.gid = gid
            info.mtime = 1
            tar.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


def extract_members(tar_path, allowed, dest_dir, max_member_bytes=512 * (1 << 20)):
    """Write allow-listed regular files from a host tar to dest_dir by fixed name.

    allowed maps a member basename to the destination filename. Member paths are
    never used to build a host path. Returns {basename: bytes written}.
    """
    written = {}
    with tarfile.open(tar_path, mode="r") as tar:
        for member in tar:
            if not member.isfile():
                continue
            base = os.path.basename(member.name.rstrip("/"))
            if base not in allowed or base in written:
                continue
            if member.size > max_member_bytes:
                raise DockerError("member %s larger than limit" % base)
            target = os.path.join(dest_dir, allowed[base])
            source = tar.extractfile(member)
            if source is None:
                continue
            count = 0
            with open(target, "wb") as handle:
                for chunk in iter(lambda: source.read(1 << 20), b""):
                    count += len(chunk)
                    if count > max_member_bytes:
                        raise DockerError("member %s larger than limit" % base)
                    handle.write(chunk)
            written[base] = count
    return written
