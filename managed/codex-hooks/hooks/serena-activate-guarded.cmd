@echo off
"D:\Codex\tools\PowerShell\7.6.5\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "D:\Codex\.codex\hooks\serena-activate-guarded.ps1" %*
exit /b %ERRORLEVEL%
