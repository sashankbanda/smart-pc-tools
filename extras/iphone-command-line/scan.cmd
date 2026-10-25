@echo off
rem Double-click this to see what is on a connected iPhone without copying anything:
rem file counts, photos / videos / other, sizes and dates per folder, and a breakdown
rem by file type. The report is also saved as a text file (the path is printed).

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Copy-IPhoneMedia.ps1" -ScanOnly

echo.
pause
