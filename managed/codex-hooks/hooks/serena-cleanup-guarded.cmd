@echo off
setlocal
set "SERENA_HOME=D:\Codex\.serena"
"D:\Codex\tools\python314-official\pythonw.exe" -I -S -B -X utf8 "%~dp0lib\hidden-console-launcher.py" "D:\Codex\tools\PowerShell\7.6.5\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0serena-behavior-guard.ps1" -Mode Cleanup
exit /b %ERRORLEVEL%
