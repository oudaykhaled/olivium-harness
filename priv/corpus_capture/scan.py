"""Bounded, ACK-driven directory enumeration. No source bodies, network or credentials."""
import hashlib
import json
import os
import stat
import struct
import sys

MAX_FRAME = 131072
MAX_BATCH = 65536
MAX_ENTRIES = 100


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")


def read_exact(stream, size):
    result = bytearray()
    while len(result) < size:
        part = stream.read(size - len(result))
        if not part:
            raise EOFError
        result.extend(part)
    return bytes(result)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate_key")
        result[key] = value
    return result


def read_frame(stream):
    size = struct.unpack(">I", read_exact(stream, 4))[0]
    if not 0 < size <= MAX_FRAME:
        raise ValueError("frame_too_large")
    return json.loads(read_exact(stream, size).decode("utf-8"), object_pairs_hook=unique_object)


def write_frame(stream, value):
    data = encode(value)
    if len(data) > MAX_BATCH:
        raise ValueError("frame_too_large")
    stream.write(struct.pack(">I", len(data)) + data)
    stream.flush()


def fingerprint(path):
    value = os.stat(path, follow_symlinks=False)
    if not stat.S_ISDIR(value.st_mode):
        raise ValueError("unsafe_directory")
    return hashlib.sha256(encode([value.st_dev, value.st_ino, value.st_mtime_ns])).hexdigest()


def safe_directory(root, relative):
    if not isinstance(root, str) or not os.path.isabs(root):
        raise ValueError("unsafe_directory")
    if not isinstance(relative, str) or os.path.isabs(relative) or ".." in relative.split("/"):
        raise ValueError("path_escape")
    path = os.path.normpath(os.path.join(root, relative))
    if os.path.commonpath([root, path]) != os.path.normpath(root):
        raise ValueError("path_escape")
    current = os.path.sep
    for component in path.split(os.path.sep):
        if not component:
            continue
        current = os.path.join(current, component)
        mode = os.lstat(current).st_mode
        if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
            raise ValueError("symlink_not_allowed")
    return path


class Enumerator:
    def __init__(self):
        self.iterator = None
        self.pending = None
        self.run_id = None
        self.seq = 0
        self.waiting = False
        self.done = False

    def close(self):
        if self.iterator is not None:
            self.iterator.close()
        self.iterator = None
        self.pending = None
        self.waiting = False

    def request(self, request):
        if not isinstance(request, dict) or request.get("v") != 1:
            raise ValueError("invalid_input")
        op = request.get("op")
        if op == "open":
            if set(request) != {"v", "op", "run_id", "root", "relative_path"}:
                raise ValueError("invalid_input")
            if self.waiting:
                raise ValueError("ack_required")
            self.close()
            self.path = safe_directory(request["root"], request["relative_path"])
            self.relative = request["relative_path"]
            self.before = fingerprint(self.path)
            self.run_id = request["run_id"]
            if not isinstance(self.run_id, str) or len(self.run_id) != 36:
                raise ValueError("invalid_input")
            self.iterator = os.scandir(self.path)
            self.seq = 0
            self.done = False
            return self.batch()
        if op == "ack":
            if set(request) != {"v", "op", "run_id", "seq"}:
                raise ValueError("invalid_input")
            if not self.waiting or request["run_id"] != self.run_id or type(request["seq"]) is not int or request["seq"] != self.seq:
                raise ValueError("invalid_ack")
            self.waiting = False
            if self.done:
                self.close()
                return {"v": 1, "run_id": self.run_id, "acked": True}
            self.seq += 1
            return self.batch()
        if op == "cancel" and set(request) == {"v", "op"}:
            self.close()
            return {"v": 1, "cancelled": True}
        raise ValueError("invalid_input")

    def entry(self, entry):
        relative = (self.relative + "/" + entry.name).lstrip("/")
        if len(relative.encode("utf-8", "strict")) > 4096:
            raise ValueError("invalid_path")
        if entry.is_symlink():
            kind, error = "other", "symlink_not_allowed"
        elif entry.is_dir(follow_symlinks=False):
            kind, error = "directory", None
        elif entry.is_file(follow_symlinks=False):
            kind, error = "file", None
        else:
            kind, error = "other", "unsupported_file"
        return {"relative_path": relative, "kind": kind, "error_code": error}

    def batch(self):
        response = {"v": 1, "run_id": self.run_id, "seq": self.seq, "entries": [],
                    "done": False, "stable": True, "directory_fingerprint": self.before,
                    "error_code": None}
        while len(response["entries"]) < MAX_ENTRIES:
            try:
                entry = self.pending if self.pending is not None else self.entry(next(self.iterator))
                self.pending = None
            except StopIteration:
                self.done = True
                response["done"] = True
                response["stable"] = fingerprint(self.path) == self.before
                break
            response["entries"].append(entry)
            if len(encode(response)) > MAX_BATCH - 256:
                response["entries"].pop()
                self.pending = entry
                break
        self.waiting = True
        return response


def main():
    enumerator = Enumerator()
    try:
        while True:
            try:
                request = read_frame(sys.stdin.buffer)
            except EOFError:
                break
            try:
                response = enumerator.request(request)
            except (ValueError, OSError, UnicodeError) as error:
                allowed = {"invalid_input", "path_escape", "unsafe_directory", "symlink_not_allowed",
                           "invalid_path", "ack_required", "invalid_ack"}
                code = str(error) if isinstance(error, ValueError) and str(error) in allowed else "unreadable_directory"
                enumerator.close()
                response = {"v": 1, "error_code": code}
            write_frame(sys.stdout.buffer, response)
    finally:
        enumerator.close()


if __name__ == "__main__":
    main()
