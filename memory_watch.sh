#!/bin/bash
# Manage the host-wide recorder. No CKB processes are started or stopped here.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ -f "$SCRIPT_DIR/memory_watch.conf" ]]; then
    source "$SCRIPT_DIR/memory_watch.conf"
fi
ACTION=${1:-status}
UNIT=ckb-sync-memory-watch.service
ENABLED=${CKB_MEMORY_WATCH_ENABLED:-1}
INTERVAL=${CKB_MEMORY_WATCH_INTERVAL:-5}
KEEP_BOOTS=${CKB_MEMORY_WATCH_KEEP_BOOTS:-3}
OUTPUT=${CKB_MEMORY_WATCH_DIR:-"$SCRIPT_DIR/diagnostics/memory-watch"}

case "$ACTION" in
    start|stop|status) ;;
    *) echo "Usage: bash memory_watch.sh [start|stop|status]" >&2; exit 2 ;;
esac
if [[ "$ACTION" == start && "$ENABLED" == 0 ]]; then
    echo "[memory-watch] Disabled; an already-running recorder is not stopped."
    exit 0
fi
if [[ $(uname -s) != Linux ]]; then
    echo "[memory-watch] Linux with systemd is required." >&2
    exit 1
fi
if [[ $EUID -ne 0 ]]; then
    exec sudo env CKB_MEMORY_WATCH_ENABLED="$ENABLED" \
        CKB_MEMORY_WATCH_INTERVAL="$INTERVAL" CKB_MEMORY_WATCH_KEEP_BOOTS="$KEEP_BOOTS" \
        CKB_MEMORY_WATCH_DIR="$OUTPUT" bash "$SCRIPT_DIR/memory_watch.sh" "$ACTION"
fi

case "$ACTION" in
    stop)
        systemctl stop "$UNIT"
        ;;
    status)
        systemctl status "$UNIT" --no-pager
        ;;
    start)
        command -v python3 >/dev/null
        command -v systemd-run >/dev/null
        command -v findmnt >/dev/null
        [[ "$OUTPUT" == /* ]] || { echo "[memory-watch] Output must be an absolute path." >&2; exit 1; }
        python3 - "$INTERVAL" "$KEEP_BOOTS" <<'PY'
import sys
if not 1 <= float(sys.argv[1]) <= 3600 or int(sys.argv[2]) < 1:
    raise SystemExit("Invalid memory-watch interval or boot retention")
PY
        mkdir -p -- "$OUTPUT"
        OUTPUT=$(cd -- "$OUTPUT" && pwd -P)
        case "$OUTPUT/" in
            /tmp/*|/var/tmp/*|/run/*)
                echo "[memory-watch] Use a persistent directory outside /tmp, /var/tmp and /run." >&2
                exit 1 ;;
        esac
        FS_TYPE=$(findmnt -n -o FSTYPE -T "$OUTPUT")
        case "$FS_TYPE" in
            tmpfs|ramfs)
                echo "[memory-watch] $OUTPUT is on $FS_TYPE; use a persistent disk." >&2
                exit 1 ;;
        esac
        # Serialize cron/manual starts across both networks and repository paths.
        exec 9>/run/ckb-sync-memory-watch-control.lock
        flock -x 9
        if systemctl is-active --quiet "$UNIT"; then
            echo "[memory-watch] Already active; configuration changes require stop/start."
            exit 0
        fi
        systemctl reset-failed "$UNIT" 2>/dev/null || true
        systemd-run --unit="$UNIT" --service-type=exec \
            --property=Restart=on-failure --property=RestartSec=10 \
            --property=MemoryMax=128M --property=Nice=10 \
            "$(command -v python3)" "$SCRIPT_DIR/memory_watch.py" \
            --output "$OUTPUT" --interval "$INTERVAL" --keep-boots "$KEEP_BOOTS"
        echo "[memory-watch] Logs: $OUTPUT (one directory per boot)"
        ;;
esac
