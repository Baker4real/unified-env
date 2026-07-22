@echo off
setlocal
set "SERENA_HOME=D:\Codex\.serena"
"D:\Codex\tools\PowerShell\7.6.4\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0serena-behavior-guard.ps1" -Mode Activation
exit /b %ERRORLEVEL%
