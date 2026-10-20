@echo off
rem ---------------------------------------------------------------------------
rem build.cmd - build the desktop app on Windows
rem ---------------------------------------------------------------------------
rem   gui\build.cmd              console build (go run style debugging)
rem   gui\build.cmd --release    no console window behind the app
rem
rem Needs Go and a MinGW-w64 gcc on PATH; Git for Windows is already required by
rem the rest of this project. See gui/README.md.
rem ---------------------------------------------------------------------------
setlocal EnableExtensions
call "%~dp0..\windows\run-bash.cmd" gui/build.sh %*
exit /b %ERRORLEVEL%
