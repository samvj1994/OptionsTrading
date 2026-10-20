@echo off
setlocal
cd /d "%~dp0"

where ruby >nul 2>nul
if errorlevel 1 (
  echo Ruby is required. Install Ruby 2.6 or newer, then run this command again.
  exit /b 1
)

where bundle >nul 2>nul
if errorlevel 1 (
  echo Bundler is required. Install it with: gem install bundler
  exit /b 1
)

bundle check >nul 2>nul
if errorlevel 1 (
  echo Installing dashboard dependencies...
  bundle install
  if errorlevel 1 exit /b 1
)

if /I "%~1"=="--preview" set DASHBOARD_TEST_PREVIEW=1
bundle exec ruby server.rb
