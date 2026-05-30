@echo off
setlocal
net session >nul 2>&1
if not "%errorlevel%"=="0" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile -ExecutionPolicy Bypass -STA -File ""%~dp0DuneManager-GUI.ps1""' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0DuneManager-GUI.ps1"
