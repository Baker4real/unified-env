@echo off
"D:\Codex\tools\PowerShell\7.6.5\pwsh.exe" -NoProfile -ExecutionPolicy Bypass -File "D:\Codex\.codex\hooks\codex-provider-stability-guard.ps1" %*
exit /b %ERRORLEVEL%
