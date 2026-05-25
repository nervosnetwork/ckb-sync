param(
    [Parameter(Mandatory = $false, Position = 0)]
    [string]$MetricsHost = $env:CKB_SYNC_METRICS_HOST,

    [Parameter(Mandatory = $false, Position = 1)]
    [ValidateSet("all", "main", "test")]
    [string]$Net = "all",

    [Parameter(Mandatory = $false)]
    [int]$RpcTimeoutSec = 5
)

$ErrorActionPreference = "Continue"

if (-not [string]::IsNullOrWhiteSpace($MetricsHost) -and $MetricsHost.Trim().StartsWith("-")) {
    Write-Warning "Ignoring invalid metrics host argument '$MetricsHost'. Use -Net <all|main|test> and -MetricsHost <host> as named arguments."
    $MetricsHost = $env:CKB_SYNC_METRICS_HOST
}

function Get-NowText {
    return (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
}

function Resolve-MetricsHost {
    param([string]$Value)

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }

    try {
        $detected = (Invoke-WebRequest -Uri "https://ifconfig.me/ip" -UseBasicParsing -TimeoutSec 10).Content.Trim()
        if ($detected -match '^\d{1,3}(\.\d{1,3}){3}$') {
            return $detected
        }
    }
    catch {
        Write-Warning "Cannot detect public IP from ifconfig.me/ip, fallback to 127.0.0.1"
    }

    return "127.0.0.1"
}

$MetricsHost = Resolve-MetricsHost -Value $MetricsHost

function Invoke-CkbRpc {
    param(
        [string]$Url,
        [string]$Method
    )

    $body = @{
        id = 1
        jsonrpc = "2.0"
        method = $Method
        params = @()
    } | ConvertTo-Json -Compress

    try {
        return Invoke-RestMethod -Uri $Url -Method Post -ContentType "application/json" -Body $body -TimeoutSec $RpcTimeoutSec
    }
    catch {
        return $null
    }
}

function Convert-HexHeight {
    param([string]$HexValue)

    if ([string]::IsNullOrWhiteSpace($HexValue)) {
        return $null
    }

    $clean = $HexValue -replace '^0x', ''
    if ($clean -notmatch '^[0-9a-fA-F]+$') {
        return $null
    }

    return [Convert]::ToInt64($clean, 16)
}

function Get-TipHeight {
    param([string]$Url)

    $response = Invoke-CkbRpc -Url $Url -Method "get_tip_header"
    return Convert-HexHeight $response.result.number
}

function Get-IndexerTip {
    param([string]$Url)

    $response = Invoke-CkbRpc -Url $Url -Method "get_indexer_tip"
    return Convert-HexHeight $response.result.block_number
}

function Get-SyncSnapshot {
    param(
        [string]$Label,
        [string]$LocalUrl,
        [string]$RemoteUrl
    )

    $height = Get-TipHeight -Url $LocalUrl
    $indexerTip = Get-IndexerTip -Url $LocalUrl
    $latestHeight = Get-TipHeight -Url $RemoteUrl

    $snapshot = [ordered]@{
        Label = $Label
        Height = $height
        IndexerTip = $indexerTip
        LatestHeight = $latestHeight
        Difference = $null
        HeightSyncRate = $null
        SyncRate = $null
    }

    if ($null -ne $indexerTip -and $null -ne $latestHeight -and $latestHeight -gt 0) {
        $snapshot.Difference = [math]::Abs($latestHeight - $indexerTip)
        $snapshot.SyncRate = "{0:N2}%" -f (($indexerTip * 100.0) / $latestHeight)
    }

    if ($null -ne $height -and $null -ne $latestHeight -and $latestHeight -gt 0) {
        $snapshot.HeightSyncRate = "{0:N2}%" -f (($height * 100.0) / $latestHeight)
    }

    return [pscustomobject]$snapshot
}

function Write-SyncSnapshot {
    param(
        [object]$Snapshot,
        [string]$DiffLog
    )

    if ($null -eq $Snapshot.Height -or $null -eq $Snapshot.IndexerTip) {
        return
    }

    $latestLabel = if ($Snapshot.Label -eq "testnet") { "testnet_height" } else { "mainnet_height" }
    if ($null -eq $Snapshot.LatestHeight) {
        Add-Content -LiteralPath $DiffLog -Value "$(Get-NowText) height: $($Snapshot.Height) indexer_tip: $($Snapshot.IndexerTip) ${latestLabel}: fetch_failed difference: fetch_failed height_sync_rate: fetch_failed sync_rate: fetch_failed"
        return
    }

    Add-Content -LiteralPath $DiffLog -Value "$(Get-NowText) height: $($Snapshot.Height) indexer_tip: $($Snapshot.IndexerTip) ${latestLabel}: $($Snapshot.LatestHeight) difference: $($Snapshot.Difference) height_sync_rate: $($Snapshot.HeightSyncRate) sync_rate: $($Snapshot.SyncRate)"
}

function Find-LatestResultLog {
    $logs = Get-ChildItem -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(without_restart_result_|result_)\d{4}-\d{2}-\d{2}\.log$' } |
        ForEach-Object {
            $dateText = [regex]::Match($_.Name, '\d{4}-\d{2}-\d{2}').Value
            [pscustomobject]@{
                File = $_
                Date = [datetime]::ParseExact($dateText, "yyyy-MM-dd", $null)
            }
        } |
        Sort-Object Date, { $_.File.Name }

    return ($logs | Select-Object -Last 1).File
}

function Add-SyncEndIfReady {
    param(
        [string]$Net,
        [object]$Snapshot,
        [string]$LogPath,
        [int]$Threshold = 13000
    )

    if (-not (Test-Path -LiteralPath $LogPath)) {
        return
    }

    $content = Get-Content -LiteralPath $LogPath -Raw
    if ($content -match "$Net sync_end") {
        return
    }

    if ($null -eq $Snapshot.Difference -or $Snapshot.Difference -ge $Threshold) {
        return
    }

    $syncEnd = Get-NowText
    Add-Content -LiteralPath $LogPath -Value "$Net sync_end: $syncEnd (height: $($Snapshot.Height), indexer_tip: $($Snapshot.IndexerTip))"

    $syncStartLine = Select-String -LiteralPath $LogPath -Pattern '^sync_start:' | Select-Object -First 1
    if (-not $syncStartLine) {
        return
    }

    $syncStartText = $syncStartLine.Line -replace '^sync_start:\s*', ''
    try {
        $syncStart = [datetime]::ParseExact($syncStartText, "yyyy-MM-dd HH:mm:ss", $null)
        $duration = (Get-Date) - $syncStart
        $durationText = "{0}d {1}h {2}m {3}s" -f $duration.Days, $duration.Hours, $duration.Minutes, $duration.Seconds
        Add-Content -LiteralPath $LogPath -Value "$Net sync duration to latest indexer height: $durationText"
    }
    catch {
        return
    }
}

function Stop-CkbByPort {
    param(
        [int]$Port,
        [string]$Label
    )

    try {
        $pids = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty OwningProcess -Unique
    }
    catch {
        return
    }

    foreach ($pidValue in $pids) {
        if ($pidValue -and $pidValue -gt 0) {
            Write-Host "$(Get-NowText) killed the $Label ckb $pidValue"
            Stop-Process -Id $pidValue -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-ExpectedMode {
    param(
        [string]$Net,
        [string]$LogPath
    )

    $logName = Split-Path -Leaf $LogPath
    $withoutRestart = $logName -like "without_restart_result*"

    if ($Net -eq "mainnet") {
        if ($withoutRestart) {
            return "1"
        }
        return "3"
    }

    if ($withoutRestart) {
        return "2"
    }
    return "4"
}

function Get-NextMode {
    param([string]$Mode)

    switch ($Mode) {
        "1" { return "2" }
        "2" { return "3" }
        "3" { return "4" }
        "4" { return "1" }
        default { return "1" }
    }
}

function Switch-EnvFile {
    param([string]$ExpectedMode)

    $file = "env.txt"
    if (-not (Test-Path -LiteralPath $file)) {
        Write-Warning "$file not found"
        return $null
    }

    $lines = @(Get-Content -LiteralPath $file)
    $first = if ($lines.Count -gt 0) { $lines[0].Trim() } else { "" }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedMode) -and $first -ne $ExpectedMode) {
        Write-Warning "Skip env.txt switch: current mode is '$first', but completed round expects mode '$ExpectedMode'."
        return $null
    }

    $next = Get-NextMode -Mode $first

    if ($lines.Count -eq 0) {
        $lines = @($next, "1")
    }
    elseif ($lines.Count -eq 1) {
        $lines[0] = $next
        $lines += "1"
    }
    else {
        $lines[0] = $next
        $lines[1] = "1"
    }

    Set-Content -LiteralPath $file -Value $lines -Encoding ASCII
    Write-Host "[info] Updated env.txt -> mode=$($lines[0]) is_exec=$($lines[1])"

    return [pscustomobject]@{
        Mode = $lines[0]
        IsExec = $lines[1]
    }
}

function Invoke-SendMessage {
    param(
        [string]$LogPath,
        [int]$TimeoutSeconds = 120
    )

    if (-not (Test-Path -LiteralPath "sendMsg.py")) {
        Write-Warning "Cannot send report: sendMsg.py not found"
        return $false
    }

    $logName = Split-Path -Leaf $LogPath
    $sendArgs = @("sendMsg.py", $LogPath)
    if ($logName -like "without_restart_result*") {
        $sendArgs += ".without_restart_env"
    }

    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        $exe = $python.Source
        $processArgs = $sendArgs
    }
    else {
        $py = Get-Command py -ErrorAction SilentlyContinue
        if (-not $py) {
            Write-Warning "Cannot send report: neither python nor py was found"
            return $false
        }

        $exe = $py.Source
        $processArgs = @("-3") + $sendArgs
    }

    $outFile = Join-Path ([System.IO.Path]::GetTempPath()) ("ckb-sync-send-{0}.out" -f ([guid]::NewGuid().ToString("N")))
    $errFile = Join-Path ([System.IO.Path]::GetTempPath()) ("ckb-sync-send-{0}.err" -f ([guid]::NewGuid().ToString("N")))

    try {
        $process = Start-Process -FilePath $exe `
            -ArgumentList $processArgs `
            -WorkingDirectory (Get-Location).Path `
            -RedirectStandardOutput $outFile `
            -RedirectStandardError $errFile `
            -WindowStyle Hidden `
            -PassThru

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            Write-Warning "sendMsg.py timed out after $TimeoutSeconds seconds"
            return $false
        }

        if (Test-Path -LiteralPath $outFile) {
            Get-Content -LiteralPath $outFile | ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace($_)) {
                    Write-Host "sendMsg: $_"
                }
            }
        }

        if (Test-Path -LiteralPath $errFile) {
            Get-Content -LiteralPath $errFile | ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace($_)) {
                    Write-Warning "sendMsg: $_"
                }
            }
        }

        if ($process.ExitCode -ne 0) {
            Write-Warning "sendMsg.py exited with code $($process.ExitCode)"
            return $false
        }

        return $true
    }
    catch {
        Write-Warning "Cannot send report: $($_.Exception.Message)"
        return $false
    }
    finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Convert-LogTimeToUnixMilliseconds {
    param(
        [string]$TimeText,
        [datetime]$Fallback
    )

    try {
        $parsed = [datetime]::ParseExact($TimeText, "yyyy-MM-dd HH:mm:ss", $null)
        return ([DateTimeOffset]$parsed).ToUnixTimeMilliseconds()
    }
    catch {
        return ([DateTimeOffset]$Fallback).ToUnixTimeMilliseconds()
    }
}

function Ensure-GrafanaLink {
    param(
        [string]$Net,
        [string]$LogPath,
        [int]$MetricsPort,
        [string]$MetricsHost
    )

    if ([string]::IsNullOrWhiteSpace($MetricsHost)) {
        return
    }

    $content = Get-Content -LiteralPath $LogPath -Raw
    $target = "${MetricsHost}:$MetricsPort"
    if ($content -match [regex]::Escape("var-url=$target")) {
        return
    }

    $syncStartMatch = [regex]::Match($content, "sync_start:\s*(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})")
    $killTimeMatch = [regex]::Match($content, "$Net kill_time:\s*(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})")

    $fromMs = Convert-LogTimeToUnixMilliseconds -TimeText $syncStartMatch.Groups[1].Value -Fallback (Get-Date).AddHours(-3)
    $toMs = Convert-LogTimeToUnixMilliseconds -TimeText $killTimeMatch.Groups[1].Value -Fallback (Get-Date)

    Add-Content -LiteralPath $LogPath -Value "metrics_target: $target"
    Add-Content -LiteralPath $LogPath -Value "Grafana: https://grafana-monitor.nervos.tech/d/pThsj6xVz/test?orgId=1&var-url=$target&from=$fromMs&to=$toMs"
}

function Complete-PostKillActions {
    param(
        [string]$Net,
        [string]$LogPath,
        [int]$MetricsPort,
        [string]$MetricsHost
    )

    $escapedNet = [regex]::Escape($Net)
    Ensure-GrafanaLink -Net $Net -LogPath $LogPath -MetricsPort $MetricsPort -MetricsHost $MetricsHost

    $content = Get-Content -LiteralPath $LogPath -Raw
    $envReady = $false

    if ($content -match "(?m)^$escapedNet env_switched:") {
        $envReady = $true
    }
    else {
        $expectedMode = Get-ExpectedMode -Net $Net -LogPath $LogPath
        $newState = Switch-EnvFile -ExpectedMode $expectedMode
        if ($newState) {
            Add-Content -LiteralPath $LogPath -Value "$Net env_switched: $(Get-NowText) (mode: $($newState.Mode), is_exec: $($newState.IsExec))"
            $envReady = $true
        }
    }

    if (-not $envReady) {
        return
    }

    $content = Get-Content -LiteralPath $LogPath -Raw
    if ($content -match "(?m)^$escapedNet report_sent:") {
        return
    }

    if (Invoke-SendMessage -LogPath $LogPath) {
        Add-Content -LiteralPath $LogPath -Value "$Net report_sent: $(Get-NowText)"
    }
    else {
        Write-Warning "Report is complete and env.txt was advanced, but sendMsg.py did not complete successfully."
    }
}

function Stop-AfterSyncEndWindow {
    param(
        [string]$Net,
        [object]$Snapshot,
        [string]$LogPath,
        [int]$Port,
        [int]$MetricsPort,
        [string]$MetricsHost
    )

    if (-not (Test-Path -LiteralPath $LogPath)) {
        return
    }

    $content = Get-Content -LiteralPath $LogPath -Raw
    if ($content -match "$Net kill_time") {
        Complete-PostKillActions -Net $Net -LogPath $LogPath -MetricsPort $MetricsPort -MetricsHost $MetricsHost
        return
    }

    if ($content -notmatch "$Net sync_end") {
        return
    }

    $match = [regex]::Match($content, "$Net sync_end:\s*(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})")
    if (-not $match.Success) {
        return
    }

    try {
        $syncEnd = [datetime]::ParseExact($match.Groups[1].Value, "yyyy-MM-dd HH:mm:ss", $null)
    }
    catch {
        return
    }

    if (((Get-Date) - $syncEnd).TotalSeconds -lt 10800) {
        return
    }

    Stop-CkbByPort -Port $Port -Label $Net
    Add-Content -LiteralPath $LogPath -Value "$Net kill_time: $(Get-NowText) (height: $($Snapshot.Height), indexer_tip: $($Snapshot.IndexerTip))"

    $syncStartLine = Select-String -LiteralPath $LogPath -Pattern '^sync_start:' | Select-Object -First 1
    $fromMs = ([DateTimeOffset](Get-Date).AddHours(-3)).ToUnixTimeMilliseconds()
    if ($syncStartLine) {
        try {
            $syncStartText = $syncStartLine.Line -replace '^sync_start:\s*', ''
            $syncStart = [datetime]::ParseExact($syncStartText, "yyyy-MM-dd HH:mm:ss", $null)
            $fromMs = ([DateTimeOffset]$syncStart).ToUnixTimeMilliseconds()
        }
        catch {
            $fromMs = ([DateTimeOffset](Get-Date).AddHours(-3)).ToUnixTimeMilliseconds()
        }
    }

    $toMs = ([DateTimeOffset](Get-Date)).ToUnixTimeMilliseconds()
    Add-Content -LiteralPath $LogPath -Value "metrics_target: ${MetricsHost}:$MetricsPort"
    Add-Content -LiteralPath $LogPath -Value "Grafana: https://grafana-monitor.nervos.tech/d/pThsj6xVz/test?orgId=1&var-url=${MetricsHost}:$MetricsPort&from=$fromMs&to=$toMs"
    Complete-PostKillActions -Net $Net -LogPath $LogPath -MetricsPort $MetricsPort -MetricsHost $MetricsHost
}

$currentDay = (Get-Date).ToString("yyyy-MM-dd")
$diffLog = "diff_${currentDay}.log"

$main = $null
if ($Net -in @("all", "main")) {
    $main = Get-SyncSnapshot -Label "mainnet" -LocalUrl "http://localhost:8114" -RemoteUrl "https://mainnet.ckbapp.dev"
    Write-SyncSnapshot -Snapshot $main -DiffLog $diffLog
}

$test = $null
if ($Net -in @("all", "test")) {
    $test = Get-SyncSnapshot -Label "testnet" -LocalUrl "http://localhost:8124" -RemoteUrl "https://testnet.ckbapp.dev"
    Write-SyncSnapshot -Snapshot $test -DiffLog $diffLog
}

$resultLogFile = Find-LatestResultLog
if ($resultLogFile) {
    if ($main) {
        Add-SyncEndIfReady -Net "mainnet" -Snapshot $main -LogPath $resultLogFile.FullName
        Stop-AfterSyncEndWindow -Net "mainnet" -Snapshot $main -LogPath $resultLogFile.FullName -Port 8114 -MetricsPort 8100 -MetricsHost $MetricsHost
    }

    if ($test) {
        Add-SyncEndIfReady -Net "testnet" -Snapshot $test -LogPath $resultLogFile.FullName
        Stop-AfterSyncEndWindow -Net "testnet" -Snapshot $test -LogPath $resultLogFile.FullName -Port 8124 -MetricsPort 8102 -MetricsHost $MetricsHost
    }
}
