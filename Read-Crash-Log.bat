@echo off
setlocal
title AIy - read crash log
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup\Setup-AIy.ps1" -Mode crashlog
echo.
pause
