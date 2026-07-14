@echo off
setlocal
set "SERENA_HOME=D:\Codex\.serena"
"D:\Codex\tools\PowerShell\7.6.3\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "D:\Codex\.codex\hooks\serena-behavior-guard.ps1" -Mode Reminder
exit /b %ERRORLEVEL%
