@echo off
rem ---------------------------------------------------------------------------
rem gui.cmd - launch the desktop app
rem ---------------------------------------------------------------------------
rem Builds it on first run, then opens the window. Same as gui.sh, for people
rem who would rather double-click.
rem
rem   gui.cmd                  build if needed, then open the window
rem   gui.cmd --rebuild        rebuild first
rem   gui.cmd --browser        use the default browser instead of a window
rem
rem Requirements: Git for Windows (already needed by build.cmd), and Go the
rem first time only. See docs/gui.md.
rem ---------------------------------------------------------------------------
setlocal EnableExtensions
call "%~dp0windows\run-bash.cmd" gui.sh %*
set "RC=%ERRORLEVEL%"

rem Only hold the console open when something failed and this was started by
rem double-clicking (Explorer runs `cmd.exe /c ""C:\path\gui.cmd" "`, so
rem cmdcmdline ends with quote-space-quote; a real terminal ends with
rem quote-quote). A successful launch closes the console with the app.
if "%RC%"=="0" goto done
set "TAIL=%cmdcmdline:~-3%"
set "TAIL=%TAIL:"=Q%"
if "%TAIL%"=="Q Q" pause

:done
exit /b %RC%
