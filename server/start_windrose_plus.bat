@echo off
where pwsh >nul 2>&1
if %ERRORLEVEL%==0 (
    pwsh -ExecutionPolicy Bypass -File "%~dp0windrose_plus_server.ps1" %*
) else (
    powershell -ExecutionPolicy Bypass -File "%~dp0windrose_plus_server.ps1" %*
)
