import importlib.util
import json
import logging
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "memory_watch.py"
spec = importlib.util.spec_from_file_location("memory_watch", SCRIPT)
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)
BOOT = "00000000-0000-0000-0000-000000000001"


class RecorderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "proc"
        self.root.mkdir()
        boot = self.root / "sys/kernel/random"
        boot.mkdir(parents=True)
        (boot / "boot_id").write_text(BOOT)
        (self.root / "meminfo").write_text(
            "MemTotal: 16000000 kB\nMemAvailable: 4000000 kB\nAnonPages: 10000000 kB\n")
        (self.root / "loadavg").write_text("1 2 3 1/100 123")
        (self.root / "uptime").write_text("12345.12 1234.00")
        for pid, anon in ((42, 4000000), (43, 5000000)):
            path = self.root / str(pid)
            path.mkdir()
            stat = ["S"] + ["0"] * 49
            stat[11], stat[12], stat[19] = "123", "45", str(pid * 100)
            (path / "stat").write_text(f"{pid} (name with ) parens) " + " ".join(stat))
            (path / "status").write_text(
                f"Name:\tpython3\nPPid:\t1\nVmRSS:\t{anon+1000} kB\n"
                f"RssAnon:\t{anon} kB\nThreads:\t2\n")
            (path / "io").write_text("read_bytes: 1234\nwrite_bytes: 5678\n")
            (path / "cgroup").write_text("0::/system.slice/test.service")
            (path / "cmdline").write_bytes(b"python3\0/home/ckb/task.py\0--token\0SECRET_TEST\0")

    def command(self, *args):
        return [sys.executable, str(SCRIPT), "--proc-root", str(self.root),
                "--output", str(self.base / "out"), "--interval", "1", *args]

    def test_snapshot_handles_exit_optional_fields_and_identifies_process(self):
        (self.root / "99").mkdir()  # A process exits before status can be read.
        (self.root / "42/io").unlink()
        result = watch.snapshot(self.root, BOOT)
        self.assertEqual(result["skipped"], 1)
        self.assertEqual(result["meminfo_KiB"]["AnonPages"], 10000000)
        self.assertIsNone(result["meminfo_KiB"]["SwapFree"])
        first, second = result["processes"]
        self.assertEqual(first["pid"], 43)
        self.assertEqual(first["start_ticks"], 4300)
        self.assertEqual(first["cpu_ticks"], 168)
        self.assertEqual(first["io"]["write_bytes"], 5678)
        self.assertEqual(first["scripts"], ["/home/ckb/task.py"])
        self.assertIsNone(second["io"])
        self.assertNotIn("SECRET_TEST", json.dumps(result))

    def test_pid_reuse_during_scan_discards_sample(self):
        original = watch.read
        seen = 0

        def changing_stat(path):
            nonlocal seen
            value = original(path)
            if path == self.root / "42/stat":
                seen += 1
                if seen == 2:
                    return value.replace("4200", "9999")
            return value

        with patch.object(watch, "read", side_effect=changing_stat):
            self.assertIsNone(watch.process(self.root / "42"))

    def test_new_boot_retains_prior_evidence_and_prunes_only_owned_directories(self):
        output = self.base / "history"
        output.mkdir()
        unrelated = output / "boot-unrelated"
        unrelated.mkdir()
        (unrelated / "keep.txt").write_text("unrelated")
        paths = []
        for index in range(1, 5):
            boot = f"00000000-0000-0000-0000-{index:012d}"
            current = watch.prepare_boot(output, boot, 3, {"interval": 5})
            (current / "samples.jsonl").write_text(f"evidence-{index}\n")
            os.utime(current / "metadata.json", (index, index))
            paths.append(current)
        self.assertFalse(paths[0].exists())
        self.assertEqual((paths[1] / "samples.jsonl").read_text(), "evidence-2\n")
        self.assertTrue(unrelated.exists())
        watch.prepare_boot(output, "00000000-0000-0000-0000-000000000004", 3, {})
        self.assertEqual((paths[3] / "samples.jsonl").read_text(), "evidence-4\n")

    def test_sampling_singleton_shutdown_and_append(self):
        child = subprocess.Popen(self.command(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: child.kill() if child.poll() is None else None)
        logfile = self.base / "out" / ("boot-" + BOOT) / "samples.jsonl"
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if logfile.exists() and len(logfile.read_text().splitlines()) >= 2:
                break
            if child.poll() is not None:
                self.fail(child.communicate())
            time.sleep(0.05)
        self.assertTrue(logfile.exists())
        duplicate = subprocess.run(self.command("--samples", "1"), capture_output=True, text=True, timeout=5)
        self.assertNotEqual(duplicate.returncode, 0)
        self.assertIn("already running", duplicate.stderr)
        child.terminate()
        child.communicate(timeout=5)
        self.assertEqual(child.returncode, 0)
        before = logfile.read_text().splitlines()
        self.assertGreaterEqual(len(before), 2)
        subprocess.run(self.command("--samples", "1"), check=True, capture_output=True, timeout=5)
        after = logfile.read_text().splitlines()
        self.assertEqual(len(after), len(before) + 1)
        self.assertTrue(all(json.loads(line)["boot_id"] == BOOT for line in after))

    def test_rotation_and_write_failure_are_not_silent(self):
        handler = watch.DurableRotatingHandler(self.base / "rotate", maxBytes=100, backupCount=7)
        try:
            for _ in range(100):
                handler.emit(logging.makeLogRecord({"msg": "x" * 50, "levelno": 20}))
            self.assertEqual(len(list(self.base.glob("rotate*"))), 8)
            with patch.object(handler.stream, "write", side_effect=OSError("disk full")):
                with self.assertRaises(OSError):
                    handler.emit(logging.makeLogRecord({"msg": "failure", "levelno": 20}))
        finally:
            handler.close()

    def test_invalid_interval_rejected_before_output_creation(self):
        for interval in ("0", "nan", "inf"):
            result = subprocess.run(self.command("--interval", interval), capture_output=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.base / "out").exists())


if __name__ == "__main__":
    unittest.main()
