@echo off
setlocal
"D:\Codex\tools\python314-official\pythonw.exe" -I -S -B -X utf8 "D:\Codex\.codex\hooks\lib\hidden-console-launcher.py" "D:\Codex\tools\PowerShell\7.6.5\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "D:\Codex\.codex\hooks\codex-github-cli-guard.ps1"
exit /b %ERRORLEVEL%
