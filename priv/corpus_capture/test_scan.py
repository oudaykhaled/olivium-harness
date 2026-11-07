"""Generic scanner mechanics; no oracle inputs or model-quality assertions."""
import importlib.util
import io
import os
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("corpus_scan", Path(__file__).with_name("scan.py"))
scan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scan)
RUN = "12345678-1234-1234-1234-123456789abc"


class ScannerTests(unittest.TestCase):
    def test_large_flat_directory_is_batched_and_acknowledged(self):
        with tempfile.TemporaryDirectory() as root:
            for number in range(311):
                Path(root, f"generic-{number:04}.md").write_text("ordinary public fixture")
            enumerator = scan.Enumerator()
            batch = enumerator.request({"v": 1, "op": "open", "run_id": RUN, "root": root, "relative_path": ""})
            names = set()
            while True:
                self.assertLessEqual(len(batch["entries"]), 100)
                self.assertLessEqual(len(scan.encode(batch)), 65536)
                names.update(entry["relative_path"] for entry in batch["entries"])
                done = batch["done"]
                batch = enumerator.request({"v": 1, "op": "ack", "run_id": RUN, "seq": batch["seq"]})
                if done:
                    self.assertTrue(batch["acked"])
                    break
            self.assertEqual(len(names), 311)

    def test_reopen_without_ack_and_replayed_ack_are_refused(self):
        with tempfile.TemporaryDirectory() as root:
            enumerator = scan.Enumerator()
            request = {"v": 1, "op": "open", "run_id": RUN, "root": root, "relative_path": ""}
            batch = enumerator.request(request)
            with self.assertRaisesRegex(ValueError, "ack_required"):
                enumerator.request(request)
            enumerator.request({"v": 1, "op": "ack", "run_id": RUN, "seq": batch["seq"]})
            with self.assertRaisesRegex(ValueError, "invalid_ack"):
                enumerator.request({"v": 1, "op": "ack", "run_id": RUN, "seq": batch["seq"]})

    def test_restart_reenumerates_without_trusting_native_offsets(self):
        with tempfile.TemporaryDirectory() as root:
            Path(root, "first.md").write_text("first")
            request = {"v": 1, "op": "open", "run_id": RUN, "root": root, "relative_path": ""}
            old = scan.Enumerator()
            old.request(request)
            old.close()
            Path(root, "later.md").write_text("later")
            new = scan.Enumerator()
            batch = new.request(request)
            self.assertEqual({e["relative_path"] for e in batch["entries"]}, {"first.md", "later.md"})
            new.close()

    def test_symlink_and_path_escape_are_not_followed(self):
        with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory() as outside:
            Path(outside, "secret.md").write_text("must never be enumerated")
            os.symlink(outside, Path(root, "link"))
            enumerator = scan.Enumerator()
            batch = enumerator.request({"v": 1, "op": "open", "run_id": RUN, "root": root, "relative_path": ""})
            self.assertEqual(batch["entries"][0]["error_code"], "symlink_not_allowed")
            enumerator.close()
            with self.assertRaises(ValueError):
                scan.safe_directory(root, "../escape")
            with self.assertRaises(ValueError):
                scan.safe_directory(root, "link")

    def test_size_is_checked_before_payload_read_and_duplicate_keys_refuse(self):
        with self.assertRaisesRegex(ValueError, "frame_too_large"):
            scan.read_frame(io.BytesIO(struct.pack(">I", 131073)))
        body = b'{"v":1,"v":1}'
        with self.assertRaisesRegex(ValueError, "duplicate_key"):
            scan.read_frame(io.BytesIO(struct.pack(">I", len(body)) + body))

    def test_directory_change_is_reported_incomplete(self):
        with tempfile.TemporaryDirectory() as root:
            for number in range(101):
                Path(root, f"{number}.md").write_text("generic")
            enumerator = scan.Enumerator()
            batch = enumerator.request({"v": 1, "op": "open", "run_id": RUN, "root": root, "relative_path": ""})
            Path(root, "changed.md").write_text("changed")
            while not batch["done"]:
                batch = enumerator.request({"v": 1, "op": "ack", "run_id": RUN, "seq": batch["seq"]})
            self.assertFalse(batch["stable"])
            enumerator.close()


if __name__ == "__main__":
    unittest.main()
