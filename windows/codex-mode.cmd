@echo off
setlocal
set "SCRIPT=%~dp0codex-mode.ps1"
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (set "PSEXE=pwsh") else (set "PSEXE=powershell")
%PSEXE% -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
