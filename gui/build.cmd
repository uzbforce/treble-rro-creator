@echo off
rem ---------------------------------------------------------------------------
rem build.cmd - build the desktop app on Windows
rem ---------------------------------------------------------------------------
rem   gui\build.cmd              console build (go run style debugging)
rem   gui\build.cmd --release    no console window behind the app
rem
rem Needs Git for Windows; Go and a MinGW-w64 gcc are downloaded into
rem stuff/tools/ when missing. See gui/README.md.
rem ---------------------------------------------------------------------------
setlocal EnableExtensions
call "%~dp0..\stuff\windows\run-bash.cmd" gui/build.sh %*
exit /b %ERRORLEVEL%
