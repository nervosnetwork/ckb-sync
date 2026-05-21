# Windows deployment notes

This is the stable Windows setup used for the CKB sync test host.

## One-time setup

Install Python and dependencies:

```powershell
py -3 -m pip install discord.py python-dotenv
```

Create Discord env files in the repo root:

```powershell
cd C:\project\ckb-sync

$token = "NEW_DISCORD_TOKEN_HERE"

"DISCORD_CHANNEL_ID=1220284512685260880`nDISCORD_TOKEN=$token" | Set-Content -Encoding ASCII .env
"DISCORD_CHANNEL_ID=1220284446096490506`nDISCORD_TOKEN=$token" | Set-Content -Encoding ASCII .without_restart_env
```

Do not paste real Discord tokens into chat or commits. If a token was pasted anywhere, reset it in Discord Developer Portal.

## Start a without-restart mainnet round

Run this once to initialize and start CKB:

```powershell
cd C:\project\ckb-sync
powershell -ExecutionPolicy Bypass -File .\sync.ps1 main 0
```

After CKB is already running, set `env.txt` to mark the current round as already started:

```powershell
"1`n0" | Set-Content -Encoding ASCII .\env.txt
```

This means:

```text
mode=1    mainnet without-restart
is_exec=0 do not start/reinitialize again in this round
```

Do not put `sync.ps1` in a timer. `sync.ps1` kills the existing CKB process, deletes the network directory, initializes a fresh directory, and starts syncing from scratch.

## Optional run scheduler

Use `run.ps1` only as the Linux `run.sh` equivalent. In mode `1` or `2` with `is_exec=0`, it exits without restarting.

Manual sanity check:

```powershell
powershell -ExecutionPolicy Bypass -File .\run.ps1
```

Expected output for the current mainnet without-restart round:

```text
No restart for ckb in this test round
```

## Diff collection

The reliable setup is a hidden PowerShell loop. It runs `get_diff_task.ps1 -Net main` every 20 minutes and adds a timeout for each collection run.

Disable the old Task Scheduler diff task if it exists:

```powershell
Stop-ScheduledTask -TaskName "ckb-sync-get-diff" -ErrorAction SilentlyContinue
Disable-ScheduledTask -TaskName "ckb-sync-get-diff" -ErrorAction SilentlyContinue
```

Stop old diff collection processes before starting a new loop:

```powershell
Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -like "*get_diff_loop.ps1*" -or $_.CommandLine -like "*get_diff_task*" -or $_.CommandLine -like "*get_diff.ps1*" } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
```

Start the hidden loop:

```powershell
Start-Process powershell.exe `
  -ArgumentList "-NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\project\ckb-sync\get_diff_loop.ps1 -Net main" `
  -WindowStyle Hidden
```

Check that the loop is running:

```powershell
Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -like "*get_diff_loop.ps1*" } |
  Select-Object ProcessId,CommandLine
```

Check collection logs:

```powershell
Get-Content C:\project\ckb-sync\get_diff_loop.log -Tail 20
Get-Content C:\project\ckb-sync\get_diff_task.log -Tail 20
Get-Content C:\project\ckb-sync\diff_$(Get-Date -Format yyyy-MM-dd).log -Tail 10
```

Healthy log lines look like:

```text
loop start net=main interval=1200 timeout=180
run start
run done exit=0
sleep 1195
```

## Stop diff collection

```powershell
Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -like "*get_diff_loop.ps1*" } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

## Migrate existing server to native metrics

Use this when an old Windows node was started with the proxy-based metrics setup. It preserves the existing CKB data directory.

```powershell
cd C:\project\ckb-sync
git pull

# Stop helpers that may keep old settings or the old proxy alive.
Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -like "*metrics_proxy.py*" -or $_.CommandLine -like "*get_diff_loop.ps1*" } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# Stop CKB only; this does not delete any chain data.
Stop-Process -Name ckb -Force -ErrorAction SilentlyContinue

# Remove any old Windows portproxy entry for 8100.
netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=8100

# Point the existing mainnet ckb.toml at CKB's native public metrics port.
$ckbDir = Get-ChildItem -Directory -Filter "mainnet_ckb_*_x86_64-pc-windows-msvc" |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1

if (-not $ckbDir) {
  throw "Cannot find mainnet CKB directory"
}

$toml = Join-Path $ckbDir.FullName "ckb.toml"
$content = Get-Content -LiteralPath $toml -Raw
$target = 'target = { type = "prometheus", listen_address = "0.0.0.0:8100" }'

if ($content -match '(?m)^\s*\[metrics\.exporter\.prometheus\]') {
  $content = [regex]::Replace(
    $content,
    '(?m)^\s*target\s*=\s*\{\s*type\s*=\s*"prometheus"\s*,\s*listen_address\s*=\s*"[^"]+"\s*\}\s*$',
    $target
  )
}
else {
  $content = $content.TrimEnd() + "`r`n`r`n[metrics.exporter.prometheus]`r`n$target`r`n"
}

Set-Content -LiteralPath $toml -Value $content -Encoding UTF8

# Make sure Windows Firewall allows Prometheus to scrape 8100.
if (-not (Get-NetFirewallRule -DisplayName "CKB Prometheus Metrics 8100" -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -DisplayName "CKB Prometheus Metrics 8100" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8100
}

# Restart CKB from the existing data directory.
Start-Process -FilePath "$($ckbDir.FullName)\ckb.exe" `
  -ArgumentList "run" `
  -WorkingDirectory $ckbDir.FullName `
  -WindowStyle Hidden

"1`n0" | Set-Content -Encoding ASCII C:\project\ckb-sync\env.txt

# Restart the diff collector.
Start-Process powershell.exe `
  -ArgumentList "-NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\project\ckb-sync\get_diff_loop.ps1 -Net main" `
  -WorkingDirectory "C:\project\ckb-sync" `
  -WindowStyle Hidden
```

## Metrics checks

CKB exposes Prometheus metrics directly on the public scrape port:

```powershell
curl.exe -i http://127.0.0.1:8100
```

The metrics port should be owned by `ckb.exe`, not a Python proxy:

```powershell
$pid = (Get-NetTCPConnection -LocalPort 8100 -State Listen -ErrorAction SilentlyContinue |
  Select-Object -First 1 -ExpandProperty OwningProcess)
Get-Process -Id $pid
```

From another machine:

```bash
curl -s http://47.131.93.120:8100 | head -30
```

If public access does not work but local access does, check AWS Security Group, subnet NACL, and Windows Firewall for TCP `8100`.

When migrating from an older proxy-based setup, stop the old proxy process:

```powershell
Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -like "*metrics_proxy.py*" } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
```

## Progress checks

```powershell
Get-Content C:\project\ckb-sync\diff_$(Get-Date -Format yyyy-MM-dd).log -Tail 10
```

Example:

```text
height: 11267873 indexer_tip: 10631624 mainnet_height: 19371697 difference: 8740073 height_sync_rate: 58.17% sync_rate: 54.88%
```

## Common pitfalls

- `sync.ps1 main 0` does not mean "do not restart"; it means "write without_restart_result and use .without_restart_env". The script still reinitializes CKB.
- Do not schedule `sync.ps1` every 2 hours for a without-restart round.
- Task Scheduler direct PowerShell actions may get stuck in `0x41301` running state. Prefer the hidden `get_diff_loop.ps1` approach for diff collection.
- Empty `mainnet_height` fields in old logs were caused by remote tip fetch failures. Newer `get_diff.ps1` writes `fetch_failed`.
