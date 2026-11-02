@echo off
setlocal
title After Effects MCP Setup

if not exist "%~dp0ae-mcp-setup.ps1" (
    echo [X] ae-mcp-setup.ps1 was not found next to install.cmd.
    echo     Extract the whole zip first, then run install.cmd again.
    echo.
    pause
    exit /b 1
)

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0ae-mcp-setup.ps1" %*
set "RC=%ERRORLEVEL%"

echo.
pause
exit /b %RC%
