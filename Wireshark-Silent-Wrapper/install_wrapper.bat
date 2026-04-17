@echo off
setlocal

set "RAW_PS_URL=https://gist.githubusercontent.com/kpawnd/08ebfc5cc8558b8710e18de2b11c1157/raw/837972961d65ad18137feb10498f515bdcd90b52/wireshark_deployment.ps1"

where pwsh >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    set "PS_EXE=pwsh"
) else (
    set "PS_EXE=powershell.exe"
)

"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "& { param([string]$Url,[string[]]$UserArgs) $code=(Invoke-WebRequest -UseBasicParsing -Uri $Url).Content; & ([scriptblock]::Create($code)) @UserArgs }" "%RAW_PS_URL%" %*
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
    echo [ERROR] Deployment failed with exit code %EXIT_CODE%.
    endlocal
    exit /b %EXIT_CODE%
)

echo [INFO] Deployment completed successfully.
endlocal
exit /b 0