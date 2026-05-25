param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("auto", "all", "main", "test")]
    [string]$Net = "auto",

    [Parameter(Mandatory = $false)]
    [string]$MetricsHost = $env:CKB_SYNC_METRICS_HOST,

    [Parameter(Mandatory = $false)]
    [switch]$NoFollowEnv
)

$ErrorActionPreference = "Continue"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$taskLog = Join-Path $scriptDir "get_diff_task.log"

function Write-TaskLog {
    param([string]$Message)

    $line = "{0} {1}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -LiteralPath $taskLog -Encoding UTF8 -Value $line
}

function Get-NetFromEnv {
    if (-not (Test-Path -LiteralPath "env.txt")) {
        return $null
    }

    $envLines = @(Get-Content -LiteralPath "env.txt")
    $mode = if ($envLines.Count -ge 1) { $envLines[0].Trim() } else { "" }

    switch ($mode) {
        { $_ -in @("1", "3") } { return "main" }
        { $_ -in @("2", "4") } { return "test" }
        default { return $null }
    }
}

function Resolve-Net {
    param(
        [string]$RequestedNet,
        [bool]$FollowEnv
    )

    if ($RequestedNet -eq "all") {
        return "all"
    }

    $envNet = Get-NetFromEnv
    if ($envNet) {
        if ($RequestedNet -eq "auto" -or ($FollowEnv -and $RequestedNet -ne $envNet)) {
            return $envNet
        }
    }

    if ($RequestedNet -eq "auto") {
        return "all"
    }

    return $RequestedNet
}

try {
    Set-Location -LiteralPath $scriptDir
    $resolvedNet = Resolve-Net -RequestedNet $Net -FollowEnv:(-not $NoFollowEnv)
    Write-TaskLog "start requested_net=$Net resolved_net=$resolvedNet follow_env=$(-not $NoFollowEnv)"

    $scriptArgs = @{
        Net = $resolvedNet
    }
    if (-not [string]::IsNullOrWhiteSpace($MetricsHost)) {
        $scriptArgs.MetricsHost = $MetricsHost
    }

    $output = & (Join-Path $scriptDir "get_diff.ps1") @scriptArgs 2>&1
    foreach ($line in $output) {
        Write-TaskLog "$line"
    }

    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    Write-TaskLog "done exit=$exitCode"
    exit 0
}
catch {
    Write-TaskLog "error: $($_.Exception.Message)"
    exit 1
}
