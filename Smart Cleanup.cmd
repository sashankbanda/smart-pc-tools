@echo off
rem Double-click this to open Smart Cleanup.
rem It shows where your space goes and what can go (duplicates, junk, old downloads, ...),
rem cleans up only what you tick, and can sort a messy folder - with an undo.

start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0app\SmartCleanup.ps1"
