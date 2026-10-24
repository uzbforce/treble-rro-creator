@echo off
rem ---------------------------------------------------------------------------
rem treble-rro-creator.cmd - launch the desktop app
rem ---------------------------------------------------------------------------
rem Builds it on first run, then opens the window. The cmd companion to
rem treble-rro-creator.sh, for people who would rather double-click.
rem
rem   treble-rro-creator.cmd               build if needed, then open the window
rem   treble-rro-creator.cmd --rebuild     rebuild first
rem   treble-rro-creator.cmd --release     no console window (the default here)
rem   treble-rro-creator.cmd --browser     use the default browser instead
rem   treble-rro-creator.cmd -h            this message
rem
rem Requirements: Git for Windows (already needed by build.cmd); Go and a
rem MinGW-w64 gcc are downloaded on the first run. See docs/gui.md.
rem ---------------------------------------------------------------------------
setlocal EnableExtensions

if "%~1"=="-h" goto usage
if "%~1"=="--help" goto usage

rem The launcher closes its console either way (treble-rro-creator.sh always
rem starts the window in the background), so all that is left to decide here is
rem whether a failure should hold the window open. Explorer starts this file as
rem   cmd.exe /c ""C:\path\treble-rro-creator.cmd" "
rem and a terminal starts cmd.exe interactively, with no /c. The /c is the
rem difference: nobody is watching a double-click, and a terminal is.
rem
rem (The command line is not matched on its trailing quotes: Windows leaves a
rem space after them, so `" "` arrives as `" " ` and a last-three-characters
rem test never matches.)
set "DOUBLE="
echo %cmdcmdline% | "%SystemRoot%\System32\findstr.exe" /i /c:" /c " >nul && set "DOUBLE=1"

call "%~dp0stuff\windows\run-bash.cmd" treble-rro-creator.sh %*
set "RC=%ERRORLEVEL%"

rem Only hold the console open when something failed and this was started by
rem double-clicking; a successful launch has already closed the console.
if "%RC%"=="0" goto done
if defined DOUBLE pause

:done
exit /b %RC%

:usage
echo Treble RRO Creator - desktop app
echo.
echo   treble-rro-creator.cmd               build if needed, then open the window
echo   treble-rro-creator.cmd --rebuild     rebuild first (after a git pull, say)
echo   treble-rro-creator.cmd --release     no console window (the default here)
echo   treble-rro-creator.cmd --detach      accepted for scripts; the console closes anyway
echo   treble-rro-creator.cmd --browser     no window; use the default browser
echo   treble-rro-creator.cmd -clone PATH   start on a different clone
echo   treble-rro-creator.cmd -h            this message
echo.
echo Builds on the first run (Go and MinGW-w64 gcc are downloaded);
echo later launches open straight away. Full guide: docs\gui.md
exit /b 0
