$ErrorActionPreference = "Stop"

$PortMainnet = 8114
$PortTestnet = 8124
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Set-Location -LiteralPath $scriptDir

function Get-NowText {
    return (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
}

function Write-RunLog {
    param([string]$Message)

    Add-Content -LiteralPath "run.log" -Encoding UTF8 -Value "$(Get-NowText) $Message"
}

function Stop-CkbByPort {
    param(
        [int]$Port,
        [string]$Label
    )

    $pids = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique

    if (-not $pids) {
        Write-Host "$(Get-NowText) no process found on $Label port $Port"
        return
    }

    foreach ($pidValue in $pids) {
        if ($pidValue -and $pidValue -gt 0) {
            Write-Host "$(Get-NowText) killed the $Label ckb $pidValue"
            Stop-Process -Id $pidValue -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-PortListening {
    param([int]$Port)

    $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1

    return $null -ne $listener
}

function Get-LatestCkbDir {
    param(
        [string]$Prefix,
        [string]$Label
    )

    $dir = Get-ChildItem -Directory -Filter "${Prefix}_ckb_*_x86_64-pc-windows-msvc" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $dir) {
        throw "Cannot find existing $Label CKB directory"
    }

    $ckbExe = Join-Path $dir.FullName "ckb.exe"
    if (-not (Test-Path -LiteralPath $ckbExe)) {
        throw "Cannot find $ckbExe"
    }

    return $dir
}

function Start-ExistingCkb {
    param(
        [string]$Prefix,
        [string]$Label
    )

    $dir = Get-LatestCkbDir -Prefix $Prefix -Label $Label
    $ckbExe = Join-Path $dir.FullName "ckb.exe"

    Write-Host "$(Get-NowText) restart $Label ckb from $($dir.Name)"
    Write-RunLog "start_existing label=$Label dir=$($dir.Name)"
    Start-Process -FilePath $ckbExe -ArgumentList @("run") -WorkingDirectory $dir.FullName -WindowStyle Hidden
    return $dir
}

function Recover-ExistingCkb {
    param(
        [string]$Mode,
        [string]$Prefix,
        [string]$Label,
        [int]$Port
    )

    Write-RunLog "recover_start mode=$Mode label=$Label port=$Port reason=not_listening"

    try {
        $dir = Start-ExistingCkb -Prefix $Prefix -Label $Label
        Write-RunLog "recover_done mode=$Mode label=$Label port=$Port dir=$($dir.Name)"
    }
    catch {
        Write-RunLog "recover_failed mode=$Mode label=$Label port=$Port error=$($_.Exception.Message)"
        throw
    }
}

function Set-EnvState {
    param(
        [string]$Mode,
        [string]$IsExec
    )

    Set-Content -LiteralPath "env.txt" -Encoding ASCII -Value @($Mode, $IsExec)
}

function Get-ModeSequence {
    $defaultSequence = @("1", "2")
    $file = "mode_sequence.txt"

    if (-not (Test-Path -LiteralPath $file)) {
        return $defaultSequence
    }

    $content = Get-Content -LiteralPath $file | ForEach-Object {
        $_ -replace '#.*$', ''
    }

    $modes = @(($content -join " ") -split '[,\s]+' |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -in @("1", "2", "3", "4") })

    if ($modes.Count -eq 0) {
        return $defaultSequence
    }

    $sequence = New-Object System.Collections.Generic.List[string]
    foreach ($modeValue in $modes) {
        if (-not $sequence.Contains($modeValue)) {
            [void]$sequence.Add($modeValue)
        }
    }

    return @($sequence.ToArray())
}

if (-not (Test-Path -LiteralPath "env.txt")) {
    Set-EnvState -Mode "1" -IsExec "1"
    Write-Host "[info] env.txt not found, created with default values:"
    Get-Content -LiteralPath "env.txt"
}

$modeSequence = @(Get-ModeSequence)
$envLines = @(Get-Content -LiteralPath "env.txt")
$mode = if ($envLines.Count -ge 1) { $envLines[0].Trim() } else { "1" }
$isExec = if ($envLines.Count -ge 2) { $envLines[1].Trim() } else { "1" }
$currentTime = Get-NowText

if ($modeSequence -notcontains $mode) {
    $mode = $modeSequence[0]
    $isExec = "1"
    Set-EnvState -Mode $mode -IsExec $isExec
    Write-Warning "Current mode is not enabled by mode_sequence.txt; reset env.txt to mode=$mode is_exec=$isExec"
}

if ($isExec -eq "0") {
    switch ($mode) {
        "1" {
            if (Test-PortListening -Port $PortMainnet) {
                Write-RunLog "check_ok mode=1 label=mainnet port=$PortMainnet action=none"
                Write-Host "$currentTime No restart for ckb in this test round"
                exit 0
            }

            Write-Warning "$currentTime mainnet ckb is not listening on port $PortMainnet; starting existing directory without reinitializing"
            Recover-ExistingCkb -Mode "1" -Prefix "mainnet" -Label "mainnet" -Port $PortMainnet
            exit 0
        }
        "2" {
            if (Test-PortListening -Port $PortTestnet) {
                Write-RunLog "check_ok mode=2 label=testnet port=$PortTestnet action=none"
                Write-Host "$currentTime No restart for ckb in this test round"
                exit 0
            }

            Write-Warning "$currentTime testnet ckb is not listening on port $PortTestnet; starting existing directory without reinitializing"
            Recover-ExistingCkb -Mode "2" -Prefix "testnet" -Label "testnet" -Port $PortTestnet
            exit 0
        }
        "3" {
            Stop-CkbByPort -Port $PortMainnet -Label "mainnet"
            Stop-CkbByPort -Port $PortTestnet -Label "testnet"
            Start-Sleep -Seconds 180
            Start-ExistingCkb -Prefix "mainnet" -Label "mainnet"
            exit 0
        }
        "4" {
            Stop-CkbByPort -Port $PortMainnet -Label "mainnet"
            Stop-CkbByPort -Port $PortTestnet -Label "testnet"
            Start-Sleep -Seconds 180
            Start-ExistingCkb -Prefix "testnet" -Label "testnet"
            exit 0
        }
        default {
            Write-Host "$currentTime Invalid mode: $mode (should be 1~4)"
            exit 1
        }
    }
}

Stop-CkbByPort -Port $PortMainnet -Label "mainnet"
Stop-CkbByPort -Port $PortTestnet -Label "testnet"

switch ($mode) {
    "1" {
        Write-Host "$currentTime Run mode=1 -> .\sync.ps1 main 0"
        & .\sync.ps1 main 0
    }
    "2" {
        Write-Host "$currentTime Run mode=2 -> .\sync.ps1 test 0"
        & .\sync.ps1 test 0
    }
    "3" {
        Write-Host "$currentTime Run mode=3 -> .\sync.ps1 main 1"
        & .\sync.ps1 main 1
    }
    "4" {
        Write-Host "$currentTime Run mode=4 -> .\sync.ps1 test 1"
        & .\sync.ps1 test 1
    }
    default {
        Write-Host "$currentTime Invalid mode: $mode (should be 1~4)"
        exit 1
    }
}

Set-EnvState -Mode $mode -IsExec "0"
Write-Host "[info] Updated env.txt -> set is_exec to 0"
