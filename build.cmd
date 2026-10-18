@echo off
rem ---------------------------------------------------------------------------
rem build.cmd - Windows launcher for build.sh
rem ---------------------------------------------------------------------------
rem Requires Git for Windows (bash.exe) and a JDK 17+. Run setup.cmd first.
rem Extra arguments are passed through, e.g.:  build.cmd --check
rem ---------------------------------------------------------------------------
call "%~dp0windows\run-bash.cmd" build.sh %*
set "RC=%ERRORLEVEL%"
rem Keep the window open when double-clicked from Explorer (full path appears
rem in cmdcmdline only in that case).
echo "%cmdcmdline%" | "%SystemRoot%\System32\find.exe" /i "%~f0" >nul && pause
exit /b %RC%
