@echo off
set "PYTHON_EXE=D:\Codex\tools\python313-official\python.exe"
if not exist "%PYTHON_EXE%" set "PYTHON_EXE=D:\hermes-data\.npm-global\python.exe"
if exist "%PYTHON_EXE%" (
  "%PYTHON_EXE%" "D:\Codex\.codex\hooks\codex-mobile-permission-guard.py" %*
) else (
  python "D:\Codex\.codex\hooks\codex-mobile-permission-guard.py" %*
)
