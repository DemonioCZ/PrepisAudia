# Přepis audia

Jednoduchý nástroj pro přepis nahrávek (mp3, wav…) na text v češtině pomocí [whisper.cpp](https://github.com/ggml-org/whisper.cpp). Běží na Windows bez instalace.

## Co je v repozitáři

| Soubor / složka | K čemu slouží |
|---|---|
| `Prepis.bat` | Spuštění dvojklikem (nebo na něj přetáhněte nahrávky). Otevře stránku v prohlížeči. |
| `Aktualizovat.bat` | Stáhne z GitHubu novější verzi programu (viz níže). |
| `NAVOD - prepis nahravky.pdf` | Návod k použití. |
| `nastroj/` | Program whisper.cpp, převod zvuku a ovládací stránka. |
| `data/opravy.txt` | Seznam oprav slov, která přepis komolí (`špatně => správně`). |
| `data/model.txt` | Naposledy zvolený model (`turbo` nebo `large`). |
| `Modely/` | Sem patří stažené modely. V repozitáři je prázdná, protože modely mají 1,5–3 GB. |

## Stažení modelů

Modely stáhněte z Hugging Face ([ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp/tree/main)) a **uložte do složky `Modely`** vedle `Prepis.bat`. Názvy souborů neměňte.

| Model | Soubor | Velikost | Odkaz ke stažení |
|---|---|---|---|
| Rychlý (turbo) | `ggml-large-v3-turbo.bin` | asi 1,6 GB | https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin |
| Přesnější (large, asi 2× pomalejší) | `ggml-large-v3.bin` | asi 3,1 GB | https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin |

Stačí jeden z nich; na stránce se nabídnou jen modely, které ve složce `Modely` opravdu jsou.

**Nepovinné:** malý model `ggml-silero-v5.1.2.bin` (asi 0,9 MB) rozpozná, kde někdo mluví, a ticho se pak nepřepisuje (méně nesmyslů v tichých místech). Stáhněte ho z https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin a uložte také do `Modely`.

Výsledná struktura:

```
PrepisAudia/
├─ Prepis.bat
├─ Modely/
│  ├─ ggml-large-v3-turbo.bin
│  ├─ ggml-large-v3.bin
│  └─ ggml-silero-v5.1.2.bin   (nepovinné)
├─ nastroj/
└─ data/
```

## Použití

1. Spusťte `Prepis.bat` (nebo na něj přetáhněte nahrávky).
2. V prohlížeči se otevře stránka, kde vyberete model a soubory.
3. Přepis (`.txt`) se uloží vedle nahrávky, verze s časy jako `… - časy.txt`.

Pokud má počítač grafickou kartu NVIDIA, při prvním spuštění se automaticky stáhne rychlejší GPU verze do `nastroj/gpu` (do repozitáře se neukládá).

## Aktualizace

Spusťte `Aktualizovat.bat`. Skript se podívá na GitHub, a pokud je tam novější verze, stáhne ji a aktualizuje **jen**:

- složku `nastroj` (kromě `nastroj/gpu`),
- `NAVOD - prepis nahravky.pdf`,
- `Prepis.bat`,
- `data/opravy.txt` (předchozí verze se uloží vedle jako `data/opravy - záloha.txt`, takže o vlastní úpravy nepřijdete).

Ničeho jiného se nedotkne: složka `Modely`, zbytek `data` (volba modelu, historie) ani nahrávky a přepisy se nemění. Před aktualizací zavřete stránku Přepisu, nebo počkejte, až doběhne rozpracovaný přepis.

### Přístup k soukromému repozitáři

Repozitář je soukromý, proto skript potřebuje přístupový token (jen pro čtení):

1. Na GitHubu otevřete **Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**.
2. U **Repository access** zvolte *Only select repositories* a vyberte `PrepisAudia`.
3. U **Permissions → Repository permissions** nastavte **Contents: Read-only**. Nic dalšího není potřeba.
4. Vytvořený token zkopírujte do souboru `nastroj/github-token.txt` (jen samotný token, jeden řádek).

Soubor s tokenem se do repozitáře nikdy nenahraje. Pokud by byl repozitář veřejný, token není potřeba.
