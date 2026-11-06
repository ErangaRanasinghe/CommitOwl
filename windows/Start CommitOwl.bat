@echo off
rem CommitOwl - daily auto commit and push for electronics projects
rem Opens the CommitOwl window with no PowerShell console behind it.
rem Developed by: EMR Industries - Version 1.3 - Built 2026.11.06
start "" wscript.exe "%~dp0commitowl-hidden.vbs" gui
exit
