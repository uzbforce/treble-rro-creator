@echo off
rem ---------------------------------------------------------------------------
rem build.cmd - build the desktop app on Windows
rem ---------------------------------------------------------------------------
rem   gui\build.cmd              console build (go run style debugging)
rem   gui\build.cmd --release    no console window behind the app
rem
rem Needs a MinGW-w64 gcc on PATH; Go is downloaded into stuff/tools/go/ when
rem missing, and Git for Windows is already required by the rest of this
rem project. See gui/README.md.
rem ---------------------------------------------------------------------------
setlocal EnableExtensions
call "%~dp0..\stuff\windows\run-bash.cmd" gui/build.sh %*
exit /b %ERRORLEVEL%
