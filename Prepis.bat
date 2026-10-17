@echo off
rem Prepis nahravky na text. Spustte dvojklikem, nebo na tento soubor pretahnete nahravky.
rem Otevre se stranka v prohlizeci, program bezi skryte na pozadi (bez okna).
start "" conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0nastroj\prepis.ps1" %*
