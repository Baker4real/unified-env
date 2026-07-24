@echo off
"D:\Codex\tools\PowerShell\7.6.4\pwsh.exe" -NoLogo -NoProfile -NonInteractive -File "D:\Codex\.codex\scripts\invoke-safe-tree-delete.ps1" %*
exit /b %ERRORLEVEL%
