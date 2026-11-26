@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -File "%~dp0ModAudit.ps1" -Mode Review
pause
