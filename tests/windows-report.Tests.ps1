param(
    [string]$PythonExecutable,
    [string]$WorkerDirectory
)

$ErrorActionPreference = "Stop"
$repoDir = Split-Path -Parent $PSScriptRoot

# Load only the production functions. Never run RPC collection or use the real
# sendMsg.py / Discord credentials. All subprocesses run in a temporary fixture.
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repoDir "get_diff.ps1"), [ref]$tokens, [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw ($parseErrors | Out-String)
}
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
}

if (-not $PythonExecutable) {
    $PythonExecutable = (Get-Command python, python3 -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1).Source
}
if (-not $PythonExecutable) {
    throw "Pass -PythonExecutable with the path to Python 3."
}

# Keep interpreter selection independent of Python launcher names on the host.
function Get-Command {
    [CmdletBinding()]
    param([string]$Name)
    if ($Name -eq "python") {
        return [pscustomobject]@{ Source = $PythonExecutable }
    }
    return Microsoft.PowerShell.Core\Get-Command -Name $Name
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Complete-Fixture {
    Stop-AfterSyncEndWindow -Net "mainnet" -Snapshot $null `
        -LogPath (Join-Path (Get-Location).Path "without_restart_result_2026-09-04.log") `
        -Port 8114 -MetricsPort 8100 -MetricsHost "127.0.0.1"
}

if ($WorkerDirectory) {
    Set-Location -LiteralPath $WorkerDirectory
    Complete-Fixture
    exit 0
}

$fixtureDir = Join-Path ([IO.Path]::GetTempPath()) ("ckb sync report tests " + [guid]::NewGuid().ToString("N"))
$logName = "without_restart_result_2026-09-04.log"
$fixtureLog = @"
ckb test fixture
network: mainnet
sync_start: 2026-09-04 18:38:41
mainnet sync_end: 2026-09-13 06:20:54 (height: 20440042, indexer_tip: 20437900)
mainnet kill_time: 2026-09-13 09:20:56 (height: 20441361, indexer_tip: 20441361)
"@

function Reset-Fixture {
    Set-Content -LiteralPath $logName -Value $fixtureLog -Encoding UTF8
    Set-Content -LiteralPath "env.txt" -Value @("1", "0") -Encoding ASCII
    Set-Content -LiteralPath "mode_sequence.txt" -Value "1,2" -Encoding ASCII
    Set-Content -LiteralPath "sender-settings.json" -Value '{}' -Encoding ASCII
    Remove-Item -LiteralPath "attempts.log" -ErrorAction SilentlyContinue
}

function Get-AttemptCount {
    if (-not (Test-Path -LiteralPath "attempts.log")) { return 0 }
    return @(Get-Content -LiteralPath "attempts.log").Count
}

function Get-MarkerCount {
    param([string]$Marker)
    return @(Select-String -LiteralPath $logName -Pattern "^mainnet ${Marker}:").Count
}

$senderFixture = @'
import json
from pathlib import Path
import sys
import time

settings = json.loads(Path("sender-settings.json").read_text())
assert sys.stdout.encoding.lower().replace("-", "") == "utf8", sys.stdout.encoding
assert sys.stderr.encoding.lower().replace("-", "") == "utf8", sys.stderr.encoding
assert len(sys.argv) == 3, sys.argv
assert Path(sys.argv[1]).is_file(), sys.argv
assert sys.argv[2] == ".without_restart_env", sys.argv
with Path("attempts.log").open("a") as attempts:
    attempts.write("attempt\n")
time.sleep(settings.get("delay", 0))
if settings.get("large_output"):
    for _ in range(1024):
        print("stdout " + "x" * 256)
        print("stderr " + "x" * 256, file=sys.stderr)
if settings.get("exit_code", 0):
    print("simulated send failure", file=sys.stderr)
    sys.exit(settings["exit_code"])
print("simulated HTTP 200: \u5df2\u53d1\u9001")
'@

New-Item -ItemType Directory -Path $fixtureDir | Out-Null
Push-Location -LiteralPath $fixtureDir
$originalPythonEncoding = $env:PYTHONIOENCODING
$env:PYTHONIOENCODING = "ascii"
try {
    Set-Content -LiteralPath "sendMsg.py" -Value $senderFixture -Encoding UTF8

    Reset-Fixture
    Complete-Fixture
    Complete-Fixture
    Assert-True ((Get-AttemptCount) -eq 1) "A successful report was sent again."
    Assert-True ((Get-MarkerCount "report_sent") -eq 1) "Success must persist exactly one report_sent marker."
    Assert-True ((Get-MarkerCount "env_switched") -eq 1) "The round must advance once."
    Assert-True (((Get-Content "env.txt") -join ',') -eq "2,1") "The next mode should be pending testnet."
    Write-Host "PASS: successful send is recorded and repeated collection skips it (paths with spaces)."

    Reset-Fixture
    Set-Content "sender-settings.json" '{"exit_code": 7}' -Encoding ASCII
    Complete-Fixture
    Assert-True ((Get-MarkerCount "report_sent") -eq 0) "Failed sends must not be marked successful."
    Set-Content "sender-settings.json" '{}' -Encoding ASCII
    Complete-Fixture
    Complete-Fixture
    Assert-True ((Get-AttemptCount) -eq 2) "A failed send must retry once, then stop after success."
    Assert-True ((Get-MarkerCount "env_switched") -eq 1) "A retry must not advance the mode again."
    Write-Host "PASS: nonzero exit retries without repeating the mode transition."

    Reset-Fixture
    Set-Content "sender-settings.json" '{"delay": 10}' -Encoding ASCII
    $sent = Invoke-SendMessage -LogPath (Join-Path $fixtureDir $logName) -TimeoutSeconds 1
    Assert-True ($sent -is [bool] -and -not $sent) "A timeout must return false."
    Set-Content "sender-settings.json" '{}' -Encoding ASCII
    Complete-Fixture
    Complete-Fixture
    Assert-True ((Get-AttemptCount) -eq 2) "A timeout must allow a later successful attempt."
    Write-Host "PASS: timed-out sender is stopped and the next attempt can succeed."

    Reset-Fixture
    Set-Content "sender-settings.json" '{"large_output": true}' -Encoding ASCII
    $sent = Invoke-SendMessage -LogPath (Join-Path $fixtureDir $logName) -TimeoutSeconds 10 3>$null 6>$null
    Assert-True ($sent -is [bool] -and $sent) "Large stdout/stderr must not deadlock or change the Boolean result."
    Write-Host "PASS: stdout and stderr larger than pipe buffers are drained without deadlock."

    Reset-Fixture
    $lockPath = Join-Path $fixtureDir "$logName.report.lock"
    $heldLock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { Complete-Fixture } finally { $heldLock.Dispose() }
    Assert-True ((Get-AttemptCount) -eq 0) "A competing collector must not send while the lock is held."
    Assert-True ((Get-MarkerCount "env_switched") -eq 0) "A competing collector must not change round state."
    Complete-Fixture
    Assert-True ((Get-AttemptCount) -eq 1) "Finalization must resume after lock release."
    Write-Host "PASS: a held lock blocks finalization and its release allows recovery."

    Reset-Fixture
    Set-Content "sender-settings.json" '{"delay": 3}' -Encoding ASCII
    $workerInfo = New-Object System.Diagnostics.ProcessStartInfo
    $workerInfo.FileName = (Get-Process -Id $PID).Path
    $workerInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -PythonExecutable "{1}" -WorkerDirectory "{2}"' -f $PSCommandPath, $PythonExecutable, $fixtureDir
    $workerInfo.UseShellExecute = $false
    $workerInfo.CreateNoWindow = $true
    $worker = [Diagnostics.Process]::Start($workerInfo)
    try {
        $deadline = (Get-Date).AddSeconds(10)
        while ((Get-AttemptCount) -eq 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
        Assert-True ((Get-AttemptCount) -eq 1) "Worker did not reach the sender."
        Complete-Fixture
        Assert-True ($worker.WaitForExit(10000)) "Worker did not finish."
        Assert-True ($worker.ExitCode -eq 0) "Worker failed."
    }
    finally {
        if (-not $worker.HasExited) { $worker.Kill(); $worker.WaitForExit() }
        $worker.Dispose()
    }
    Complete-Fixture
    Assert-True ((Get-AttemptCount) -eq 1) "Concurrent processes sent duplicate reports."
    Assert-True ((Get-MarkerCount "report_sent") -eq 1) "Concurrent completion must persist one marker."
    Write-Host "PASS: concurrent collector processes send only once."

    Reset-Fixture
    Add-Content $logName "mainnet env_switched: 2026-09-13 09:20:56 (mode: 1, is_exec: 1)"
    Complete-Fixture
    Complete-Fixture
    Assert-True ((Get-AttemptCount) -eq 1) "Existing env_switched reports must be marked sent after successful retry."
    Assert-True (((Get-Content "env.txt") -join ',') -eq "1,0") "Existing env_switched state must not be advanced again."
    Write-Host "PASS: legacy completed report without report_sent sends once and stops."

    # Exercise the actual task wrapper with a fake collector, including the
    # streams omitted by its old 2>&1 capture. No real collector is invoked.
    Copy-Item -LiteralPath (Join-Path $repoDir "get_diff_task.ps1") -Destination $fixtureDir
    $workerInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Net main' -f (Join-Path $fixtureDir "get_diff_task.ps1")
    $collectorFixture = @'
param([string]$Net)
Write-Host "sendMsg: simulated HTTP 200"
Write-Warning "sendMsg.py exited with code"
exit 7
'@
    Set-Content -LiteralPath "get_diff.ps1" -Value $collectorFixture -Encoding UTF8
    $worker = [Diagnostics.Process]::Start($workerInfo)
    try {
        Assert-True ($worker.WaitForExit(10000)) "Task wrapper did not finish."
        Assert-True ($worker.ExitCode -eq 7) "Task wrapper must propagate the collector exit code."
    }
    finally {
        if (-not $worker.HasExited) { $worker.Kill(); $worker.WaitForExit() }
        $worker.Dispose()
    }
    $taskLogContent = Get-Content -LiteralPath "get_diff_task.log" -Raw
    Assert-True ($taskLogContent.Contains("sendMsg: simulated HTTP 200")) "Task log lost the sender's host output."
    Assert-True ($taskLogContent.Contains("sendMsg.py exited with code")) "Task log lost the sender's warning."
    Assert-True ($taskLogContent.Contains("done exit=7")) "Task log must record the collector exit code."
    Write-Host "PASS: task logging captures host/warning streams and propagates a nonzero exit."

    Set-Content -LiteralPath "get_diff.ps1" -Encoding UTF8 -Value @'
Write-Host "diagnostic before failure"
throw "simulated collector exception"
'@
    $worker = [Diagnostics.Process]::Start($workerInfo)
    try {
        Assert-True ($worker.WaitForExit(10000)) "Failing task wrapper did not finish."
        Assert-True ($worker.ExitCode -eq 1) "Task wrapper must fail on a terminating collector error."
    }
    finally {
        if (-not $worker.HasExited) { $worker.Kill(); $worker.WaitForExit() }
        $worker.Dispose()
    }
    $taskLogContent = Get-Content -LiteralPath "get_diff_task.log" -Raw
    Assert-True ($taskLogContent.Contains("diagnostic before failure")) "Task log must retain output before a terminating error."
    Assert-True ($taskLogContent.Contains("error: simulated collector exception")) "Task log must record the exception."
    Write-Host "PASS: task logging preserves diagnostics before a terminating exception."

    Write-Host "All 9 Windows report regression checks passed. No Discord requests were made."
}
finally {
    $env:PYTHONIOENCODING = $originalPythonEncoding
    Pop-Location
    Remove-Item -LiteralPath $fixtureDir -Recurse -Force
}
