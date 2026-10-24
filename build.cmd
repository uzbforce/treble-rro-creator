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
rem and a terminal -- cmd, PowerShell, VS Code -- starts cmd.exe with no /c. The
rem /c is the difference, and matching on it is the only test that works:
rem Windows leaves a space after the trailing quotes, so a last-three-characters
rem test never matches.
set "DOUBLE="
echo %cmdcmdline% | "%SystemRoot%\System32\findstr.exe" /i /c:" /c " >nul && set "DOUBLE=1"
if defined DOUBLE pause

exit /b %RC%
