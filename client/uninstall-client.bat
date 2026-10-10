@echo off
rem Truck Mount - player uninstall. Double-click, or drag your WoW folder onto this file.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-client.ps1" -Uninstall "%~1"
pause
