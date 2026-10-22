@echo off
rem ---------------------------------------------------------------------------
rem build.cmd - Windows entry point
rem ---------------------------------------------------------------------------
rem Finds Git for Windows (never WSL) and runs build.sh, which does everything:
rem
rem   build.cmd                  build (downloads the toolchain on first run)
rem   build.cmd setup            install / repair the build tools
rem   build.cmd doctor           check the toolchain
rem   build.cmd check            validate config.env
rem   build.cmd clean            remove build output
rem   build.cmd clean --all      start over for a different device
rem
rem Requirements: Git for Windows + JDK 17+ on PATH.
rem Tip: run this from cmd or PowerShell (.\\build.cmd), not from WSL.
rem ---------------------------------------------------------------------------
setlocal EnableExtensions
call "%~dp0stuff\windows\run-bash.cmd" build.sh %*
set "RC=%ERRORLEVEL%"

rem Keep the window open only when double-clicked from Explorer. Explorer runs
rem   cmd.exe /c ""C:\path\build.cmd" "
rem (cmdcmdline ends with quote-space-quote), while a terminal -- including
rem PowerShell -- ends with just quote-quote. Replacing quotes with Q makes the
rem two cases easy to compare.
set "TAIL=%cmdcmdline:~-3%"
set "TAIL=%TAIL:"=Q%"
if "%TAIL%"=="Q Q" pause

exit /b %RC%
