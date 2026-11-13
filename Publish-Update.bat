@echo off
setlocal
title AIy - publish the last build
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup\Setup-AIy.ps1" -Mode publish
echo.
pause
