@echo off
rem ---------------------------------------------------------------------------
rem gui.cmd - launch the desktop app
rem ---------------------------------------------------------------------------
rem Builds it on first run, then opens the window. Same as gui.sh, for people
rem who would rather double-click.
rem
rem   gui.cmd                  build if needed, then open the window
rem   gui.cmd --rebuild        rebuild first
rem   gui.cmd --detach         let the console close (implies --release)
rem   gui.cmd --browser        use the default browser instead of a window
rem
rem Requirements: Git for Windows (already needed by build.cmd), and Go the
rem first time only. See docs/gui.md.
rem ---------------------------------------------------------------------------
setlocal EnableExtensions

rem Explorer starts this file as `cmd.exe /c ""C:\path\gui.cmd" "`, so the
rem command line ends with quote-space-quote; a real terminal ends with
rem quote-quote. A double-click is the case where nobody wants a console sitting
rem behind the app, so that launch gets the release build and is handed to the
rem shell: this console closes as soon as the window is up. Started from a
rem terminal, the output stays where you can read it.
set "TAIL=%cmdcmdline:~-3%"
set "TAIL=%TAIL:"=Q%"
set "DOUBLE="
if "%TAIL%"=="Q Q" set "DOUBLE=1"

set "FLAGS="
if defined DOUBLE set "FLAGS=--detach"

call "%~dp0stuff\windows\run-bash.cmd" gui.sh %FLAGS% %*
set "RC=%ERRORLEVEL%"

rem Only hold the console open when something failed and this was started by
rem double-clicking; a successful launch is already gone by now with --detach.
if "%RC%"=="0" goto done
if defined DOUBLE pause

:done
exit /b %RC%
