#!/usr/bin/env python3
"""Low-frequency Linux process memory/IO recorder; Python standard library only."""
import argparse
import datetime
import fcntl
import json
import logging
import logging.handlers
import os
from pathlib import Path
import re
import shutil
import signal
import time

COLLECTOR = "ckb-sync-memory-watch-v1"


class DurableRotatingHandler(logging.handlers.RotatingFileHandler):
    def handleError(self, record):
        # Let systemd report/restart a failed collector instead of silently losing data.
        raise OSError("Recorder log write failed")


def prepare_boot(output, boot_id, keep_boots, settings):
    if not re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", boot_id):
        raise ValueError("Invalid Linux boot ID")
    current = output / ("boot-" + boot_id)
    current.mkdir(exist_ok=True)
    marker = current / "metadata.json"
    if not marker.exists():
        with marker.open("w") as stream:
            json.dump({"collector": COLLECTOR, "boot_id": boot_id,
                       "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                       "clock_ticks_per_second": os.sysconf("SC_CLK_TCK"),
                       "settings": settings}, stream)
            stream.flush()
            os.fsync(stream.fileno())
    # Only prune our marked boot directories, never unrelated diagnostics.
    previous = []
    for path in output.glob("boot-*"):
        if path == current or path.is_symlink() or not path.is_dir():
            continue
        try:
            metadata = json.loads(read(path / "metadata.json"))
            if (metadata.get("collector") == COLLECTOR and
                    path.name == "boot-" + metadata.get("boot_id", "")):
                previous.append(path)
        except (OSError, ValueError):
            continue
    previous.sort(key=lambda path: (path / "metadata.json").stat().st_mtime, reverse=True)
    for path in previous[keep_boots - 1:]:
        shutil.rmtree(path)
    return current


def read(path):
    return path.read_text(errors="replace").strip()


def fields(path):
    return dict(line.split(":", 1) for line in read(path).splitlines() if ":" in line)


def number(data, key):
    value = data.get(key)
    return int(value.split()[0]) if value else None


def link(path):
    try:
        return os.readlink(path)
    except OSError:
        return None


def process(path):
    # stat fields after the last ')' begin at field 3, state.
    stat = read(path / "stat").rsplit(")", 1)[1].split()
    data = fields(path / "status")
    if "VmRSS" not in data:  # Kernel threads have no userspace address space.
        return None
    row = {"pid": int(path.name), "ppid": number(data, "PPid"),
           "name": data.get("Name", "").strip(), "state": stat[0],
           "start_ticks": int(stat[19]), "cpu_ticks": int(stat[11]) + int(stat[12]),
           "threads": number(data, "Threads"), "exe": link(path / "exe"),
           "cwd": link(path / "cwd")}
    for key in ("VmRSS", "RssAnon", "RssFile", "RssShmem", "VmSwap", "VmHWM"):
        row[key + "_KiB"] = number(data, key)
    for filename in ("io", "cgroup"):
        try:
            row[filename] = (dict((k, int(v.strip())) for k, v in fields(path / filename).items())
                             if filename == "io" else read(path / filename).splitlines())
        except (OSError, ValueError):
            row[filename] = None
    # Keep script filenames only, never complete command arguments or environment.
    try:
        args = (path / "cmdline").read_bytes().split(b"\0")
        row["scripts"] = [arg.decode(errors="replace") for arg in args
                          if arg.endswith((b".py", b".sh")) and not arg.startswith(b"-")]
    except OSError:
        row["scripts"] = []
    # Discard a sample if this PID was reused during collection.
    end = read(path / "stat").rsplit(")", 1)[1].split()
    return row if end[19] == stat[19] else None


def snapshot(root, boot_id):
    began = time.monotonic()
    result = {"utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "boot_id": boot_id, "processes": [], "skipped": 0,
              "uptime_seconds": float(read(root / "uptime").split()[0])}
    meminfo = fields(root / "meminfo")
    result["meminfo_KiB"] = {k: number(meminfo, k) for k in
                            ("MemTotal", "MemAvailable", "AnonPages", "Cached", "Dirty",
                             "Writeback", "Slab", "SwapTotal", "SwapFree")}
    result["loadavg"] = read(root / "loadavg")
    for path in root.iterdir():
        if not path.name.isdigit():
            continue
        try:
            row = process(path)
            if row is not None:
                result["processes"].append(row)
        except (OSError, ValueError, IndexError):
            result["skipped"] += 1
    for name in ("memory", "io", "cpu"):
        try:
            result["pressure_" + name] = read(root / "pressure" / name)
        except OSError:
            pass
    result["processes"].sort(key=lambda p: p["RssAnon_KiB"] or 0, reverse=True)
    result["scan_seconds"] = round(time.monotonic() - began, 4)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default=str(Path(__file__).resolve().parent / "diagnostics/memory-watch"))
    parser.add_argument("--interval", type=float, default=5)
    parser.add_argument("--keep-boots", type=int, default=3)
    parser.add_argument("--samples", type=int, default=0, help="0 means continuous")
    parser.add_argument("--proc-root", default="/proc")
    args = parser.parse_args()
    if not 1 <= args.interval <= 3600:
        parser.error("interval must be between 1 and 3600 seconds")
    if args.keep_boots < 1:
        parser.error("keep-boots must be at least 1")
    os.umask(0o077)
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    lock = (output / "collector.lock").open("a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit("A recorder is already running for this output directory")
    root = Path(args.proc_root)
    boot_id = read(root / "sys/kernel/random/boot_id")
    boot_output = prepare_boot(output, boot_id, args.keep_boots, {"interval": args.interval})
    handler = DurableRotatingHandler(
        boot_output / "samples.jsonl", maxBytes=32 * 1024 * 1024, backupCount=7)
    handler.setFormatter(logging.Formatter("%(message)s"))
    logger = logging.getLogger("memory-watch")
    logger.setLevel(logging.INFO)
    logger.addHandler(handler)
    running = True

    def stop(*unused):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    count = 0
    print("Recording to", boot_output, "every", args.interval, "seconds", flush=True)
    try:
        while running:
            began = time.monotonic()
            logger.info(json.dumps(snapshot(root, boot_id), ensure_ascii=True, separators=(",", ":")))
            handler.flush()
            os.fsync(handler.stream.fileno())
            count += 1
            if args.samples and count >= args.samples:
                break
            remaining = args.interval - (time.monotonic() - began)
            while running and remaining > 0:
                time.sleep(min(remaining, 0.25))
                remaining = args.interval - (time.monotonic() - began)
    finally:
        handler.close()
        lock.close()


if __name__ == "__main__":
    main()
