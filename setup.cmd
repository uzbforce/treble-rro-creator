@echo off
rem ---------------------------------------------------------------------------
rem setup.cmd - Windows launcher for setup.sh
rem ---------------------------------------------------------------------------
rem Downloads the Windows build-tools (aapt2.exe, zipalign.exe, apksigner) and
rem a resource dictionary, then tells you to run build.cmd.
rem ---------------------------------------------------------------------------
call "%~dp0windows\run-bash.cmd" setup.sh %*
set "RC=%ERRORLEVEL%"
rem Keep the window open when double-clicked from Explorer.
echo "%cmdcmdline%" | "%SystemRoot%\System32\find.exe" /i "%~f0" >nul && pause
exit /b %RC%
