# Aktualizace nástroje z GitHubu (repozitář DemonioCZ/prepisaudia).
# Spouští se přes Aktualizovat.bat. Aktualizuje jen složku nastroj, NAVOD a Prepis.bat.
# Ostatního (Modely, data, nastroj\gpu, přepisy) se nedotkne.
# Soukromý repozitář: do souboru nastroj\github-token.txt vložte přístupový token (viz README).

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repo    = 'DemonioCZ/prepisaudia'
$vetev   = 'main'
$nastroj = $PSScriptRoot
$koren   = Split-Path $nastroj -Parent
$stavCesta  = Join-Path $nastroj 'aktualizace-stav.txt'
$tokenCesta = Join-Path $nastroj 'github-token.txt'

# Které soubory se aktualizují (cesty relativně ke kořeni, s lomítkem /)
function Aktualizovat($rel) {
    if ($rel -eq 'Prepis.bat' -or $rel -eq 'NAVOD - prepis nahravky.pdf') { return $true }
    if ($rel -like 'nastroj/gpu/*') { return $false }
    if ($rel -eq 'nastroj/github-token.txt' -or $rel -eq 'nastroj/aktualizace-stav.txt') { return $false }
    return ($rel -like 'nastroj/*')
}

function Hash($cesta) {
    if (-not (Test-Path -LiteralPath $cesta)) { return '' }
    (Get-FileHash -LiteralPath $cesta -Algorithm SHA256).Hash
}

function Konec($zprava) { Write-Host ''; Write-Host $zprava; exit }

# Uložená verze z minulé aktualizace
$stav = @{}
if (Test-Path -LiteralPath $stavCesta) {
    Get-Content -LiteralPath $stavCesta | ForEach-Object {
        $i = $_.IndexOf('=')
        if ($i -gt 0) { $stav[$_.Substring(0, $i)] = $_.Substring($i + 1) }
    }
}

$hlavicky = @{ 'User-Agent' = 'PrepisAudia-aktualizace'; 'Accept' = 'application/vnd.github+json' }
if (Test-Path -LiteralPath $tokenCesta) {
    $token = (Get-Content -LiteralPath $tokenCesta -Raw).Trim()
    if ($token) { $hlavicky['Authorization'] = "Bearer $token" }
}

Write-Host 'Zjišťuji, jestli je na GitHubu novější verze…'
try {
    $commit = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/commits/$vetev" -Headers $hlavicky
} catch {
    $kod = 0
    if ($_.Exception.Response) { $kod = [int]$_.Exception.Response.StatusCode }
    if ($kod -eq 404 -or $kod -eq 401) {
        Konec "Repozitář se nepodařilo otevřít (chyba $kod).`nPokud je soukromý, vložte platný token do souboru:`n  $tokenCesta`n(postup je v README.md)."
    }
    Konec "Nepodařilo se spojit s GitHubem: $($_.Exception.Message)"
}

$novaVerze = $commit.sha
$popis = ($commit.commit.message -split "`n")[0]
$datum = $commit.commit.committer.date
if ($stav['verze'] -eq $novaVerze) {
    Konec "Máte nejnovější verzi ($($novaVerze.Substring(0,7)), $datum).`nNení co aktualizovat."
}

Write-Host "Nalezena nová verze $($novaVerze.Substring(0,7)) ze dne $datum"
Write-Host "  $popis"
Write-Host ''

if (Get-Process -Name 'whisper-cli' -ErrorAction SilentlyContinue) {
    Konec 'Právě běží přepis. Počkejte, až doběhne, zavřete stránku Přepisu a spusťte aktualizaci znovu.'
}

# Stažení a rozbalení do dočasné složky
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('prepisaudia_aktualizace_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    $zip = Join-Path $tmp 'verze.zip'
    Write-Host 'Stahuji…'
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri "https://api.github.com/repos/$repo/zipball/$novaVerze" -Headers $hlavicky -OutFile $zip -UseBasicParsing
    Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $tmp 'x') -Force
    # GitHub zabalí vše do jedné složky s názvem repozitáře a verze
    $zdroj = Get-ChildItem -LiteralPath (Join-Path $tmp 'x') -Directory | Select-Object -First 1
    if (-not $zdroj) { Konec 'Stažený soubor je prázdný, aktualizace se neprovedla.' }
    $zdrojCesta = $zdroj.FullName

    $zmeneno = 0
    foreach ($soubor in (Get-ChildItem -LiteralPath $zdrojCesta -Recurse -File -Force)) {
        $rel = $soubor.FullName.Substring($zdrojCesta.Length + 1).Replace('\', '/')
        if (-not (Aktualizovat $rel)) { continue }
        $cil = Join-Path $koren ($rel.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
        if ((Hash $cil) -eq (Hash $soubor.FullName)) { continue }
        New-Item -ItemType Directory -Force -Path (Split-Path $cil -Parent) | Out-Null
        Copy-Item -LiteralPath $soubor.FullName -Destination $cil -Force
        Write-Host "  aktualizováno: $rel"
        $zmeneno++
    }

    # Uložit stav pro příští aktualizaci
    $obsah = @("verze=$novaVerze")
    [System.IO.File]::WriteAllLines($stavCesta, $obsah)

    Write-Host ''
    Write-Host "Hotovo. Aktualizováno souborů: $zmeneno."
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
