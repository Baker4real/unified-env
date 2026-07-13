@echo off
"D:\Codex\tools\PowerShell\7.6.3\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "D:\Codex\.codex\hooks\serena-dashboard-guard.ps1" %*
exit /b %ERRORLEVEL%
