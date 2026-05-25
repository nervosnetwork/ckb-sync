## Usage
```bash
# Start or restart ckb every two hours.
20 */2 * * * cd /home/ckb/scz/ckb-sync && sudo bash sync.sh >> sync.log 2>&1
# Statistics are collected every 20 minutes.
10,30,50 * * * * cd /home/ckb/scz/ckb-sync && sudo bash get_diff.sh >> get_diff.log 2>&1
```

## Windows rough version
```powershell
# Start mainnet, without restart report.
powershell -ExecutionPolicy Bypass -File .\sync.ps1 main 0

# Start testnet, restart report.
powershell -ExecutionPolicy Bypass -File .\sync.ps1 test 1

# Collect sync diff and send report when ready.
powershell -ExecutionPolicy Bypass -File .\get_diff.ps1
```

For scheduled Windows runs, use `run.ps1` instead of calling `sync.ps1` directly.
`run.ps1` follows `env.txt` like the Linux `run.sh`: mode `1`/`2` starts a without-restart round once, then later timer runs do nothing until `get_diff.ps1` advances `env.txt`.
Mode `3`/`4` performs restart rounds.
For Windows Task Scheduler, prefer `get_diff_task.ps1` for diff collection because it wraps `get_diff.ps1` with task-friendly logging.
If Task Scheduler has quoting issues with PowerShell actions, use `get_diff_task.cmd auto` as the scheduled action.
If Task Scheduler waits on PowerShell and leaves the task in `0x41301` running state, use `get_diff_task_detached.cmd auto`.
See `docs/windows.md` for the current stable Windows deployment procedure.

The Windows report reuses `sendMsg.py` and the same `.env` / `.without_restart_env` files.
It includes `platform: Windows (PowerShell)` near the top of the report.
Grafana links detect the metrics host from `https://ifconfig.me/ip` by default.
Override it with `CKB_SYNC_METRICS_HOST` or the optional script argument when needed:
```powershell
powershell -ExecutionPolicy Bypass -File .\sync.ps1 main 0 47.131.93.120
powershell -ExecutionPolicy Bypass -File .\get_diff.ps1 47.131.93.120
```

## Instructions
Python3 and packages such as discord and python-dotenv need to be installed on the server for testing synchronization.
```bash
sudo apt-get install jq python3-pip -y
```
```bash
sudo pip install discord python-dotenv
```
Please configure the .env file for sending test reports.
```dotenv
DISCORD_CHANNEL_ID=YOUR_DISCORD_CHANNEL_ID
DISCORD_TOKEN=YOUR_DISCORD_TOKEN
```
## exit the SSH session
1. control + A
2. D
## Debug
If there are problems with CKB sync, you can use the following command and enable the debug configuration in the ckb.toml file to help identify the issue.
```bash
curl -s -X POST 127.0.0.1:8114  -H 'Content-Type: application/json' -d '{ "id": 42, "jsonrpc": "2.0", "method": "sync_state", "params": [] }' | jq
curl -s -X POST 127.0.0.1:8114  -H 'Content-Type: application/json' -d '{ "id": 42, "jsonrpc": "2.0", "method": "get_peers", "params": [] }' | jq | grep last_common_header_number
```
Line 13 of ckb.toml

`filter = "info,ckb=debug"`
