#!/bin/bash
set -e

# 不带参数：正常重启；参数 0：使用全零 assume-valid-target。
if [[ $# -gt 1 || ( $# -eq 1 && $1 != 0 ) ]]; then
    echo "用法: bash restart_mainnet.sh [0]" >&2
    exit 1
fi
CMD=(./ckb run)
if [[ ${1:-} == 0 ]]; then
    CMD+=(--assume-valid-target 0x0000000000000000000000000000000000000000000000000000000000000000)
fi

# 先确认目录和版本，再停止旧节点。
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
NODE_DIRS=(mainnet_ckb_*_x86_64-unknown-linux-gnu)
if [[ ${#NODE_DIRS[@]} -ne 1 || ! -d ${NODE_DIRS[0]} ]]; then
    echo "需要且只能有一个 mainnet 节点目录" >&2
    exit 1
fi
cd -- "${NODE_DIRS[0]}"
./ckb --version

PIDS=$(sudo lsof -t -a -iTCP:8114 -sTCP:LISTEN || true)
for pid in $PIDS; do
    echo "停止 CKB PID=$pid"
    sudo kill "$pid"
done
for pid in $PIDS; do
    while sudo kill -0 "$pid" 2>/dev/null; do sleep 1; done
done

RUN_USER=${SUDO_USER:-$USER}
RUN_GROUP=$(id -gn "$RUN_USER")
sudo chown "$RUN_USER:$RUN_GROUP" .
if [[ -d data ]]; then
    sudo chown -R "$RUN_USER:$RUN_GROUP" data
fi

echo "目录: $PWD"
echo "启动命令: ${CMD[*]}"
sudo -u "$RUN_USER" setsid -f "${CMD[@]}" >/dev/null 2>&1 </dev/null
