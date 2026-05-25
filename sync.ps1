param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("main", "test")]
    [string]$Net,

    [Parameter(Mandatory = $true, Position = 1)]
    [ValidateSet("0", "1")]
    [string]$RestartFlag,

    [Parameter(Mandatory = $false, Position = 2)]
    [string]$MetricsHost = $env:CKB_SYNC_METRICS_HOST
)

$ErrorActionPreference = "Stop"

$MainnetAssumeValidTarget = ""
$TestnetAssumeValidTarget = ""

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
        Write-Warning "$Label`: cannot query port $Port, skip stop"
        return
    }

    foreach ($pidValue in $pids) {
        if ($pidValue -and $pidValue -gt 0) {
            Write-Host "$(Get-NowText) killed the $Label ckb $pidValue"
            Stop-Process -Id $pidValue -Force -ErrorAction SilentlyContinue
        }
    }
}

function Clear-MetricsPort {
    param([int]$Port)

    try {
        netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$Port | Out-Null
    }
    catch {
        # It is fine when no old portproxy entry exists.
    }

    try {
        $oldPids = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty OwningProcess -Unique
        foreach ($oldPid in $oldPids) {
            if ($oldPid -and $oldPid -gt 0 -and $oldPid -ne 4) {
                Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        Write-Warning "Cannot clear metrics port $Port. It may already be free."
    }
}

function Ensure-MetricsFirewallRule {
    param([int]$Port)

    try {
        $ruleName = "CKB Prometheus Metrics $Port"
        if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule `
                -DisplayName $ruleName `
                -Direction Inbound `
                -Action Allow `
                -Protocol TCP `
                -LocalPort $Port | Out-Null
        }
    }
    catch {
        Write-Warning "Cannot ensure firewall rule for metrics port $Port. Run PowerShell as Administrator or configure it manually."
    }
}

function Get-LatestCkbRelease {
    $releases = Invoke-RestMethod `
        -Uri "https://api.github.com/repos/nervosnetwork/ckb/releases" `
        -Headers @{ "User-Agent" = "ckb-sync-windows" }

    $release = $releases |
        Where-Object { $_.tag_name -like "v0.206*" } |
        Sort-Object { [datetime]$_.published_at } |
        Select-Object -Last 1

    if (-not $release) {
        throw "Cannot find CKB release matching v0.206*"
    }

    return $release
}

function Add-IndexerModule {
    param([string]$Content)

    return [regex]::Replace($Content, '(?m)^modules\s*=\s*\[(.*?)\]', {
        param($match)

        $items = $match.Groups[1].Value
        if ($items -match '"Indexer"') {
            return $match.Value
        }

        if ([string]::IsNullOrWhiteSpace($items)) {
            return 'modules = ["Indexer"]'
        }

        return "modules = [$items, `"Indexer`"]"
    })
}

function Update-CkbToml {
    param(
        [string]$Path,
        [int]$RpcPort,
        [int]$MetricsPort,
        [bool]$IsTestnet
    )

    $content = Get-Content -LiteralPath $Path -Raw
    $content = $content -replace '(?m)^listen_address\s*=.*$', "listen_address = `"0.0.0.0:$RpcPort`""

    if ($IsTestnet) {
        $content = $content -replace '(?m)^(listen_addresses\s*=.*)8115(.*)$', '${1}8125${2}'
    }

    $content = Add-IndexerModule -Content $content

    $extraConfig = @"

[metrics.exporter.prometheus]
target = { type = "prometheus", listen_address = "0.0.0.0:$MetricsPort" }

# Experimental: Monitor memory changes.
[memory_tracker]
# Seconds between checking the process, 0 is disable, default is 0.
interval = 5
"@

    $metricsTarget = "target = { type = `"prometheus`", listen_address = `"0.0.0.0:$MetricsPort`" }"
    if ($content -match '(?m)^\s*\[metrics\.exporter\.prometheus\]') {
        $content = [regex]::Replace(
            $content,
            '(?m)^\s*target\s*=\s*\{\s*type\s*=\s*"prometheus"\s*,\s*listen_address\s*=\s*"[^"]+"\s*\}\s*$',
            $metricsTarget
        )
    }
    else {
        $content = $content.TrimEnd() + "`r`n" + $extraConfig + "`r`n"
    }

    Set-Content -LiteralPath $Path -Value $content -Encoding UTF8
}

function Write-MachineInfo {
    param([string]$ResultLog)

    try {
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $os = Get-CimInstance Win32_OperatingSystem
        $computer = Get-CimInstance Win32_ComputerSystem
        $cores = ($cpu.NumberOfLogicalProcessors)
        $memoryGb = [math]::Round($computer.TotalPhysicalMemory / 1GB, 1)
        Add-Content -LiteralPath $ResultLog -Value "machine: ${cores}C${memoryGb}G    $($os.Caption)    $($cpu.Name)"
    }
    catch {
        Add-Content -LiteralPath $ResultLog -Value "machine_info: unavailable"
    }
}

if ($Net -eq "main") {
    $Label = "mainnet"
    $RpcPort = 8114
    $MetricsPort = 8100
    $AssumeValidTarget = $MainnetAssumeValidTarget
}
else {
    $Label = "testnet"
    $RpcPort = 8124
    $MetricsPort = 8100
    $AssumeValidTarget = $TestnetAssumeValidTarget
}

$MetricsHost = Resolve-MetricsHost -Value $MetricsHost

Stop-CkbByPort -Port $RpcPort -Label $Label
Clear-MetricsPort -Port $MetricsPort
Start-Sleep -Seconds 2

$release = Get-LatestCkbRelease
$ckbVersion = $release.tag_name
Write-Host "Latest CKB version: $ckbVersion"

$assetName = "ckb_${ckbVersion}_x86_64-pc-windows-msvc.zip"
$asset = $release.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
if (-not $asset) {
    throw "Cannot find Windows asset: $assetName"
}

if (-not (Test-Path -LiteralPath $assetName)) {
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $assetName
}

$targetPrefix = if ($Net -eq "main") { "mainnet" } else { "testnet" }
Get-ChildItem -Directory -Filter "${targetPrefix}_ckb_*_x86_64-pc-windows-msvc" |
    Remove-Item -Recurse -Force

$extractDir = [IO.Path]::GetFileNameWithoutExtension($assetName)
if (Test-Path -LiteralPath $extractDir) {
    Remove-Item -LiteralPath $extractDir -Recurse -Force
}

Expand-Archive -LiteralPath $assetName -DestinationPath . -Force
Remove-Item -LiteralPath $assetName -Force

$targetDir = "${targetPrefix}_ckb_${ckbVersion}_x86_64-pc-windows-msvc"
Move-Item -LiteralPath $extractDir -Destination $targetDir -Force

$startDay = (Get-Date).ToString("yyyy-MM-dd")
if ($RestartFlag -eq "0") {
    $resultLog = "without_restart_result_${startDay}.log"
    $otherLog = "result_${startDay}.log"
}
else {
    $resultLog = "result_${startDay}.log"
    $otherLog = "without_restart_result_${startDay}.log"
}

foreach ($log in @($resultLog, $otherLog)) {
    if (Test-Path -LiteralPath $log) {
        Remove-Item -LiteralPath $log -Force
        Write-Host "$log removed"
    }
}

$ckbExe = Join-Path $targetDir "ckb.exe"
& $ckbExe --version | Set-Content -LiteralPath $resultLog -Encoding UTF8
Add-Content -LiteralPath $resultLog -Value "platform: Windows (PowerShell)"
Add-Content -LiteralPath $resultLog -Value "network: $Label"
Add-Content -LiteralPath $resultLog -Value "metrics_target: ${MetricsHost}:$MetricsPort"

Push-Location $targetDir
try {
    $chain = if ($Net -eq "main") { "mainnet" } else { "testnet" }
    & ".\ckb.exe" init --chain $chain --force

    $tomlPath = Join-Path (Get-Location) "ckb.toml"
    $specLine = Select-String -LiteralPath $tomlPath -Pattern 'spec =' | Select-Object -First 1
    if ($specLine) {
        Write-Host $specLine.Line
        $specName = (($specLine.Line -split '/')[1] -split '\.')[0]
        Add-Content -LiteralPath (Join-Path (Split-Path (Get-Location) -Parent) $resultLog) -Value $specName
    }

    Update-CkbToml -Path $tomlPath -RpcPort $RpcPort -MetricsPort $MetricsPort -IsTestnet:($Net -eq "test")
}
finally {
    Pop-Location
}

Ensure-MetricsFirewallRule -Port $MetricsPort

Add-Content -LiteralPath $resultLog -Value "rich-indexer type: Not Enabled"

Write-Host "$(Get-NowText) start $Label ckb node"
Push-Location $targetDir
try {
    $arguments = @("run")
    if (-not [string]::IsNullOrWhiteSpace($AssumeValidTarget)) {
        $arguments += @("--assume-valid-target", $AssumeValidTarget)
        Add-Content -LiteralPath (Join-Path (Split-Path (Get-Location) -Parent) $resultLog) -Value "$Label assume-valid-target: $AssumeValidTarget"
    }
    else {
        Add-Content -LiteralPath (Join-Path (Split-Path (Get-Location) -Parent) $resultLog) -Value "$Label assume-valid-target: default"
    }

    Start-Process -FilePath ".\ckb.exe" -ArgumentList $arguments -WorkingDirectory (Get-Location) -WindowStyle Hidden
}
finally {
    Pop-Location
}

Write-MachineInfo -ResultLog $resultLog
Add-Content -LiteralPath $resultLog -Value "sync_start: $(Get-NowText)"
