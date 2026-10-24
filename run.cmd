@echo off
rem Double-click this to copy photos and videos off a connected iPhone.
rem It finds the phone, scans the folders you pick, shows what is there,
rem and asks where to put the files - no command line required.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Copy-IPhoneMedia.ps1"

echo.
pause
