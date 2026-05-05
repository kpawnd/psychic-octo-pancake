@echo off
setlocal

set "RAW_PS_URL=https://raw.githubusercontent.com/kpawnd/psychic-octo-pancake/main/SteamCMD-Updater-Service/Remove-UpdateService.ps1"

where pwsh >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    set "PS_EXE=pwsh"
) else (
    set "PS_EXE=powershell.exe"
)

"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "& { $code=(Invoke-WebRequest -UseBasicParsing -Uri '%RAW_PS_URL%').Content; & ([scriptblock]::Create($code)) }"
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
    echo [ERROR] Cleanup failed with exit code %EXIT_CODE%.
    endlocal
    exit /b %EXIT_CODE%
)

echo [INFO] Cleanup completed successfully.
endlocal
exit /b 0
