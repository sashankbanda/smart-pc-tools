@echo off
rem Double-click this to copy photos and videos off a connected iPhone.
rem It asks for everything it needs - no command line required.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Copy-IPhoneMedia.ps1"

echo.
pause
