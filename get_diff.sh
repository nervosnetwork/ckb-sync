#!/bin/bash

current_day=$(TZ='Asia/Shanghai' date "+%Y-%m-%d")

if [[ -e "diff_${current_day}.log" && ! -w "diff_${current_day}.log" ]]; then
	sudo chown "$USER":"$(id -gn)" "diff_${current_day}.log" 2>/dev/null || true
	chmod u+rw "diff_${current_day}.log" 2>/dev/null || true
fi

# echo mainnet msg
localhost_hex_height=$(curl -sS -X POST -H "Content-Type: application/json" -d '{"id": 1, "jsonrpc": "2.0", "method": "get_tip_header", "params": []}' http://localhost:8114 | jq -r '.result.number' | sed 's/^0x//')
if [[ $? -ne 0 || -z "$localhost_hex_height" ]]; then
	localhost_height="获取失败"
else
	localhost_height=$((16#$localhost_hex_height))
fi

indexer_tip_hex=$(curl -sS -X POST -H "Content-Type: application/json" -d '{"id": 1, "jsonrpc": "2.0", "method": "get_indexer_tip", "params": []}' http://localhost:8114 | jq -r '.result.block_number' | sed 's/^0x//')
if [[ $? -ne 0 || -z "$indexer_tip_hex" ]]; then
	indexer_tip="获取失败"
else
	indexer_tip=$((16#$indexer_tip_hex))
fi

latest_hex_height=$(curl -sS -X POST -H "Content-Type: application/json" -d '{"id": 1, "jsonrpc": "2.0", "method": "get_tip_header", "params": []}' https://mainnet.ckbapp.dev | jq -r '.result.number' | sed 's/^0x//')
if [[ $? -ne 0 || -z "$latest_hex_height" ]]; then
	latest_height="获取失败"
else
	latest_height=$((16#$latest_hex_height))
fi

# 计算本地indexer_tip和最新区块高度差值或指出无法计算
if [[ $indexer_tip =~ ^[0-9]+$ && $latest_height =~ ^[0-9]+$ ]]; then
	difference=$(($latest_height - $indexer_tip))
	if [[ $difference -lt 0 ]]; then
		difference=$((-$difference)) # 转换为绝对值
	fi
	sync_rate=$(echo "scale=10; $indexer_tip * 100 / $latest_height" | bc | awk '{printf "%.2f\n", $0}')
	sync_rate="${sync_rate}%"
	height_sync_rate=$(echo "scale=10; $localhost_height * 100 / $latest_height" | bc | awk '{printf "%.2f\n", $0}')
	height_sync_rate="${height_sync_rate}%"

else
	difference="无法计算"
	sync_rate="无法计算"
fi

if [[ "$localhost_height" != "获取失败" && "$indexer_tip" != "获取失败" ]]; then
	echo "$(TZ='Asia/Shanghai' date "+%Y-%m-%d %H:%M:%S") height: ${localhost_height} indexer_tip: ${indexer_tip} mainnet_height: ${latest_height} difference: ${difference} height_sync_rate: ${height_sync_rate} sync_rate: ${sync_rate}" >>"diff_${current_day}.log"
fi

# echo testnet msg
testnet_localhost_hex_height=$(curl -sS -X POST -H "Content-Type: application/json" -d '{"id": 1, "jsonrpc": "2.0", "method": "get_tip_header", "params": []}' http://localhost:8124 | jq -r '.result.number' | sed 's/^0x//')
if [[ $? -ne 0 || -z "$testnet_localhost_hex_height" ]]; then
	testnet_localhost_height="获取失败"
else
	testnet_localhost_height=$((16#$testnet_localhost_hex_height))
fi

testnet_indexer_tip_hex=$(curl -sS -X POST -H "Content-Type: application/json" -d '{"id": 1, "jsonrpc": "2.0", "method": "get_indexer_tip", "params": []}' http://localhost:8124 | jq -r '.result.block_number' | sed 's/^0x//')
if [[ $? -ne 0 || -z "$testnet_indexer_tip_hex" ]]; then
	testnet_indexer_tip="获取失败"
else
	testnet_indexer_tip=$((16#$testnet_indexer_tip_hex))
fi

testnet_latest_hex_height=$(curl -sS -X POST -H "Content-Type: application/json" -d '{"id": 1, "jsonrpc": "2.0", "method": "get_tip_header", "params": []}' https://testnet.ckbapp.dev | jq -r '.result.number' | sed 's/^0x//')
if [[ $? -ne 0 || -z "$testnet_latest_hex_height" ]]; then
	testnet_latest_height="获取失败"
else
	testnet_latest_height=$((16#$testnet_latest_hex_height))
fi

if [[ $testnet_indexer_tip =~ ^[0-9]+$ && $testnet_latest_height =~ ^[0-9]+$ ]]; then
	testnet_difference=$(($testnet_latest_height - $testnet_indexer_tip))
	if [[ $testnet_difference -lt 0 ]]; then
		testnet_difference=$((-$testnet_difference))
	fi
	sync_rate=$(echo "scale=10; $testnet_indexer_tip * 100 / $testnet_latest_height" | bc | awk '{printf "%.2f\n", $0}')
	sync_rate="${sync_rate}%"
	height_sync_rate=$(echo "scale=10; $testnet_localhost_height * 100 / $testnet_latest_height" | bc | awk '{printf "%.2f\n", $0}')
	height_sync_rate="${height_sync_rate}%"

else
	testnet_difference="无法计算"
	sync_rate="无法计算"
fi

if [[ "$testnet_localhost_height" != "获取失败" && "$testnet_indexer_tip" != "获取失败" ]]; then
	echo "$(TZ='Asia/Shanghai' date "+%Y-%m-%d %H:%M:%S") height: ${testnet_localhost_height} indexer_tip: ${testnet_indexer_tip} testnet_height: ${testnet_latest_height} difference: ${testnet_difference} height_sync_rate: ${height_sync_rate} sync_rate: ${sync_rate}" >>diff_${current_day}.log
fi

result_log=$(
	ls -1 {without_restart_result_,result_}*.log 2>/dev/null |
		awk -F'[_ .]' '{d=$(NF-1); print d, $0}' |
		sort -k1,1 |
		tail -n1 |
		cut -d' ' -f2-
)

# 检查sync_end是否存在，并且差值小于总高度的1%
finalize_sync() {
	local net="$1"                # mainnet / testnet
	local diff_val="$2"           # 对应网络的 difference 数值
	local log_file="$3"           # 日志文件路径
	local threshold="${4:-13000}" # 允许的阈值，默认 13000

	if ! grep -q "${net} sync_end" "$log_file" &&
		[[ "$diff_val" =~ ^[0-9]+$ ]] &&
		[[ "$diff_val" -lt "$threshold" ]]; then

		local sync_end sync_start start_sec end_sec diff_sec
		local days hours minutes seconds

		sync_end=$(TZ='Asia/Shanghai' date "+%Y-%m-%d %H:%M:%S")

		# 根据 mainnet / testnet 选择当前高度与 indexer_tip 变量
		local curr_height curr_tip
		if [[ "$net" == "testnet" ]]; then
			curr_height="$testnet_localhost_height"
			curr_tip="$testnet_indexer_tip"
		else
			curr_height="$localhost_height"
			curr_tip="$indexer_tip"
		fi
		echo "${net} sync_end: ${sync_end}（当前高度：$curr_height,当前indexer_tip: $curr_tip)" >>"$log_file"

		# 读取并计算耗时（若未找到 sync_start 则跳过耗时统计，避免脚本退出）
		sync_start=$(grep 'sync_start' "$log_file" | cut -d' ' -f2-)
		if [[ -n "$sync_start" ]]; then
			start_sec=$(date -d "$sync_start" +%s)
			end_sec=$(date -d "$sync_end" +%s)
			diff_sec=$((end_sec - start_sec))

			days=$((diff_sec / 86400))
			hours=$(((diff_sec % 86400) / 3600))
			minutes=$(((diff_sec % 3600) / 60))
			seconds=$((diff_sec % 60))

			echo "${net}同步到最新indexer高度耗时: ${days}天 ${hours}小时 ${minutes}分钟 ${seconds}秒" >>"$log_file"
		fi
	fi
}

finalize_sync "mainnet" "$difference" "$result_log"
finalize_sync "testnet" "$testnet_difference" "$result_log"

# --- 写死端口 ---
PORT_MAINNET=8114
PORT_TESTNET=8124

# $1=port  $2=label(mainnet/testnet)
kill_ckb() {
	local port="$1" label="$2"
	# 防止出现 lsof: unacceptable port specification（变量为空或非法）
	if [[ -z "$port" || ! "$port" =~ ^[0-9]+$ ]]; then
		echo "$(TZ='Asia/Shanghai' date "+%Y-%m-%d %H:%M:%S") [WARN] $label: invalid port '$port', skip kill"
		return 0
	fi

	# -i:PORT 写法必须保证port不为空
	local pids
	pids=$(sudo lsof -ti:"$port") || true
	if [[ -n "$pids" ]]; then
		for i in $pids; do
			echo "$(TZ='Asia/Shanghai' date "+%Y-%m-%d %H:%M:%S") killed the $label ckb $i"
			sudo kill "$i" || true
		done
	fi
}

toggle_env() {
	local file="env.txt"
	if [[ ! -f "$file" ]]; then
		echo "[ERROR] $file not found"
		return 1
	fi

	# 读取第一行，去掉空白
	local first next
	first=$(sed -n '1p' "$file" | tr -d ' \t\r')

	case "$first" in
	1) next=2 ;;
	2) next=3 ;;
	3) next=4 ;;
	4) next=1 ;;
	*) next=1 ;; # 非1~4的值时重置为1
	esac

	# 更新第一行
	sed -i "1s/.*/$next/" "$file"

	# 确保第二行存在并设为1
	local lines
	lines=$(wc -l <"$file")
	if ((lines < 2)); then
		echo "1" >>"$file"
	else
		sed -i "2s/.*/1/" "$file"
	fi
}

# $1=label(mainnet/testnet)  $2=port
handle_sync_end_and_maybe_kill() {
	local label="$1" port="$2"

	# 仅当存在 “<label> sync_end” 且不存在 “<label> kill_time” 时处理
	if grep -q "$label sync_end" "$result_log" && ! grep -q "$label kill_time" "$result_log"; then
		# 取 sync_end 的时间字符串
		local sync_end_time_str
		sync_end_time_str=$(grep 'sync_end' "$result_log" | awk -F'sync_end: |（当前高度' '{print $2}' | head -n1)

		# 转 UTC 秒并按你原来的“减8小时”习惯校正
		local sync_end_timestamp_utc sync_end_timestamp current_timestamp time_diff
		sync_end_timestamp_utc=$(date -u -d "$sync_end_time_str" +%s 2>/dev/null || echo "")
		if [[ -z "$sync_end_timestamp_utc" ]]; then
			return 0
		fi
		sync_end_timestamp=$((sync_end_timestamp_utc - 8 * 3600))

		current_timestamp=$(TZ='Asia/Shanghai' date +%s)
		time_diff=$((current_timestamp - sync_end_timestamp))

		# 超过 3 小时(10800秒)则 kill 并记录
		if [[ $time_diff -ge 10800 ]]; then
			kill_ckb "$port" "$label"

			# 取 sync_start 并做同样的时区换算（毫秒，用于 Grafana 链接）
			local sync_start_time sync_start_timestamp_utc sync_start_timestamp
			sync_start_time=$(grep 'sync_start:' "$result_log" | head -n1 | cut -d' ' -f2-)
			sync_start_timestamp_utc=$(date -u -d "$sync_start_time" +%s 2>/dev/null || echo "")
			if [[ -n "$sync_start_timestamp_utc" ]]; then
				sync_start_timestamp=$(((sync_start_timestamp_utc - 8 * 3600) * 1000))
			else
				sync_start_timestamp=$(((current_timestamp - 10800) * 1000)) # 兜底给个近似窗口
			fi

			local curr_height curr_tip
			if [[ "$label" == "testnet" ]]; then
				curr_height="$testnet_localhost_height"
				curr_tip="$testnet_indexer_tip"
			else
				curr_height="$localhost_height"
				curr_tip="$indexer_tip"
			fi
			echo "$label kill_time: $(TZ='Asia/Shanghai' date "+%Y-%m-%d %H:%M:%S")（当前高度：$curr_height,当前indexer_tip: $curr_tip)" >>"$result_log"
			# 根据网络选择 Grafana 的 metrics 端口：mainnet=8100，testnet=8102
			local NODE_IP metrics_port
			NODE_IP=$(curl -4 -fsS https://ifconfig.me/ip 2>/dev/null || curl -4 -fsS https://ipv4.icanhazip.com 2>/dev/null || echo "127.0.0.1")
			NODE_IP=$(echo "$NODE_IP" | tr -d '[:space:]')
			if [[ "$label" == "mainnet" ]]; then
				metrics_port=8100
			else
				metrics_port=8102
			fi
			echo "详见: https://grafana-monitor.nervos.tech/d/pThsj6xVz/test?orgId=1&var-url=$NODE_IP:${metrics_port}&from=${sync_start_timestamp}&to=${current_timestamp}000" >>"$result_log"

			if [[ "$result_log" == without_restart_result* ]]; then
				python3 sendMsg.py "$result_log" .without_restart_env
			else
				python3 sendMsg.py "$result_log"
			fi
			toggle_env
		fi
	fi
}

# --- 调用（写死 mainnet / testnet 各自端口） ---
handle_sync_end_and_maybe_kill "mainnet" "$PORT_MAINNET"
handle_sync_end_and_maybe_kill "testnet" "$PORT_TESTNET"
