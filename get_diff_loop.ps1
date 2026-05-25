param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("auto", "all", "main", "test")]
    [string]$Net = "auto",

    [Parameter(Mandatory = $false)]
    [int]$IntervalSeconds = 1200,

    [Parameter(Mandatory = $false)]
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = "Continue"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$loopLog = Join-Path $scriptDir "get_diff_loop.log"

function Write-LoopLog {
    param([string]$Message)

    $line = "{0} {1}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -LiteralPath $loopLog -Encoding UTF8 -Value $line
}

Set-Location -LiteralPath $scriptDir
Write-LoopLog "loop start net=$Net interval=$IntervalSeconds timeout=$TimeoutSeconds"

while ($true) {
    $start = Get-Date
    Write-LoopLog "run start"

    $process = Start-Process -FilePath "powershell.exe" `
        -ArgumentList @(
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            "$scriptDir\get_diff_task.ps1",
            "-Net",
            $Net
        ) `
        -WindowStyle Hidden `
        -PassThru

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Write-LoopLog "run timeout, killing pid=$($process.Id)"
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-LoopLog "run done exit=$($process.ExitCode)"
    }

    $elapsed = [int]((Get-Date) - $start).TotalSeconds
    $sleepSeconds = [Math]::Max(10, $IntervalSeconds - $elapsed)
    Write-LoopLog "sleep $sleepSeconds"
    Start-Sleep -Seconds $sleepSeconds
}
