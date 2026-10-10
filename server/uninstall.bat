@echo off
title Truck Mount - uninstall
rem Double-click, or drag worldserver.conf onto this file.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Uninstall "%~1"
echo.
pause
