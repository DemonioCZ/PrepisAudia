#!/usr/bin/env python3
"""Převod doladěného Whisper modelu z Hugging Face (.safetensors) do formátu ggml pro whisper.cpp.

Hlavička (nastavení, mel filtry, slovník) se převezme z původního ggml modelu stejné velikosti
(např. ggml-large-v3.bin), vymění se jen váhy. Potřebuje jen Python 3 a numpy.

Použití:
  python3 prevod-modelu.py ggml-large-v3.bin vystup.bin model.safetensors [další .safetensors ...]
"""
import json, struct, sys
import numpy as np

DT = {'F16': np.float16, 'F32': np.float32, 'BF16': None}


def nacti_safetensors(cesty):
    tenzory = {}
    for cesta in cesty:
        f = open(cesta, 'rb')
        n = struct.unpack('<Q', f.read(8))[0]
        hlav = json.loads(f.read(n))
        mm = f
        zacatek = 8 + n
        for jmeno, info in hlav.items():
            if jmeno == '__metadata__':
                continue
            tenzory[jmeno] = (mm, zacatek, info)
    return tenzory


def hf_pole(t):
    f, zacatek, info = t
    b, e = info['data_offsets']
    f.seek(zacatek + b)
    raw = np.frombuffer(f.read(e - b), dtype=np.uint8)
    if info['dtype'] == 'BF16':
        u = raw.view(np.uint16).astype(np.uint32) << 16
        return u.view(np.float32)
    return raw.view(DT[info['dtype']])


def hf_jmeno(g):
    """Jméno tenzoru v ggml (styl OpenAI) -> jméno v Hugging Face."""
    s = g
    s = s.replace('encoder.positional_embedding', 'encoder.embed_positions.weight')
    s = s.replace('decoder.positional_embedding', 'decoder.embed_positions.weight')
    s = s.replace('decoder.token_embedding', 'decoder.embed_tokens')
    s = s.replace('encoder.ln_post', 'encoder.layer_norm')
    if s.startswith('decoder.ln.'):
        s = s.replace('decoder.ln.', 'decoder.layer_norm.')
    s = s.replace('.blocks.', '.layers.')
    s = s.replace('.cross_attn_ln.', '.encoder_attn_layer_norm.')
    s = s.replace('.attn_ln.', '.self_attn_layer_norm.')
    s = s.replace('.mlp_ln.', '.final_layer_norm.')
    s = s.replace('.mlp.0.', '.fc1.').replace('.mlp.2.', '.fc2.')
    for a, b in (('query', 'q_proj'), ('key', 'k_proj'), ('value', 'v_proj'), ('out', 'out_proj')):
        s = s.replace(f'.cross_attn.{a}.', f'.encoder_attn.{b}.')
        s = s.replace(f'.attn.{a}.', f'.self_attn.{b}.')
    return 'model.' + s


def main():
    """Lze spouštět opakovaně: každé spuštění pracuje nejvýš LIMIT sekund a pokračuje, kde minule skončilo."""
    import os, time
    LIMIT = float(os.environ.get('LIMIT', '1e9'))
    vzor, vystup, *st = sys.argv[1:]
    stav_cesta = os.environ.get('STAV', vystup + '.stav')
    tenzory = nacti_safetensors(st)
    fi = open(vzor, 'rb')
    if os.path.exists(stav_cesta):
        stav = json.load(open(stav_cesta))
        fi.seek(stav['vstup'])
        fo = open(vystup, 'r+b'); fo.truncate(stav['vystup']); fo.seek(stav['vystup'])
    else:
        fo = open(vystup, 'wb')

        def kopiruj(n):
            b = fi.read(n); fo.write(b); return b

        assert struct.unpack('<i', kopiruj(4))[0] == 0x67676d6c, 'vzor není ggml model'
        hp = struct.unpack('<11i', kopiruj(44))
        n_mel, n_fft = struct.unpack('<2i', kopiruj(8))
        kopiruj(4 * n_mel * n_fft)
        n_tok = struct.unpack('<i', kopiruj(4))[0]
        for _ in range(n_tok):
            kopiruj(struct.unpack('<i', kopiruj(4))[0])
        print('hparams', hp, 'tokeny', n_tok, flush=True)
        stav = {'pocet': 0}

    start = time.time()
    hotovo = False
    while True:
        h = fi.read(12)
        if len(h) < 12:
            hotovo = True
            break
        n_dims, n_name, ftype = struct.unpack('<3i', h)
        dims = struct.unpack(f'<{n_dims}i', fi.read(4 * n_dims))
        jmeno = fi.read(n_name).decode()
        prvku = int(np.prod(dims))
        fi.seek(prvku * (2 if ftype == 1 else 4), 1)
        hj = hf_jmeno(jmeno)
        if hj not in tenzory:
            sys.exit(f'CHYBA: v doladěném modelu chybí {hj} (pro {jmeno})')
        a = hf_pole(tenzory[hj]).reshape(-1)
        if a.size != prvku:
            sys.exit(f'CHYBA: nesedí velikost {jmeno}: {a.size} vs {prvku}')
        a = a.astype(np.float16 if ftype == 1 else np.float32)
        fo.write(h); fo.write(struct.pack(f'<{n_dims}i', *dims)); fo.write(jmeno.encode())
        fo.write(a.tobytes())
        stav['pocet'] += 1
        if time.time() - start > LIMIT:
            break
    fo.flush()
    stav['vstup'] = fi.tell(); stav['vystup'] = fo.tell()
    fo.close()
    if hotovo:
        if os.path.exists(stav_cesta):
            os.remove(stav_cesta)
        print('HOTOVO, tenzorů:', stav['pocet'], flush=True)
    else:
        json.dump(stav, open(stav_cesta, 'w'))
        print('POKRAČOVAT, zatím tenzorů:', stav['pocet'], 'zapsáno MB:', stav['vystup'] // 2**20, flush=True)


if __name__ == '__main__':
    main()
