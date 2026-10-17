# Přepis audia

Jednoduchý nástroj pro přepis nahrávek (mp3, wav…) na text v češtině pomocí [whisper.cpp](https://github.com/ggml-org/whisper.cpp). Běží na Windows bez instalace.

## Co je v repozitáři

| Soubor / složka | K čemu slouží |
|---|---|
| `Prepis.bat` | Spuštění dvojklikem (nebo na něj přetáhněte nahrávky). Otevře stránku v prohlížeči. |
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
