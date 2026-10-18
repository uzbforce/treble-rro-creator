@echo off
rem ---------------------------------------------------------------------------
rem run-bash.cmd - run one of this project's shell scripts under Git Bash
rem ---------------------------------------------------------------------------
rem Usage:  windows\run-bash.cmd <script.sh> [args...]
rem
rem Kept in one place so build.cmd / setup.cmd / cleanup.cmd cannot drift apart.
rem ---------------------------------------------------------------------------
setlocal EnableExtensions

set "SCRIPT=%~1"
if "%SCRIPT%"=="" (
    echo Usage: windows\run-bash.cmd ^<script.sh^> [args...]
    exit /b 1
)

rem Project root = parent of this file's directory
set "ROOT=%~dp0.."
set "BASH="

rem 1) Standard Git for Windows install locations
for %%B in (
    "%ProgramFiles%\Git\bin\bash.exe"
    "%LocalAppData%\Programs\Git\bin\bash.exe"
) do if not defined BASH if exist "%%~B" set "BASH=%%~B"

rem 2) Any bash on PATH, but only accept a real MSYS one (never WSL's)
if not defined BASH (
    for /f "delims=" %%B in ('%SystemRoot%\System32\where.exe bash.exe 2^>nul') do if not defined BASH call :try_bash "%%B"
)

if not defined BASH goto no_bash

rem Collect arguments after the script name (cmd's %* keeps the script too)
set "ARGS="
:collect_args
shift
if "%~1"=="" goto args_done
set ARGS=%ARGS% "%~1"
goto collect_args
:args_done

rem Run from the project root; a relative script path avoids handing bash a
rem C:\... path, where it would treat the backslashes as escape characters.
pushd "%ROOT%" >nul
"%BASH%" --noprofile --norc "./%SCRIPT%" %ARGS%
set "RC=%ERRORLEVEL%"
popd >nul
exit /b %RC%

rem ---------------------------------------------------------------------------
:try_bash
rem Accept the candidate only if it reports an MSYS/Cygwin environment.
"%~1" -c "uname -s" 2>nul | "%SystemRoot%\System32\findstr.exe" /i "MINGW MSYS CYGWIN" >nul
if errorlevel 1 exit /b 0
set "BASH=%~1"
exit /b 0

:no_bash
echo.
echo   Git for Windows was not found.
echo   Install it from https://git-scm.com/download/win and try again.
echo   WSL's bash.exe is not supported - this tool needs Git Bash (MSYS2).
echo.
pause
exit /b 1
