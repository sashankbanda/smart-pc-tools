@echo off
rem Double-click this to open Smart Transfer.
rem It copies photos, videos and files from an iPhone, an Android phone or any folder or
rem drive, checks every file, and only then offers to remove the originals.

start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0app\SmartTransfer.ps1"
