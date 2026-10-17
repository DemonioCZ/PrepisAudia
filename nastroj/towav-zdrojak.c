// Prevede zvukovy soubor (mp3/wav/flac) na 16 kHz mono 16bit WAV.
// Pouziti: towav vstup vystup.wav
#define MA_NO_DEVICE_IO
#define MA_NO_THREADING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#include <stdio.h>

int main(int argc, char** argv) {
    if (argc != 3) { fprintf(stderr, "Pouziti: towav vstup vystup.wav\n"); return 1; }
    ma_decoder_config dc = ma_decoder_config_init(ma_format_s16, 1, 16000);
    ma_decoder dec;
    if (ma_decoder_init_file(argv[1], &dc, &dec) != MA_SUCCESS) { fprintf(stderr, "Nelze otevrit %s\n", argv[1]); return 2; }
    ma_encoder_config ec = ma_encoder_config_init(ma_encoding_format_wav, ma_format_s16, 1, 16000);
    ma_encoder enc;
    if (ma_encoder_init_file(argv[2], &ec, &enc) != MA_SUCCESS) { fprintf(stderr, "Nelze zapsat %s\n", argv[2]); ma_decoder_uninit(&dec); return 3; }
    static ma_int16 buf[16000];
    for (;;) {
        ma_uint64 n = 0;
        ma_result r = ma_decoder_read_pcm_frames(&dec, buf, 16000, &n);
        if (n > 0) ma_encoder_write_pcm_frames(&enc, buf, n, NULL);
        if (r != MA_SUCCESS || n == 0) break;
    }
    ma_encoder_uninit(&enc);
    ma_decoder_uninit(&dec);
    return 0;
}
