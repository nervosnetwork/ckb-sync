param(
    [Parameter(Mandatory = $false, Position = 0)]
    [string]$MetricsHost = $env:CKB_SYNC_METRICS_HOST
)

$ErrorActionPreference = "Continue"

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
        return Invoke-RestMethod -Uri $Url -Method Post -ContentType "application/json" -Body $body -TimeoutSec 15
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

function Switch-EnvFile {
    $file = "env.txt"
    if (-not (Test-Path -LiteralPath $file)) {
        Write-Warning "$file not found"
        return
    }

    $lines = @(Get-Content -LiteralPath $file)
    $first = if ($lines.Count -gt 0) { $lines[0].Trim() } else { "" }
    switch ($first) {
        "1" { $next = "2" }
        "2" { $next = "3" }
        "3" { $next = "4" }
        "4" { $next = "1" }
        default { $next = "1" }
    }

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

    Set-Content -LiteralPath $file -Value $lines -Encoding UTF8
}

function Invoke-SendMessage {
    param([string]$LogPath)

    if (-not (Test-Path -LiteralPath "sendMsg.py")) {
        return
    }

    $logName = Split-Path -Leaf $LogPath
    $args = @("sendMsg.py", $LogPath)
    if ($logName -like "without_restart_result*") {
        $args += ".without_restart_env"
    }

    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        & $python.Source @args
        return
    }

    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        & $py.Source -3 @args
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
    if ($content -notmatch "$Net sync_end" -or $content -match "$Net kill_time") {
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
    Invoke-SendMessage -LogPath $LogPath
    Switch-EnvFile
}

$currentDay = (Get-Date).ToString("yyyy-MM-dd")
$diffLog = "diff_${currentDay}.log"

$main = Get-SyncSnapshot -Label "mainnet" -LocalUrl "http://localhost:8114" -RemoteUrl "https://mainnet.ckbapp.dev"
Write-SyncSnapshot -Snapshot $main -DiffLog $diffLog

$test = Get-SyncSnapshot -Label "testnet" -LocalUrl "http://localhost:8124" -RemoteUrl "https://testnet.ckbapp.dev"
Write-SyncSnapshot -Snapshot $test -DiffLog $diffLog

$resultLogFile = Find-LatestResultLog
if ($resultLogFile) {
    Add-SyncEndIfReady -Net "mainnet" -Snapshot $main -LogPath $resultLogFile.FullName
    Add-SyncEndIfReady -Net "testnet" -Snapshot $test -LogPath $resultLogFile.FullName
    Stop-AfterSyncEndWindow -Net "mainnet" -Snapshot $main -LogPath $resultLogFile.FullName -Port 8114 -MetricsPort 8100 -MetricsHost $MetricsHost
    Stop-AfterSyncEndWindow -Net "testnet" -Snapshot $test -LogPath $resultLogFile.FullName -Port 8124 -MetricsPort 8102 -MetricsHost $MetricsHost
}
