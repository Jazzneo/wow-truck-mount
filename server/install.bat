@echo off
title Truck Mount installer
rem Double-click, or drag worldserver.conf onto this file.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" "%~1"
echo.
pause
