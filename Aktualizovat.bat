@echo off
rem Stahne z GitHubu novejsi verzi programu. Modely, nahravky, prepisy a vase opravy zustanou.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0nastroj\aktualizace.ps1"
echo.
pause
