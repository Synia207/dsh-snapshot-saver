@echo off
chcp 65001 >nul
set "DSH_HOME=%USERPROFILE%\.dsh"
echo ========================================
echo DSH snapshot save
echo ========================================
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$p = (Get-ChildItem -LiteralPath (Join-Path $env:USERPROFILE '.dsh\bin') -Filter '1-*.ps1').FullName; & $p"
set "EXIT_CODE=%ERRORLEVEL%"
echo.
if not "%EXIT_CODE%"=="0" (
    echo Snapshot save failed. Exit code: %EXIT_CODE%
) else (
    echo Snapshot save completed.
)
pause
exit /b %EXIT_CODE%
