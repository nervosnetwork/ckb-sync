#!/bin/bash

# 用法：
#   bash sync.sh main 0   # mainnet，不重启
#   bash sync.sh test 1   # testnet，重启

NET="$1"
RESTART_FLAG="$2"

if [[ "$NET" != "main" && "$NET" != "test" ]]; then
	echo "用法: bash sync.sh [main|test] [0|1]"
	exit 1
fi

if [[ "$RESTART_FLAG" != "0" && "$RESTART_FLAG" != "1" ]]; then
	echo "第二个参数必须是 0 或 1：0=without_restart，1=restart result"
	exit 1
fi

# 0x0000000000000000000000000000000000000000000000000000000000000000
mainnet_assume_valid_target=""
testnet_assume_valid_target=""

# -------- 仅杀掉目标网络端口上的 ckb --------
kill_ckb_by_port() {
	local port="$1" label="$2"
	if [[ -z "$port" || ! "$port" =~ ^[0-9]+$ ]]; then
		echo "$(TZ='Asia/Shanghai' date "+%Y-%m-%d %H:%M:%S") [WARN] $label: invalid port '$port', skip kill"
		return 0
	fi
	local pids
	pids=$(sudo lsof -ti:"$port" 2>/dev/null || true)
	if [[ -n "$pids" ]]; then
		for i in $pids; do
			echo "$(TZ='Asia/Shanghai' date "+%Y-%m-%d %H:%M:%S") killed the $label ckb $i"
			sudo kill "$i" || true
		done
	fi
}

# -------- 选择网络相关参数 --------
if [[ "$NET" == "main" ]]; then
	LABEL="mainnet"
	RPC_PORT=8114
	METRICS_PORT=8100
	ASSUME_VALID_TARGET="$mainnet_assume_valid_target"
else
	LABEL="testnet"
	RPC_PORT=8124
	METRICS_PORT=8102
	ASSUME_VALID_TARGET="$testnet_assume_valid_target"
fi

# 先杀掉目标网络
kill_ckb_by_port "$RPC_PORT" "$LABEL"
sleep 2

# -------- 获取并解包 CKB --------
ckb_version=$(
	curl -s https://api.github.com/repos/nervosnetwork/ckb/releases |
		jq -r '.[] | select(.tag_name | startswith("v0.206")) |
      {tag_name, published_at} | "\(.published_at) \(.tag_name)"' |
		sort | tail -n 1 | cut -d " " -f2
)
echo "Latest CKB version: $ckb_version"
tar_name="ckb_${ckb_version}_x86_64-unknown-linux-gnu.tar.gz"

if [ ! -f "$tar_name" ]; then
	wget -q "https://github.com/nervosnetwork/ckb/releases/download/${ckb_version}/${tar_name}"
fi

# 仅清理本次要用到的网络目录（包含历史的），避免无谓删除另一网络目录
if [[ "$NET" == "main" ]]; then
	sudo rm -rf mainnet_ckb_*_x86_64-unknown-linux-gnu
else
	sudo rm -rf testnet_ckb_*_x86_64-unknown-linux-gnu
fi

# 解包一次，然后拷贝/移动出目标目录
sudo rm -rf "ckb_${ckb_version}_x86_64-unknown-linux-gnu"
tar xzf "${tar_name}"
rm -f "${tar_name}"

if [[ "$NET" == "main" ]]; then
	cp -r "ckb_${ckb_version}_x86_64-unknown-linux-gnu" "mainnet_ckb_${ckb_version}_x86_64-unknown-linux-gnu"
else
	mv "ckb_${ckb_version}_x86_64-unknown-linux-gnu" "testnet_ckb_${ckb_version}_x86_64-unknown-linux-gnu"
fi

# -------- 测试报告result文件名逻辑 --------
start_day=$(TZ='Asia/Shanghai' date "+%Y-%m-%d")
if [[ "$RESTART_FLAG" == "0" ]]; then
  result_log="without_restart_result_${start_day}.log"
  other_log="result_${start_day}.log"
else
  result_log="result_${start_day}.log"
  other_log="without_restart_result_${start_day}.log"
fi

# 当天的result文件都要删掉
for f in "$result_log" "$other_log"; do
  if [[ -e "$f" ]]; then
    rm -f -- "$f"
    echo "$f 已被删除"
  fi
done

if [[ "$NET" == "main" ]]; then
	"./mainnet_ckb_${ckb_version}_x86_64-unknown-linux-gnu/ckb" --version >"$result_log"
else
	"./testnet_ckb_${ckb_version}_x86_64-unknown-linux-gnu/ckb" --version >"$result_log"
fi

# -------- 初始化 & 修改 ckb.toml --------
if [[ "$NET" == "main" ]]; then
	cd "mainnet_ckb_${ckb_version}_x86_64-unknown-linux-gnu" || exit 1

	sudo ./ckb init --chain mainnet --force
	echo "------------------------------------------------------------"
	grep 'spec =' ckb.toml
	grep 'spec =' ckb.toml | cut -d'/' -f2 | cut -d'.' -f1 >>../"$result_log"

	grep "^listen_address =" ckb.toml
	sed -i 's/^listen_address = .*/listen_address = "0.0.0.0:8114"/' ckb.toml
	grep "^listen_address =" ckb.toml

	grep "^modules =" ckb.toml
	sed -i '/^modules = .*/s/\]/, "Indexer"]/' ckb.toml
	grep "^modules =" ckb.toml

	config_content="
[metrics.exporter.prometheus]
target = { type = \"prometheus\", listen_address = \"0.0.0.0:${METRICS_PORT}\" }

# # Experimental: Monitor memory changes.
[memory_tracker]
# # Seconds between checking the process, 0 is disable, default is 0.
interval = 5
"
	echo "$config_content" >>ckb.toml
	tail -n 8 ckb.toml

	cd ..

else
	cd "testnet_ckb_${ckb_version}_x86_64-unknown-linux-gnu" || exit 1

	sudo ./ckb init --chain testnet --force
	echo "------------------------------------------------------------"
	grep 'spec =' ckb.toml
	grep 'spec =' ckb.toml | cut -d'/' -f2 | cut -d'.' -f1 >>../"$result_log"

	grep "^listen_address =" ckb.toml
	sed -i 's/^listen_address = .*/listen_address = "0.0.0.0:8124"/' ckb.toml
	grep "^listen_address =" ckb.toml

	# listen_addresses 改 8115 -> 8125 （保持你的逻辑）
	grep "^listen_addresses" ckb.toml
	sed -i '/listen_addresses/s/8115/8125/' ckb.toml
	grep "^listen_addresses" ckb.toml

	grep "^modules =" ckb.toml
	sed -i '/^modules = .*/s/\]/, "Indexer"]/' ckb.toml
	grep "^modules =" ckb.toml

	config_content="
[metrics.exporter.prometheus]
target = { type = \"prometheus\", listen_address = \"0.0.0.0:${METRICS_PORT}\" }

# # Experimental: Monitor memory changes.
[memory_tracker]
# # Seconds between checking the process, 0 is disable, default is 0.
interval = 5
"
	echo "$config_content" >>ckb.toml
	tail -n 8 ckb.toml

	cd ..
fi

echo "rich-indexer type: Not Enabled" >>"$result_log"

# -------- 启动目标网络节点 --------
echo "$(TZ='Asia/Shanghai' date "+%Y-%m-%d %H:%M:%S") start ${LABEL} ckb node"
if [[ "$NET" == "main" ]]; then
	sudo chown -R "$USER:$USER" "mainnet_ckb_${ckb_version}_x86_64-unknown-linux-gnu"
	cd "mainnet_ckb_${ckb_version}_x86_64-unknown-linux-gnu" || exit 1

	if [ -z "${ASSUME_VALID_TARGET}" ]; then
		# https://github.com/nervosnetwork/ckb/blob/pkg/v0.203.0/util/constant/src/latest_assume_valid_target.rs
		setsid -f ./ckb run >/dev/null 2>&1 </dev/null
		echo "mainnet assume-valid-target: default" >>"$result_log"
	else
		setsid -f ./ckb run --assume-valid-target "$ASSUME_VALID_TARGET" >/dev/null 2>&1 &
		echo "mainnet assume-valid-target: ${ASSUME_VALID_TARGET}" >>"$result_log"
	fi
	cd ..

else
	sudo chown -R "$USER:$USER" "testnet_ckb_${ckb_version}_x86_64-unknown-linux-gnu"
	cd "testnet_ckb_${ckb_version}_x86_64-unknown-linux-gnu" || exit 1

	if [ -z "${ASSUME_VALID_TARGET}" ]; then
		setsid -f ./ckb run >/dev/null 2>&1 &
		echo "testnet assume-valid-target: default" >>"$result_log"
	else
		setsid -f ./ckb run --assume-valid-target "$ASSUME_VALID_TARGET" >/dev/null 2>&1 &
		echo "testnet assume-valid-target: ${ASSUME_VALID_TARGET}" >>"$result_log"
	fi
	cd ..
fi

# -------- 机器信息 & 同步起始时间 --------
echo "$(grep -c ^processor /proc/cpuinfo)C$(free -h | grep Mem | awk '{print $2}' | sed 's/Gi//')G    $(lsb_release -d | sed 's/Description:\s*//')    $(lscpu | grep "Model name" | cut -d ':' -f2 | xargs)" >>"$result_log"
sync_start=$(TZ='Asia/Shanghai' date "+%Y-%m-%d %H:%M:%S")
echo "sync_start: ${sync_start}" >>"$result_log"
