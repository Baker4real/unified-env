@echo off
setlocal
set "CODEX_PYTHON=D:\Codex\tools\python314-official\python.exe"
set "WRAPPER=%~dp0install_skill_guarded.py"
if not exist "%CODEX_PYTHON%" (
  >&2 echo ERROR: missing managed Python runtime: %CODEX_PYTHON%
  exit /b 2
)
if not exist "%WRAPPER%" (
  >&2 echo ERROR: missing guarded skill wrapper: %WRAPPER%
  exit /b 2
)
"%CODEX_PYTHON%" -X utf8 -I "%WRAPPER%" %*
exit /b %ERRORLEVEL%
