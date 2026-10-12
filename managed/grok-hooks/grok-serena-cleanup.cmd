@echo off
setlocal
set "SERENA_HOME=D:\Codex\.serena"
"D:\Codex\tools\python315-official\pythonw.exe" -I -S -B -X utf8 "D:\Codex\.codex\hooks\lib\hidden-console-launcher.py" "D:\Codex\tools\python315-official\python.exe" -I -S -B -X utf8 "%~dp0grok-host-hook.py" Cleanup
exit /b %ERRORLEVEL%
