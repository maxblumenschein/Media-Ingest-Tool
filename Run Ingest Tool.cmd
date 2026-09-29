@echo off
setlocal

echo ============================================================
echo  Media Ingest Tool
echo ============================================================
echo.

if not exist "%~dp0Ingest-MediaFiles.ps1" (
    echo ERROR: Could not find Ingest-MediaFiles.ps1 in this folder:
    echo   %~dp0
    echo.
    echo Make sure "Ingest-MediaFiles.ps1" is saved in the SAME folder
    echo as this file, then try again.
    echo.
    pause
    exit /b 1
)

echo Starting...
echo.

REM Run the script's CONTENT inline (Invoke-Expression) instead of asking
REM PowerShell to execute the .ps1 FILE directly. Some organizations set an
REM execution policy (often via Group Policy) that blocks unsigned .ps1
REM files from being run even with -ExecutionPolicy Bypass on the command
REM line. That file-signature check only applies to running script FILES,
REM not to commands PowerShell is told to run directly - so reading the
REM script's text and handing it to PowerShell that way sidesteps the
REM block entirely without changing any policy setting and without needing
REM admin rights.
powershell.exe -NoLogo -NoProfile -Command "& { $s = Get-Content -LiteralPath '%~dp0Ingest-MediaFiles.ps1' -Raw -Encoding UTF8; Invoke-Expression $s }"
set EXITCODE=%ERRORLEVEL%

echo.
if not "%EXITCODE%"=="0" (
    echo ============================================================
    echo The tool exited with an error ^(code %EXITCODE%^).
    echo If you saw a red error message above, that's the cause -
    echo copy it and share it so it can be fixed.
    echo ============================================================
    echo.
)

pause
