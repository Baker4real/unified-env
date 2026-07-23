@echo off
"D:\Codex\tools\python314-official\pythonw.exe" -I -S -B -X utf8 "%~dp0lib\hidden-console-launcher.py" "D:\Codex\tools\python314-official\python.exe" -I -S -B -X utf8 "%~dp0codex-state-preflight.py" %*
exit /b %ERRORLEVEL%
