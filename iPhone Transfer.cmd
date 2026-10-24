@echo off
rem Double-click this to open the iPhone Transfer app.
rem It finds your iPhone, shows what is on it, copies the folders you pick,
rem checks every file, and only then offers to free up space on the phone.

start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0app\iPhoneTransfer.ps1"
