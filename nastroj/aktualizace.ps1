# Aktualizace nástroje z GitHubu (repozitář DemonioCZ/prepisaudia).
# Spouští se přes Aktualizovat.bat. Stáhne nejnovější verzi a přepíše jen soubory programu.
# Nikdy nesahá na: složku Modely, nastroj\gpu, nahrávky a přepisy.
# data\model.txt se nepřepisuje, pokud už existuje.
# data\opravy.txt se přepíše jen tehdy, pokud jste ho od minulé aktualizace neměnili;
# jinak zůstane váš a nová verze z GitHubu se uloží vedle jako „opravy (z GitHubu).txt“.
# Soukromý repozitář: do souboru nastroj\github-token.txt vložte přístupový token (viz README).

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repo    = 'DemonioCZ/prepisaudia'
$vetev   = 'main'
$nastroj = $PSScriptRoot
$koren   = Split-Path $nastroj -Parent
$stavCesta  = Join-Path $nastroj 'aktualizace-stav.txt'
$tokenCesta = Join-Path $nastroj 'github-token.txt'

# Co se nikdy nepřepisuje (cesty relativně ke kořeni, s lomítkem /)
function Chraneno($rel) {
    if ($rel -like 'Modely/*') { return $true }
    if ($rel -like 'nastroj/gpu/*') { return $true }
    if ($rel -eq 'nastroj/github-token.txt' -or $rel -eq 'nastroj/aktualizace-stav.txt') { return $true }
    if ($rel -like 'data/*' -and $rel -ne 'data/opravy.txt' -and $rel -ne 'data/model.txt') { return $true }
    return $false
}

function Hash($cesta) {
    if (-not (Test-Path -LiteralPath $cesta)) { return '' }
    (Get-FileHash -LiteralPath $cesta -Algorithm SHA256).Hash
}

function Konec($zprava) { Write-Host ''; Write-Host $zprava; exit }

# Uložený stav z minulé aktualizace (verze a otisk opravy.txt)
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
    $poznamky = @()
    $noveOpravyHash = $stav['opravy']
    foreach ($soubor in (Get-ChildItem -LiteralPath $zdrojCesta -Recurse -File -Force)) {
        $rel = $soubor.FullName.Substring($zdrojCesta.Length + 1).Replace('\', '/')
        if (Chraneno $rel) { continue }
        $cil = Join-Path $koren ($rel.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
        $novyHash = Hash $soubor.FullName
        $staryHash = Hash $cil

        if ($rel -eq 'data/model.txt' -and $staryHash) { continue }   # volba modelu je vaše
        if ($rel -eq 'data/opravy.txt') {
            $noveOpravyHash = $novyHash
            if ($staryHash -and $staryHash -ne $novyHash -and $staryHash -ne $stav['opravy']) {
                # opravy.txt jste upravili: necháme váš a nový uložíme vedle
                $vedle = Join-Path (Join-Path $koren 'data') 'opravy (z GitHubu).txt'
                Copy-Item -LiteralPath $soubor.FullName -Destination $vedle -Force
                $poznamky += "Váš soubor data\opravy.txt jste upravili, proto zůstal beze změny.`n  Nová verze z GitHubu je vedle jako opravy (z GitHubu).txt a můžete si z ní převzít nové řádky."
                continue
            }
        }
        if ($staryHash -eq $novyHash) { continue }
        New-Item -ItemType Directory -Force -Path (Split-Path $cil -Parent) | Out-Null
        Copy-Item -LiteralPath $soubor.FullName -Destination $cil -Force
        Write-Host "  aktualizováno: $rel"
        $zmeneno++
    }

    # Uložit stav pro příští aktualizaci
    $obsah = @("verze=$novaVerze", "opravy=$noveOpravyHash")
    [System.IO.File]::WriteAllLines($stavCesta, $obsah)

    Write-Host ''
    Write-Host "Hotovo. Aktualizováno souborů: $zmeneno."
    $poznamky | ForEach-Object { Write-Host ''; Write-Host $_ }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
