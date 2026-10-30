# Linux sync-test memory recording

The recorder is part of the Linux sync test, using Python 3's standard library
and systemd. Install `python3`, `util-linux` (`findmnt`/`flock`) and systemd if they
are not already present. Run the management commands from the repository root.
It reads all user processes, because another process can affect the CKB test.
It does not invoke the report/Discord scripts or change CKB settings.

## Start, configure, and verify

`run.sh`, `sync.sh`, `restart_mainnet.sh`, and `restart_testnet.sh` call
`memory_watch.sh start`. Starting an active recorder does not restart it or create
a second recorder. Both networks share `ckb-sync-memory-watch.service`. A failure
prints a warning and the CKB test continues, so verify recording before reproducing
a failure. The default cron entry in the README invokes `run.sh`.

To attach to an already running test:

```bash
sudo bash memory_watch.sh start
sudo bash memory_watch.sh status
sudo journalctl -u ckb-sync-memory-watch.service -n 20 --no-pager
```

For host-specific settings, copy `memory_watch.conf.example` to
`memory_watch.conf` and edit it. The latter is ignored by Git and is sourced as
Bash configuration. Defaults:

| Setting | Default | Meaning |
| --- | --- | --- |
| `CKB_MEMORY_WATCH_ENABLED` | `1` | Set `0` to skip automatic starts |
| `CKB_MEMORY_WATCH_INTERVAL` | `5` | Seconds between scans, range 1–3600 |
| `CKB_MEMORY_WATCH_KEEP_BOOTS` | `3` | Boot directories retained, including current boot |
| `CKB_MEMORY_WATCH_DIR` | Repository `diagnostics/memory-watch/` | Absolute persistent output path |

The shell rejects temporary paths and tmpfs/ramfs output mounts. Use a local
persistent disk. The default is outside the per-network CKB directories that
`sync.sh` deletes. All diagnostic data is ignored by Git and files created by the
collector are readable only by root. Do not run `git clean -fdx` over diagnostics.

Configuration is read when the service starts. Apply changes with:

```bash
sudo bash memory_watch.sh stop
sudo bash memory_watch.sh start
```

Setting `ENABLED=0` alone does not stop an existing recorder; stop it explicitly.
If the earlier temporary `ckb-memory-watch.service` is still running, stop that
service before starting this recorder to avoid duplicate work.

After about 10 seconds, verify that samples advance (adjust the directory if
configured differently):

```bash
boot_id=$(cat /proc/sys/kernel/random/boot_id)
sudo tail -n 1 "diagnostics/memory-watch/boot-$boot_id/samples.jsonl" |
python3 -c '
import json, sys
d = json.load(sys.stdin)
print("UTC:", d["utc"], "processes:", len(d["processes"]),
      "scan seconds:", d["scan_seconds"])
for p in d["processes"][:10]:
    print(p["pid"], p["name"], (p["RssAnon_KiB"] or 0)/1024,
          "MiB anonymous", p["exe"], p["scripts"])
'
```

## Recorded data and overhead

Each line in `samples.jsonl` is a complete JSON snapshot, timestamped in UTC.
Use `boot_id`, `pid`, and `start_ticks` together to identify a process across PID
reuse. `metadata.json` records the clock-tick rate for CPU/start counters.

- Per process: anonymous/file/shared RSS, total RSS, swap, peak RSS, parent PID,
  thread count, state, CPU ticks, executable, working directory, script filenames,
  cgroup (service/container attribution), and cumulative I/O counters.
- Per host: available/anonymous memory, cache, dirty/writeback pages, swap, load,
  uptime, and CPU/memory/I/O pressure where supported.
- Collection quality: scan duration and count of processes skipped (for example,
  because they exited during the scan). Unavailable optional fields are null.

Full command arguments, environment variables, and script contents are not
recorded. I/O counters are cumulative; compare successive samples for the same
process identity. `RssAnon` is an approximate resident-memory statistic; shared
pages after fork can be counted in multiple processes. Do not treat summed RSS
as an exact host memory total. See the
[Linux /proc documentation](https://docs.kernel.org/filesystems/proc.html).

Five seconds is a useful starting point for the observed approximately 30-second,
4 GiB rise. It yields several samples without scanning every process every second.
Use one second for brief spikes, then restore five seconds for longer sync tests.
Processes that start and exit between scans can still be missed; this is not a
complete process-execution audit. Reads are sequential, not an atomic host snapshot.
Review `scan_seconds`, service CPU/memory usage, and log growth on the actual host;
no Linux-host performance benchmark is implied by the default. Sampling waits if a
scan/write takes longer than the requested interval instead of overlapping scans.

The service has a 128 MiB memory limit and CPU nice level 10. Each sample is flushed
and `fsync` is requested. This adds disk I/O and cannot guarantee the last sample
survives a storage failure or that sampling continues while the host is stalled.
To compare performance baselines, use the same collector settings on both runs.

## Retention, restart, and export

Each boot gets `boot-<Linux boot ID>/` with a current file plus seven rotated files
(`samples.jsonl.1` is the newest rotated file). Files rotate at approximately
32 MiB, so each boot retains approximately 256 MiB, and three boots approximately
768 MiB. Retention is by size, not a guaranteed number of hours. Many processes or
a shorter interval reduce the retained time. On startup, only older boot directories
marked as belonging to this collector are pruned. An active boot continues its
existing ring instead of truncating it.

The transient systemd service survives SSH disconnection and CKB restarts, but
does not auto-start at machine boot. The next invocation of `run.sh` or another
test entry point starts it for the new boot. The previous boot's files remain
separate. For immediate boot-time collection a persistent systemd unit would be
needed; this test integration does not install one.

After a hang, recover access and export promptly. Stop collection before making a
consistent archive; prevent scheduled starts while exporting if a cron boundary
is imminent. Use your configured output path if it differs from the default:

```bash
# After reboot the transient unit may not exist; that is expected.
sudo bash memory_watch.sh stop
archive="diagnostics/ckb-memory-watch-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
sudo tar -czf - -C diagnostics memory-watch > "$archive"
ls -lh "$archive"
```

Archive files are outside the recorder's rotation and must be managed separately.
Resume collection with `sudo bash memory_watch.sh start` after preserving evidence.
When testing is finished, stop the service and set `CKB_MEMORY_WATCH_ENABLED=0`
in `memory_watch.conf` to prevent the test cron job from starting it again.

## Local verification

```bash
python3 -m unittest discover -s tests -p 'test_memory_watch.py'
bash -n memory_watch.sh run.sh sync.sh restart_mainnet.sh restart_testnet.sh
```

Tests use a synthetic `/proc` tree and temporary output directory. They do not
start services, kill processes, download CKB, or send test reports.
