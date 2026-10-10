@echo off
rem OC Designer - editeur du menu de demarrage OpenCore
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0OCDesigner.ps1" %*
