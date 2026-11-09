@echo off
setlocal
set "SCRIPT=%~dp0uninstall.ps1"
cd /d "%USERPROFILE%"
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (set "PSEXE=pwsh") else (set "PSEXE=powershell")
%PSEXE% -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%
