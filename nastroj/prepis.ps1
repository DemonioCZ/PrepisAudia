# Přepis nahrávek na text pomocí whisper.cpp, ovládaný přes webovou stránku.
# Spouští se přes Prepis.bat: tento skript běží skrytě jako malý místní server
# (jen pro tento počítač) a v prohlížeči otevře stránku, kde je vše vidět.
# Přepis (.txt) se uloží vedle zvukového souboru, druhá verze s časy jako „… - časy.txt“.
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Soubory)

$ErrorActionPreference = 'Stop'
$nastroj = $PSScriptRoot
$koren   = Split-Path $nastroj -Parent
$naWindows = -not $IsLinux

# Modely ve složce Modely. Na stránce se nabídnou jen ty, které tam opravdu jsou.
$modelyDir = Join-Path $koren 'Modely'
$vadModel = Join-Path $modelyDir 'ggml-silero-v5.1.2.bin'   # rozpoznání řeči, nepovinné
$vsechnyModely = @(
    [pscustomobject]@{ klic = 'turbo'; soubor = 'ggml-large-v3-turbo.bin'; nazev = 'Rychlý (turbo)' }
    [pscustomobject]@{ klic = 'large'; soubor = 'ggml-large-v3.bin'; nazev = 'Přesnější (large, asi 2× pomalejší)' }
)
$cliCpu = Join-Path $nastroj 'whisper-cli.exe'
$towav  = Join-Path $nastroj 'towav.exe'
$stranka = Join-Path $nastroj 'stranka.html'
$dataDir = Join-Path $koren 'data'
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$opravyCesta = Join-Path $dataDir 'opravy.txt'
$historieCesta = Join-Path $dataDir 'historie.txt'
$volbaCesta = Join-Path $dataDir 'model.txt'   # naposledy zvolený model
$gpuDir = Join-Path $nastroj 'gpu'
$gpuZip = 'https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-cublas-12.4.0-bin-x64.zip'

# Dočasná složka s jednoduchým názvem (programy neumí diakritiku v cestě)
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) 'whisper_prepis'
if ($tmp -match '[^\x00-\x7F]') { $tmp = Join-Path $env:PUBLIC 'whisper_prepis' }
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$logCesta = Join-Path $tmp 'server.log'
function Log($zprava) { Add-Content -LiteralPath $logCesta -Value "$(Get-Date -Format s) $zprava" -Encoding UTF8 }

function Hlaska($zprava) {
    Log $zprava
    if ($naWindows) {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show($zprava, 'Přepis nahrávek')
    } else { Write-Host $zprava }
}

# ---------- Kontroly při spuštění ----------
foreach ($f in @($cliCpu, $towav, $stranka)) {
    if (-not (Test-Path $f)) { Hlaska "Chybí soubor: $f"; exit }
}
$modely = @($vsechnyModely | Where-Object { Test-Path (Join-Path $modelyDir $_.soubor) })
if (-not $modely) { Hlaska "Chybí model (např. ggml-large-v3-turbo.bin).`nModel musí ležet ve složce Modely vedle Prepis.bat."; exit }
$zvolenyModel = $modely[0].klic
if (Test-Path -LiteralPath $volbaCesta) {
    $ulozeny = ([System.IO.File]::ReadAllText($volbaCesta)).Trim()
    if ($modely | Where-Object { $_.klic -eq $ulozeny }) { $zvolenyModel = $ulozeny }
}

function Model-Info($klic) { $modely | Where-Object { $_.klic -eq $klic } | Select-Object -First 1 }
function Model-Nazev($klic) { $m = Model-Info $klic; if ($m) { $m.nazev } else { '' } }

# Cesta k modelu pro whisper (bez diakritiky, jinak krátká cesta 8.3)
function Cesta-Modelu($klic) { Kratka-Cesta (Join-Path $modelyDir (Model-Info $klic).soubor) }
function Kratka-Cesta($cesta) {
    if ($naWindows -and $cesta -match '[^\x00-\x7F]') {
        $cesta = (New-Object -ComObject Scripting.FileSystemObject).GetFile($cesta).ShortPath
    }
    return $cesta
}

if ($naWindows) {
    $sys32 = Join-Path $env:windir 'System32'
    $chybi = @('msvcp140.dll', 'vcruntime140_1.dll', 'vcomp140.dll') | Where-Object { -not (Test-Path (Join-Path $sys32 $_)) }
    if ($chybi) {
        Start-Process 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
        Hlaska "V počítači chybí knihovna Microsoft Visual C++ (stačí jednou nainstalovat).`nStahování se právě otevřelo. Nainstalujte ji a pak Prepis.bat spusťte znovu."
        exit
    }
    if ((Cesta-Modelu $zvolenyModel) -match '[^\x00-\x7F]') {
        Hlaska "Cesta ke složce s nástrojem obsahuje diakritiku:`n$koren`nPřesuňte složku jinam, např. do C:\Whisper."
        exit
    }
}

# ---------- Stav aplikace ----------
$vlakna = [Math]::Max(1, [Environment]::ProcessorCount)
$polozky = New-Object System.Collections.ArrayList
$gpuStav = 'zadna'      # zadna | stahuji | pripravena | selhala
$gpuNazev = ''
$gpuJob = $null
$autoVyber = -not $Soubory
$konec = $false
$cisloUlohy = 0

if ($naWindows) {
    $nvidia = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'NVIDIA' }
    if ($nvidia) {
        $gpuNazev = $nvidia[0].Name
        if (Test-Path (Join-Path $gpuDir 'whisper-cli.exe')) {
            $gpuStav = 'pripravena'
        } else {
            # Jednorázové stažení verze pro grafiku na pozadí
            $gpuStav = 'stahuji'
            $gpuJob = Start-Job -ArgumentList $gpuZip, $gpuDir -ScriptBlock {
                param($url, $cil)
                $ProgressPreference = 'SilentlyContinue'
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $zip = Join-Path ([System.IO.Path]::GetTempPath()) 'whisper-gpu.zip'
                $rozbal = Join-Path ([System.IO.Path]::GetTempPath()) 'whisper-gpu'
                Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $rozbal
                Expand-Archive -Path $zip -DestinationPath $rozbal -Force
                New-Item -ItemType Directory -Force -Path $cil | Out-Null
                Get-ChildItem (Join-Path $rozbal 'Release') -Include '*.dll' -Recurse | Copy-Item -Destination $cil -Force
                Get-ChildItem (Join-Path $rozbal 'Release') -Include 'whisper-cli.exe' -Recurse | Copy-Item -Destination $cil -Force
                Remove-Item -Force -ErrorAction SilentlyContinue $zip
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $rozbal
            }
        }
    }
}

function Pridej-Soubory($cesty) {
    foreach ($c in $cesty) {
        if (-not $c -or -not (Test-Path -LiteralPath $c)) { continue }
        $info = Get-Item -LiteralPath $c
        [void]$polozky.Add([pscustomobject]@{
            Id = $polozky.Count; Nazev = $info.Name; Cesta = $info.FullName
            Stav = 'ceka'; Procenta = 0; Nahled = @(); Cil = ''; Chyba = ''
            Start = $null; Sekundy = 0; Gpu = $false; Model = $zvolenyModel; CilCasy = ''; Delka = 0
            Proc = $null; Vstup = ''; Wav = ''; Zaklad = ''; Out = ''; Err = ''
        })
    }
}

function Vyber-Soubory {
    if (-not $naWindows) {
        # Testovací režim mimo Windows
        if ($env:PREPIS_TEST_SOUBORY) { $s = $env:PREPIS_TEST_SOUBORY -split '\|'; $env:PREPIS_TEST_SOUBORY = ''; return $s }
        return @()
    }
    Add-Type -AssemblyName System.Windows.Forms
    $vlastnik = New-Object System.Windows.Forms.Form
    $vlastnik.TopMost = $true
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'Vyberte nahrávku k přepisu (lze i více najednou)'
    $dlg.Filter = 'Zvukové soubory (*.mp3;*.wav;*.flac)|*.mp3;*.wav;*.flac|Všechny soubory (*.*)|*.*'
    $dlg.Multiselect = $true
    $vysledek = $dlg.ShowDialog($vlastnik)
    $vlastnik.Dispose()
    if ($vysledek -ne [System.Windows.Forms.DialogResult]::OK) { return @() }
    return $dlg.FileNames
}

function Spust($exe, [string[]]$argumenty, $out, $err) {
    $citovane = ($argumenty | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $p = Start-Process -FilePath $exe -ArgumentList $citovane -NoNewWindow -PassThru `
        -RedirectStandardOutput $out -RedirectStandardError $err
    $null = $p.Handle   # aby šel později přečíst ExitCode
    return $p
}

function Precti($cesta) {
    if (-not (Test-Path -LiteralPath $cesta)) { return '' }
    try {
        $fs = [System.IO.File]::Open($cesta, 'Open', 'Read', 'ReadWrite')
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        $t = $sr.ReadToEnd(); $sr.Close(); return $t
    } catch { return '' }
}

function Aplikuj-Opravy($text) {
    if (-not (Test-Path -LiteralPath $opravyCesta)) { return $text }
    foreach ($r in [System.IO.File]::ReadAllLines($opravyCesta, [System.Text.Encoding]::UTF8)) {
        $r = $r.Trim()
        if (-not $r -or $r.StartsWith('#') -or -not $r.Contains('=>')) { continue }
        $co, $cim = $r -split '=>', 2
        $co = $co.Trim(); $cim = $cim.Trim()
        if ($co) { $text = $text.Replace($co, $cim) }
    }
    return $text
}

function Spust-Whisper($p) {
    $exe = $cliCpu
    if ($p.Gpu) { $exe = Join-Path $gpuDir 'whisper-cli.exe' }
    Remove-Item -Force -ErrorAction SilentlyContinue "$($p.Zaklad).json"
    $argumenty = @('-m', (Cesta-Modelu $p.Model), '-l', 'cs', '-t', "$vlakna", '-oj', '-of', $p.Zaklad, '-np', '-pp', '-f', $p.Wav)
    # Rozpoznání řeči (VAD): pokud je ve složce Modely malý model Silero, přepíše se jen to, kde někdo mluví.
    # Ticho, potlesk a šum se přeskočí, takže se v nich přepis nezacyklí.
    if (Test-Path -LiteralPath $vadModel) { $argumenty += @('--vad', '-vm', (Kratka-Cesta $vadModel)) }
    $p.Proc = Spust $exe $argumenty $p.Out $p.Err
    $p.Stav = 'prepis'
}

function Dokonci-Chybou($p, $zprava) {
    $p.Stav = 'chyba'; $p.Chyba = $zprava; $p.Proc = $null
    Log "Chyba u $($p.Nazev): $zprava"
    Remove-Item -Force -ErrorAction SilentlyContinue $p.Vstup, $p.Wav, "$($p.Zaklad).json"
}

function Cas-Text($ms) {
    $ts = [TimeSpan]::FromMilliseconds($ms)
    '{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds
}

# Přepis s časy: řádky „[hh:mm:ss] text“ -> pole { s = sekundy; t = text }
function Nacti-Casy($cesta) {
    if (-not $cesta -or -not (Test-Path -LiteralPath $cesta)) { return $null }
    @(foreach ($r in [System.IO.File]::ReadAllLines($cesta, [System.Text.Encoding]::UTF8)) {
        if ($r -match '^\[(\d+):(\d\d):(\d\d)\]\s?(.*)$') {
            [pscustomobject]@{ s = [int]$matches[1] * 3600 + [int]$matches[2] * 60 + [int]$matches[3]; t = $matches[4] }
        }
    })
}

function Bez-Diakritiky($text) {
    $d = $text.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $d.ToCharArray()) {
        if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne 'NonSpacingMark') { [void]$sb.Append($ch) }
    }
    $sb.ToString().ToLowerInvariant()
}

function Zastav($p) {
    if ($p.Stav -notin @('ceka', 'priprava', 'prepis')) { return }
    if ($p.Proc -and -not $p.Proc.HasExited) {
        try { $p.Proc.Kill(); [void]$p.Proc.WaitForExit(3000) } catch { }
    }
    $p.Stav = 'zastaveno'; $p.Proc = $null
    Log "Zastaveno: $($p.Nazev)"
    if ($p.Zaklad) {
        Remove-Item -Force -ErrorAction SilentlyContinue $p.Vstup, $p.Wav, "$($p.Zaklad).json", $p.Out, $p.Err
    }
}

# Posune práci o krok dál (volá se neustále v hlavní smyčce)
function Krok {
    if ($script:gpuJob -and $script:gpuJob.State -ne 'Running') {
        if ($script:gpuJob.State -eq 'Completed' -and (Test-Path (Join-Path $gpuDir 'whisper-cli.exe'))) {
            $script:gpuStav = 'pripravena'
        } else {
            $script:gpuStav = 'selhala'
            Log "Stažení verze pro grafiku selhalo: $(($script:gpuJob | Receive-Job -ErrorAction SilentlyContinue 2>&1) -join ' ')"
        }
        Remove-Job $script:gpuJob -Force; $script:gpuJob = $null
    }

    $p = $polozky | Where-Object { $_.Stav -in @('priprava', 'prepis') } | Select-Object -First 1
    if (-not $p) {
        if ($script:gpuStav -eq 'stahuji') { return }
        $p = $polozky | Where-Object { $_.Stav -eq 'ceka' } | Select-Object -First 1
        if (-not $p) { return }
        # Začít: převod na 16 kHz WAV
        $script:cisloUlohy++
        $n = $script:cisloUlohy
        $p.Vstup = Join-Path $tmp ("vstup$n" + [System.IO.Path]::GetExtension($p.Cesta).ToLower())
        $p.Wav = Join-Path $tmp "vstup$n.wav"
        $p.Zaklad = Join-Path $tmp "vystup$n"
        $p.Out = Join-Path $tmp "whisper$n.out.txt"
        $p.Err = Join-Path $tmp "whisper$n.err.txt"
        $p.Start = Get-Date
        $p.Gpu = ($script:gpuStav -eq 'pripravena')
        $p.Model = $script:zvolenyModel
        try {
            Copy-Item -LiteralPath $p.Cesta -Destination $p.Vstup -Force
            $p.Proc = Spust $towav @($p.Vstup, $p.Wav) (Join-Path $tmp "towav$n.out.txt") (Join-Path $tmp "towav$n.err.txt")
            $p.Stav = 'priprava'
        } catch { Dokonci-Chybou $p "Soubor se nepodařilo načíst: $($_.Exception.Message)" }
        return
    }

    $p.Sekundy = [int]((Get-Date) - $p.Start).TotalSeconds
    if ($p.Stav -eq 'priprava') {
        if (-not $p.Proc.HasExited) { return }
        Remove-Item -Force -ErrorAction SilentlyContinue $p.Vstup
        if ($p.Proc.ExitCode -ne 0 -or -not (Test-Path $p.Wav)) {
            Dokonci-Chybou $p 'Soubor se nepodařilo načíst. Podporované formáty jsou mp3, wav a flac.'
            return
        }
        Spust-Whisper $p
        return
    }

    # Stav 'prepis': průběh a náhled textu
    $err = Precti $p.Err
    $m = [regex]::Matches($err, 'progress =\s*(\d+)%')
    if ($m.Count -gt 0) { $p.Procenta = [int]$m[$m.Count - 1].Groups[1].Value }
    $radky = (Precti $p.Out) -split "`r?`n" | Where-Object { $_ -match '^\[' } | ForEach-Object { ($_ -replace '^\[[^\]]*\]\s*', '').Trim() }
    $p.Nahled = @($radky | Select-Object -Last 4)
    if (-not $p.Proc.HasExited) { return }

    $ok = $p.Proc.ExitCode -eq 0 -and (Test-Path "$($p.Zaklad).json")
    if (-not $ok -and $p.Gpu) {
        Log "Grafika selhala u $($p.Nazev), zkouším procesor. $err"
        $p.Gpu = $false; $p.Procenta = 0; $p.Nahled = @()
        Spust-Whisper $p
        return
    }
    if (-not $ok) { Dokonci-Chybou $p "Přepis se nepodařil (kód $($p.Proc.ExitCode))."; return }

    try {
        $segmenty = (Get-Content -LiteralPath "$($p.Zaklad).json" -Raw -Encoding UTF8 | ConvertFrom-Json).transcription
        $radky = @($segmenty | ForEach-Object {
            $t = $_.text.Trim()
            if ($t) { [pscustomobject]@{ ms = [long]$_.offsets.from; t = $t } }
        })
        # Pojistka proti zacyklení: stejná věta víc než 2× za sebou se dál nevypisuje.
        $opakovani = 0; $predchozi = $null
        $radky = @(foreach ($r in $radky) {
            if ($r.t -eq $predchozi) { $opakovani++ } else { $opakovani = 0; $predchozi = $r.t }
            if ($opakovani -lt 2) { $r }
        })
        $text = Aplikuj-Opravy ((($radky | ForEach-Object { $_.t }) -join "`r`n") + "`r`n")
        $textCasy = Aplikuj-Opravy ((($radky | ForEach-Object { "[$(Cas-Text $_.ms)] $($_.t)" }) -join "`r`n") + "`r`n")
        $info = Get-Item -LiteralPath $p.Cesta
        $cil = Join-Path $info.DirectoryName ($info.BaseName + '.txt')
        $i = 2
        while (Test-Path -LiteralPath $cil) { $cil = Join-Path $info.DirectoryName ("$($info.BaseName) ($i).txt"); $i++ }
        $cilCasy = Join-Path $info.DirectoryName ([System.IO.Path]::GetFileNameWithoutExtension($cil) + ' - časy.txt')
        $bom = New-Object System.Text.UTF8Encoding $true
        [System.IO.File]::WriteAllText($cil, $text, $bom)
        [System.IO.File]::WriteAllText($cilCasy, $textCasy, $bom)
        # Délka nahrávky z převedeného WAV (16 kHz, mono, 16 bit = 32000 bajtů za sekundu)
        try { $p.Delka = [int](((Get-Item -LiteralPath $p.Wav).Length - 44) / 32000) } catch { }
        $p.Cil = $cil; $p.CilCasy = $cilCasy; $p.Procenta = 100; $p.Stav = 'hotovo'; $p.Proc = $null
        Zapis-Historii $p
        Remove-Item -Force -ErrorAction SilentlyContinue $p.Wav, "$($p.Zaklad).json", $p.Out, $p.Err
        Log "Hotovo: $cil za $($p.Sekundy) s"
    } catch { Dokonci-Chybou $p "Přepis se nepodařilo uložit: $($_.Exception.Message)" }
}

# Historie přepisů: historie.txt, jeden řádek =
# datum<TAB>nahrávka<TAB>přepis<TAB>doba přepisu (s)<TAB>model<TAB>přepis s časy<TAB>délka nahrávky (s)
function Zapis-Historii($p) {
    try {
        $radek = (@((Get-Date -Format 'yyyy-MM-dd HH:mm'), $p.Cesta, $p.Cil, $p.Sekundy, $p.Model, $p.CilCasy, $p.Delka) -join "`t") + "`r`n"
        if (-not (Test-Path -LiteralPath $historieCesta)) {
            [System.IO.File]::WriteAllText($historieCesta, "# Historie přepisů (datum, nahrávka, přepis, doba přepisu, model, přepis s časy, délka nahrávky)`r`n", (New-Object System.Text.UTF8Encoding $true))
        }
        [System.IO.File]::AppendAllText($historieCesta, $radek, (New-Object System.Text.UTF8Encoding $false))
    } catch { Log "Historii se nepodařilo zapsat: $($_.Exception.Message)" }
}

# Délka zvukového souboru podle Windows (sloupec „Délka“ v Průzkumníku), v sekundách
function Delka-Nahravky($cesta) {
    if (-not $naWindows) { return 0 }
    try {
        $slozka = (New-Object -ComObject Shell.Application).Namespace((Split-Path $cesta -Parent))
        $t = $slozka.GetDetailsOf($slozka.ParseName((Split-Path $cesta -Leaf)), 27)
        if ($t -match '(\d+):(\d\d):(\d\d)') { return [int]$matches[1] * 3600 + [int]$matches[2] * 60 + [int]$matches[3] }
    } catch { }
    return 0
}

# Při spuštění:
# - smazat z historie záznamy, jejichž přepis už ve své složce není
#   (když je nedostupný celý disk, např. odpojený síťový disk X:, záznam zůstane),
# - u starších záznamů doplnit délku nahrávky.
function Procisti-Historii {
    if (-not (Test-Path -LiteralPath $historieCesta)) { return }
    try {
        $radky = [System.IO.File]::ReadAllLines($historieCesta, [System.Text.Encoding]::UTF8)
        $zmena = $false
        $nech = @(foreach ($r in $radky) {
            $c = @($r -split "`t")
            if ($r.StartsWith('#') -or $c.Count -lt 3) { $r; continue }
            $disk = [System.IO.Path]::GetPathRoot($c[2])
            if (-not (Test-Path -LiteralPath $c[2]) -and $disk -and (Test-Path -LiteralPath $disk)) { $zmena = $true; continue }
            if ($c.Count -lt 7 -or -not ($c[6] -as [int])) {
                $d = 0
                if (Test-Path -LiteralPath $c[1]) { $d = Delka-Nahravky $c[1] }
                if ($d -gt 0) {
                    while ($c.Count -lt 7) { $c += '' }
                    $c[6] = "$d"; $r = $c -join "`t"; $zmena = $true
                }
            }
            $r
        })
        if ($zmena) {
            [System.IO.File]::WriteAllText($historieCesta, (($nech -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding $true))
            Log "Historie upravena (záznamů: $($radky.Count) -> $($nech.Count))"
        }
    } catch { Log "Historii se nepodařilo pročistit: $($_.Exception.Message)" }
}

function Nacti-Historii {
    if (-not (Test-Path -LiteralPath $historieCesta)) { return @() }
    $i = 0
    @(foreach ($r in [System.IO.File]::ReadAllLines($historieCesta, [System.Text.Encoding]::UTF8)) {
        $c = $r -split "`t"
        if ($r.StartsWith('#') -or $c.Count -lt 3) { continue }
        [pscustomobject]@{ h = $i; datum = $c[0]; nazev = [System.IO.Path]::GetFileName($c[1]); cil = $c[2]
            sekundy = [int]($c[3] -as [int]); model = $(if ($c.Count -gt 4) { $c[4] } else { '' })
            nahravka = $c[1]; casy = $(if ($c.Count -gt 5) { $c[5] } else { '' })
            delka = $(if ($c.Count -gt 6) { [int]($c[6] -as [int]) } else { 0 })
            existuje = (Test-Path -LiteralPath $c[2]) }
        $i++
    })
}

# Hledání slova ve všech přepisech z historie (bez ohledu na velikost písmen a diakritiku)
function Hledej($dotaz) {
    $hledane = Bez-Diakritiky $dotaz.Trim()
    if ($hledane.Length -lt 2) { return @() }
    $vysledky = New-Object System.Collections.ArrayList
    $videne = @{}
    $hist = @(Nacti-Historii); [array]::Reverse($hist)
    foreach ($z in $hist) {
        if ($videne.ContainsKey($z.cil) -or -not $z.existuje) { continue }
        $videne[$z.cil] = $true
        $radky = Nacti-Casy $z.casy
        if ($null -eq $radky) {
            $radky = @([System.IO.File]::ReadAllLines($z.cil, [System.Text.Encoding]::UTF8) | ForEach-Object { [pscustomobject]@{ s = -1; t = $_ } })
        }
        foreach ($r in $radky) {
            if ((Bez-Diakritiky $r.t).Contains($hledane)) {
                [void]$vysledky.Add([pscustomobject]@{ h = $z.h; nazev = $z.nazev; datum = $z.datum; s = $r.s; t = $r.t })
                if ($vysledky.Count -ge 200) { return $vysledky.ToArray() }
            }
        }
    }
    return $vysledky.ToArray()
}

function Pracuje { [bool]($polozky | Where-Object { $_.Stav -in @('ceka', 'priprava', 'prepis') }) }

# ---------- Webový server ----------
function Odpoved($ctx, $telo, $typ = 'application/json; charset=utf-8', $kod = 200) {
    $bajty = [System.Text.Encoding]::UTF8.GetBytes($telo)
    $ctx.Response.StatusCode = $kod
    $ctx.Response.ContentType = $typ
    $ctx.Response.Headers['Cache-Control'] = 'no-store'
    $ctx.Response.ContentLength64 = $bajty.Length
    $ctx.Response.OutputStream.Write($bajty, 0, $bajty.Length)
    $ctx.Response.OutputStream.Close()
}

# Zvuk pro přehrávač: po kouscích (max 2 MB) s podporou přetáčení
function Odpoved-Zvuk($ctx, $cesta) {
    $typ = switch ([System.IO.Path]::GetExtension($cesta).ToLower()) { '.wav' { 'audio/wav' } '.flac' { 'audio/flac' } default { 'audio/mpeg' } }
    $fs = [System.IO.File]::Open($cesta, 'Open', 'Read', 'ReadWrite')
    try {
        $delka = $fs.Length; $od = [long]0; $do = $delka - 1
        $rozsah = $ctx.Request.Headers['Range']
        if ($rozsah -match 'bytes=(\d+)-(\d*)') {
            $od = [long]$matches[1]
            if ($matches[2]) { $do = [Math]::Min($do, [long]$matches[2]) }
        }
        $res = $ctx.Response
        $res.Headers['Accept-Ranges'] = 'bytes'
        if ($od -ge $delka) {
            $res.StatusCode = 416; $res.Headers['Content-Range'] = "bytes */$delka"; $res.ContentLength64 = 0
            $res.OutputStream.Close(); return
        }
        $do = [Math]::Min($do, $od + 2MB - 1)
        $kus = $do - $od + 1
        $res.StatusCode = 206
        $res.ContentType = $typ
        $res.Headers['Content-Range'] = "bytes $od-$do/$delka"
        $res.ContentLength64 = $kus
        [void]$fs.Seek($od, 'Begin')
        $buf = New-Object byte[] 65536
        while ($kus -gt 0) {
            $n = $fs.Read($buf, 0, [int][Math]::Min($buf.Length, $kus))
            if ($n -le 0) { break }
            $res.OutputStream.Write($buf, 0, $n); $kus -= $n
        }
        $res.OutputStream.Close()
    } finally { $fs.Close() }
}

function Json($obj) { ConvertTo-Json -InputObject $obj -Depth 5 -Compress }

function Stav-Json {
    $seznam = @($polozky | ForEach-Object {
        [pscustomobject]@{ id = $_.Id; nazev = $_.Nazev; stav = $_.Stav; procenta = $_.Procenta
            nahled = @($_.Nahled); cil = $_.Cil; chyba = $_.Chyba; sekundy = $_.Sekundy; gpu = $_.Gpu; model = $_.Model }
    })
    $nabidka = @($modely | ForEach-Object { [pscustomobject]@{ klic = $_.klic; nazev = $_.nazev } })
    Json ([pscustomobject]@{ polozky = $seznam; modely = $nabidka; zvolenyModel = $script:zvolenyModel; gpuStav = $gpuStav; gpuNazev = $gpuNazev; autoVyber = $script:autoVyber; pracuje = (Pracuje) })
}

function Obsluz($ctx) {
    $cesta = $ctx.Request.Url.AbsolutePath
    $id = -1
    if ($ctx.Request.QueryString['id']) { $id = [int]$ctx.Request.QueryString['id'] }
    $cilSoubor = $null; $casySoubor = $null; $zvukSoubor = $null
    if ($id -ge 0 -and $id -lt $polozky.Count) {
        $cilSoubor = $polozky[$id].Cil; $casySoubor = $polozky[$id].CilCasy; $zvukSoubor = $polozky[$id].Cesta
    }
    if ($ctx.Request.QueryString['h']) {
        $h = [int]$ctx.Request.QueryString['h']
        $zaznam = Nacti-Historii | Where-Object { $_.h -eq $h } | Select-Object -First 1
        if ($zaznam) { $cilSoubor = $zaznam.cil; $casySoubor = $zaznam.casy; $zvukSoubor = $zaznam.nahravka }
    }
    $maCil = $cilSoubor -and (Test-Path -LiteralPath $cilSoubor)

    switch ($cesta) {
        '/' { Odpoved $ctx ([System.IO.File]::ReadAllText($stranka, [System.Text.Encoding]::UTF8)) 'text/html; charset=utf-8' }
        '/stav' { Odpoved $ctx (Stav-Json) }
        '/historie' {
            $hist = @(Nacti-Historii)
            [array]::Reverse($hist)
            Odpoved $ctx (Json $hist)
        }
        '/vybrat' {
            $script:autoVyber = $false
            $vybrane = @(Vyber-Soubory)
            Pridej-Soubory $vybrane
            Odpoved $ctx (Json ([pscustomobject]@{ pocet = $vybrane.Count }))
        }
        '/text' {
            if ($maCil) {
                Odpoved $ctx ([System.IO.File]::ReadAllText($cilSoubor, [System.Text.Encoding]::UTF8)) 'text/plain; charset=utf-8'
            } else { Odpoved $ctx '' 'text/plain; charset=utf-8' 404 }
        }
        '/casy' {
            $radky = Nacti-Casy $casySoubor
            if ($null -ne $radky) { Odpoved $ctx (Json @($radky)) } else { Odpoved $ctx '[]' 'application/json; charset=utf-8' 404 }
        }
        '/zvuk' {
            if ($zvukSoubor -and (Test-Path -LiteralPath $zvukSoubor)) { Odpoved-Zvuk $ctx $zvukSoubor }
            else { Odpoved $ctx '' 'text/plain; charset=utf-8' 404 }
        }
        '/hledat' {
            # Dotaz dekódovat jako UTF-8 (QueryString by použil kódování systému)
            $dotaz = ''
            foreach ($cast in $ctx.Request.Url.Query.TrimStart('?').Split('&')) {
                if ($cast.StartsWith('q=')) { $dotaz = [Uri]::UnescapeDataString($cast.Substring(2).Replace('+', ' ')) }
            }
            Odpoved $ctx (Json @(Hledej $dotaz))
        }
        '/otevrit' {
            if ($maCil -and $naWindows) { Start-Process -FilePath $cilSoubor }
            Odpoved $ctx '{}'
        }
        '/slozka' {
            if ($maCil -and $naWindows) { Start-Process explorer.exe -ArgumentList "/select,`"$cilSoubor`"" }
            Odpoved $ctx '{}'
        }
        '/opravy' {
            if ($naWindows) {
                if (-not (Test-Path -LiteralPath $opravyCesta)) { [System.IO.File]::WriteAllText($opravyCesta, "# špatně => správně`r`n", (New-Object System.Text.UTF8Encoding $true)) }
                Start-Process notepad.exe -ArgumentList "`"$opravyCesta`""
            }
            Odpoved $ctx '{}'
        }
        '/zastavit' {
            if ($id -ge 0 -and $id -lt $polozky.Count) { Zastav $polozky[$id] }
            Odpoved $ctx '{}'
        }
        '/model' {
            $k = $ctx.Request.QueryString['k']
            if (Model-Info $k) {
                $script:zvolenyModel = $k
                # Platí i pro nahrávky, které ještě nezačaly
                $polozky | Where-Object { $_.Stav -eq 'ceka' } | ForEach-Object { $_.Model = $k }
                try { [System.IO.File]::WriteAllText($volbaCesta, $k) } catch { }
            }
            Odpoved $ctx '{}'
        }
        '/konec' { $script:zavreno = Get-Date; Odpoved $ctx '{}' }
        default { Odpoved $ctx 'Nenalezeno' 'text/plain; charset=utf-8' 404 }
    }
}

Procisti-Historii
Pridej-Soubory $Soubory

$listener = $null
$port = 0
foreach ($zkus in 47801..47830) {
    $l = New-Object System.Net.HttpListener
    $l.Prefixes.Add("http://localhost:$zkus/")
    try { $l.Start(); $listener = $l; $port = $zkus; break } catch { $l.Close() }
}
if (-not $listener) { Hlaska 'Nepodařilo se spustit stránku (žádný volný port).'; exit }
$adresa = "http://localhost:$port/"
Log "Server běží na $adresa"
if ($naWindows) { Start-Process $adresa } else { Write-Host $adresa }

$posledniDotaz = Get-Date
$zavreno = $null
$ctxTask = $listener.GetContextAsync()
while (-not $konec) {
    if ($ctxTask.Wait(250)) {
        $ctx = $ctxTask.Result
        $ctxTask = $listener.GetContextAsync()
        try { Obsluz $ctx } catch {
            Log "Chyba při obsluze $($ctx.Request.Url): $($_.Exception.Message)"
            try { Odpoved $ctx (Json ([pscustomobject]@{ chyba = $_.Exception.Message })) 'application/json; charset=utf-8' 500 } catch { }
        }
        $posledniDotaz = Get-Date
        if ($ctx.Request.Url.AbsolutePath -ne '/konec') { $zavreno = $null }
    }
    try { Krok } catch { Log "Chyba: $($_.Exception.Message)" }
    # Stránka zavřená a nic se nepřepisuje: ukončit
    # (po zavření stránky za 5 s, jinak po 30 s bez dotazu)
    if (-not (Pracuje)) {
        if ($zavreno -and ((Get-Date) - $zavreno).TotalSeconds -gt 5) { break }
        if (((Get-Date) - $posledniDotaz).TotalSeconds -gt 30) { break }
    }
}
Start-Sleep -Milliseconds 300
$listener.Stop()
Log 'Server ukončen'
