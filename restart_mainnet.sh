#!/bin/bash

PORT=8114
mainnet_assume_valid_target=""

kill_main_ckb() {
	PIDS=$(sudo lsof -ti:${PORT})
	for i in $PIDS; do
		echo "$(TZ='Asia/Shanghai' date "+%Y-%m-%d %H:%M:%S") killed the main ckb $i"
		sudo kill $i
	done
}

kill_main_ckb

cd mainnet_ckb_*_x86_64-unknown-linux-gnu || exit
if [ -z "${mainnet_assume_valid_target}" ]; then
	setsid -f ./ckb run >/dev/null 2>&1 &
else
	setsid -f ./ckb run --assume-valid-target "$mainnet_assume_valid_target" >/dev/null 2>&1 &
fi
