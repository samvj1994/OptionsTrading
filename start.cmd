@echo off
setlocal
cd /d "%~dp0"

where py >nul 2>nul
if errorlevel 1 (
  where python >nul 2>nul
  if errorlevel 1 (
    echo Python 3.10 or newer is required. Install Python, then run this command again.
    exit /b 1
  )
  set "PYTHON=python"
) else (
  set "PYTHON=py -3"
)

%PYTHON% -c "import sys; raise SystemExit(sys.version_info < (3,10))"
if errorlevel 1 (
  echo Python 3.10 or newer is required. Upgrade Python, then run this command again.
  exit /b 1
)

if /I "%~1"=="--preview" set "DASHBOARD_TEST_PREVIEW=1"
%PYTHON% server.py
