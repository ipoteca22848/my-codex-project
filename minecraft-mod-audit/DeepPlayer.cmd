@echo off
cd /d "%~dp0"
start "Minecraft Mod Audit" /max powershell.exe -NoProfile -NoExit -File "%~dp0ModAudit.ps1" -Deep
