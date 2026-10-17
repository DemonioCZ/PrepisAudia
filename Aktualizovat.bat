@echo off
rem Stahne z GitHubu novejsi verzi programu (nastroj, NAVOD, Prepis.bat, data\opravy.txt).
rem Modely, nahravky a prepisy zustanou.
set "CESTA_NASTROJ=%~dp0nastroj"
set "CESTA_SKRIPT=%~dp0nastroj\aktualizace.ps1"
if exist "%CESTA_SKRIPT%" goto spustit

echo Chybi nastroj\aktualizace.ps1, stahuji ho z GitHubu...
if not exist "%CESTA_NASTROJ%" mkdir "%CESTA_NASTROJ%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $h=@{'User-Agent'='PrepisAudia-aktualizace';'Accept'='application/vnd.github.raw'}; $t=Join-Path $env:CESTA_NASTROJ 'github-token.txt'; if (Test-Path -LiteralPath $t) { $h['Authorization']='Bearer '+(Get-Content -LiteralPath $t -Raw).Trim() }; Invoke-WebRequest -UseBasicParsing -Uri 'https://api.github.com/repos/DemonioCZ/PrepisAudia/contents/nastroj/aktualizace.ps1?ref=main' -Headers $h -OutFile $env:CESTA_SKRIPT"
if exist "%CESTA_SKRIPT%" goto spustit
echo.
echo Skript se nepodarilo stahnout. Zkontrolujte pripojeni k internetu,
echo nebo u soukromeho repozitare token v souboru nastroj\github-token.txt.
echo.
pause
exit /b

:spustit
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%CESTA_SKRIPT%"
echo.
pause
