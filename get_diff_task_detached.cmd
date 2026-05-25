@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "NET=%~1"
if "%NET%"=="" set "NET=auto"

cd /d "%SCRIPT_DIR%"

echo %DATE% %TIME% detached trigger net=%NET% >> "%SCRIPT_DIR%get_diff_task_cmd.log"
start "" /b powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SCRIPT_DIR%get_diff_task.ps1" -Net "%NET%"

exit /b 0
