@echo off
setlocal
title AIy - setup
cd /d "%~dp0"
echo.
echo  AIy setup wizard. Keep this window open.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup\Setup-AIy.ps1" -Mode menu
echo.
pause
