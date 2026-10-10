@echo off
rem Truck Mount - player install. Double-click, or drag your WoW folder / Wow.exe onto this file.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-client.ps1" "%~1"
pause
