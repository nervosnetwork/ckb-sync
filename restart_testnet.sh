#!/bin/bash

PORT=8124
testnet_assume_valid_target=""

kill_test_ckb() {
	PIDS=$(sudo lsof -ti:${PORT})
	for i in $PIDS; do
		echo "$(TZ='Asia/Shanghai' date "+%Y-%m-%d %H:%M:%S") killed the test ckb $i"
		sudo kill $i
	done
}

kill_test_ckb

cd testnet_ckb_*_x86_64-unknown-linux-gnu || exit
RUN_USER="${SUDO_USER:-$USER}"
RUN_GROUP=$(id -gn "$RUN_USER")
sudo chown "$RUN_USER:$RUN_GROUP" .
if [[ -d data ]]; then
	sudo chown -R "$RUN_USER:$RUN_GROUP" data
fi
if [ -z "${testnet_assume_valid_target}" ]; then
	setsid -f ./ckb run >/dev/null 2>&1 &
else
	setsid -f ./ckb run --assume-valid-target "$testnet_assume_valid_target" >/dev/null 2>&1 &
fi
