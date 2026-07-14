@echo off
"D:\Codex\tools\python314-official\python.exe" "%~dp0codex-state-preflight.py" %*
exit /b %ERRORLEVEL%
