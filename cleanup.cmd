@echo off
rem ---------------------------------------------------------------------------
rem cleanup.cmd - Windows launcher for cleanup.sh
rem ---------------------------------------------------------------------------
rem Interactive: quick clean (build artifacts) or full clean (re-target device).
rem ---------------------------------------------------------------------------
call "%~dp0windows\run-bash.cmd" cleanup.sh %*
set "RC=%ERRORLEVEL%"
rem Keep the window open when double-clicked from Explorer.
echo "%cmdcmdline%" | "%SystemRoot%\System32\find.exe" /i "%~f0" >nul && pause
exit /b %RC%
