@echo off
rem Double-click this to open Smart Memory.
rem It shows how full the memory is, closes the apps you pick (they can still ask to save),
rem stops apps from starting with Windows, and tidies up memory before something heavy.

start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0app\SmartMemory.ps1"
