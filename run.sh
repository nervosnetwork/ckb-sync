#!/bin/bash

PORT_MAINNET=8114
PORT_TESTNET=8124

if [[ ! -f env.txt ]]; then
	echo "1" >env.txt
	echo "1" >>env.txt
	echo "[info] env.txt not found, created with default values:"
	cat env.txt
fi

mode=$(sed -n '1p' env.txt)
is_exec=$(sed -n '2p' env.txt)

current_time=$(TZ='Asia/Shanghai' date "+%Y-%m-%d %H:%M:%S")

kill_ckb() {
	local port="$1"
	local pids
	# 只抓监听者
	pids=$(sudo lsof -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | sort -u)

	if [[ -z "$pids" ]]; then
		echo "$(TZ='Asia/Shanghai' date "+%Y-%m-%d %H:%M:%S") no process found on port $port"
		return 0
	fi

	sudo kill $pids 2>/dev/null # ← 不要加引号
	sleep 10

	local still_alive
	still_alive=$(sudo lsof -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | sort -u)
	if [[ -n "$still_alive" ]]; then
		echo "$(TZ='Asia/Shanghai' date "+%Y-%m-%d %H:%M:%S") still alive → force killing..."
		sudo kill -9 $still_alive 2>/dev/null # ← 不要加引号
	fi

	if sudo lsof -t -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
		echo "$(TZ='Asia/Shanghai' date "+%Y-%m-%d %H:%M:%S") WARNING: port $port still occupied after kill attempts"
	else
		echo "$(TZ='Asia/Shanghai' date "+%Y-%m-%d %H:%M:%S") done killing processes on port $port"
	fi
}

if [[ "$is_exec" == "0" ]]; then
	case "$mode" in
	1 | 2)
		echo "$current_time No restart for ckb in this test round"
		exit 0
		;;
	3 | 4)
		kill_ckb "$PORT_MAINNET"
		kill_ckb "$PORT_TESTNET"

		if [[ "$mode" == "3" ]]; then
			cd mainnet_ckb_*_x86_64-unknown-linux-gnu || exit
			sleep 180
			setsid -f ./ckb run >/dev/null 2>&1 </dev/null
		else
			cd testnet_ckb_*_x86_64-unknown-linux-gnu || exit
			sleep 180
			setsid -f ./ckb run >/dev/null 2>&1 </dev/null
		fi
		exit 0
		;;
	*) ;;
	esac
fi

kill_ckb $PORT_MAINNET
kill_ckb $PORT_TESTNET

case "$mode" in
1)
	echo "$current_time Run mode=1 → bash sync.sh main 0"
	bash sync.sh main 0
	;;
2)
	echo "$current_time Run mode=2 → bash sync.sh test 0"
	bash sync.sh test 0
	;;
3)
	echo "$current_time Run mode=3 → bash sync.sh main 1"
	bash sync.sh main 1
	;;
4)
	echo "$current_time Run mode=4 → bash sync.sh test 1"
	bash sync.sh test 1
	;;
*)
	echo "$current_time Invalid mode: $mode (should be 1~4)"
	exit 1
	;;
esac

sed -i '2s/.*/0/' env.txt
echo "[info] Updated env.txt → set is_exec to 0"
