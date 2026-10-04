@echo off
chcp 65001 >nul
set "DSH_HOME=%USERPROFILE%\.dsh"
echo ========================================
echo DSH snapshot restore
echo ========================================
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$p = (Get-ChildItem -LiteralPath (Join-Path $env:USERPROFILE '.dsh\bin') -Filter '2-*.ps1').FullName; & $p"
set "EXIT_CODE=%ERRORLEVEL%"
echo.
if not "%EXIT_CODE%"=="0" (
    echo Snapshot restore failed. Exit code: %EXIT_CODE%
) else (
    echo Snapshot restore completed. Restart DSH after this window.
)
pause
exit /b %EXIT_CODE%
