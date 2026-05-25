param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("all", "main", "test")]
    [string]$Net = "main",

    [Parameter(Mandatory = $false)]
    [string]$MetricsHost = $env:CKB_SYNC_METRICS_HOST
)

$ErrorActionPreference = "Continue"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$taskLog = Join-Path $scriptDir "get_diff_task.log"

function Write-TaskLog {
    param([string]$Message)

    $line = "{0} {1}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -LiteralPath $taskLog -Encoding UTF8 -Value $line
}

try {
    Set-Location -LiteralPath $scriptDir
    Write-TaskLog "start net=$Net"

    $scriptArgs = @{
        Net = $Net
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
