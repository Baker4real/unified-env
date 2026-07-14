@echo off
"D:\Codex\tools\python314-official\python.exe" "D:\Codex\.codex\hooks\codex-state-preflight.py" %*
exit /b %ERRORLEVEL%
