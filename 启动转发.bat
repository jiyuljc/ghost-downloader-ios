@echo off
rem ================================================================
rem  Ghost Downloader Relay - double-click to start
rem
rem  Keep this file pure ASCII. cmd.exe reads a .bat using the
rem  console code page (GBK on Chinese Windows), so UTF-8 Chinese
rem  in here gets mis-decoded and fragments of it turn into commands.
rem  All Chinese output comes from tools\gd-relay.py instead, where
rem  Python writes through the Windows console API and never garbles.
rem ================================================================
setlocal
title Ghost Downloader Relay

cd /d "%~dp0"

set "PY="
where python >nul 2>nul && set "PY=python"
if not defined PY (
  where py >nul 2>nul && set "PY=py"
)

if not defined PY (
  echo.
  echo   [X] Python not found.
  echo.
  echo   Install Python 3, and during setup tick:
  echo       [x] Add python.exe to PATH
  echo.
  echo   Download: https://www.python.org/downloads/
  echo.
  echo   Then run this file again.
  echo.
  pause
  exit /b 1
)

%PY% "%~dp0tools\gd-relay.py" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
  echo.
  echo   [X] Relay exited with code %RC%.
  echo   Window kept open so you can read the error above.
  echo.
  pause
)

endlocal
