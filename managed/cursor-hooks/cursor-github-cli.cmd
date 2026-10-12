@echo off
setlocal
"D:\Codex\tools\python315-official\pythonw.exe" -I -S -B -X utf8 "D:\Codex\.codex\hooks\lib\hidden-console-launcher.py" "D:\Codex\tools\python315-official\python.exe" -I -S -B -X utf8 "%~dp0cursor-host-hook.py" GitHubCli
exit /b %ERRORLEVEL%
