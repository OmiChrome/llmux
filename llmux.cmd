@echo off
rem llmux launcher for cmd.exe: uses Python if installed, else PowerShell.
rem Keep llmux.cmd next to llmux.py / llmux.ps1 and put that folder on PATH.
setlocal
python -c "import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)" >nul 2>nul
if not errorlevel 1 if exist "%~dp0llmux.py" goto use_python
py -3 -c "import sys" >nul 2>nul
if not errorlevel 1 if exist "%~dp0llmux.py" goto use_py
where pwsh >nul 2>nul
if not errorlevel 1 goto use_pwsh
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0llmux.ps1" %*
exit /b %errorlevel%
:use_python
python "%~dp0llmux.py" %*
exit /b %errorlevel%
:use_py
py -3 "%~dp0llmux.py" %*
exit /b %errorlevel%
:use_pwsh
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0llmux.ps1" %*
exit /b %errorlevel%
