@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "NET=%~1"
if "%NET%"=="" set "NET=main"

cd /d "%SCRIPT_DIR%"

echo %DATE% %TIME% cmd start net=%NET%>>"%SCRIPT_DIR%get_diff_task_cmd.log"
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SCRIPT_DIR%get_diff_task.ps1" -Net "%NET%" >>"%SCRIPT_DIR%get_diff_task_cmd.log" 2>&1
set "EXIT_CODE=%ERRORLEVEL%"
echo %DATE% %TIME% cmd done exit=%EXIT_CODE%>>"%SCRIPT_DIR%get_diff_task_cmd.log"

exit /b %EXIT_CODE%
