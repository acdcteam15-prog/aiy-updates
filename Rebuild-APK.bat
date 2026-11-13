@echo off
setlocal
title AIy - rebuild APK
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup\Setup-AIy.ps1" -Mode rebuild
echo.
pause
