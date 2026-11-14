// BC1/BC2/BC3 (DXT1/3/5) block decoders, following the D3D/Metal definitions.
#include "bc_decode.h"

#include <string.h>

static void rgb565(uint16_t c, uint8_t out[4])
{
    int r = (c >> 11) & 31, g = (c >> 5) & 63, b = c & 31;
    out[0] = (uint8_t)((r << 3) | (r >> 2));
    out[1] = (uint8_t)((g << 2) | (g >> 4));
    out[2] = (uint8_t)((b << 3) | (b >> 2));
    out[3] = 255;
}

// colour block (8 bytes) -> 16 RGBA texels; `alpha_mode` = BC1 three-colour + transparent allowed
static void color_block(const uint8_t *b, int bc1, uint8_t px[16][4])
{
    uint16_t c0 = (uint16_t)(b[0] | b[1] << 8), c1 = (uint16_t)(b[2] | b[3] << 8);
    uint8_t pal[4][4];
    rgb565(c0, pal[0]);
    rgb565(c1, pal[1]);
    if (!bc1 || c0 > c1) {
        for (int i = 0; i < 3; i++) {
            pal[2][i] = (uint8_t)((2 * pal[0][i] + pal[1][i] + 1) / 3);
            pal[3][i] = (uint8_t)((pal[0][i] + 2 * pal[1][i] + 1) / 3);
        }
        pal[2][3] = pal[3][3] = 255;
    } else {
        for (int i = 0; i < 3; i++)
            pal[2][i] = (uint8_t)((pal[0][i] + pal[1][i]) / 2);
        pal[2][3] = 255;
        pal[3][0] = pal[3][1] = pal[3][2] = pal[3][3] = 0;
    }
    uint32_t idx = (uint32_t)(b[4] | b[5] << 8 | b[6] << 16 | (uint32_t)b[7] << 24);
    for (int i = 0; i < 16; i++)
        memcpy(px[i], pal[(idx >> (2 * i)) & 3], 4);
}

static void alpha_bc2(const uint8_t *b, uint8_t px[16][4])
{
    for (int i = 0; i < 16; i++) {
        int a = (b[i / 2] >> (4 * (i & 1))) & 15;
        px[i][3] = (uint8_t)(a * 17);
    }
}

static void alpha_bc3(const uint8_t *b, uint8_t px[16][4])
{
    uint8_t a[8];
    a[0] = b[0];
    a[1] = b[1];
    if (a[0] > a[1]) {
        for (int i = 1; i < 7; i++)
            a[i + 1] = (uint8_t)(((7 - i) * a[0] + i * a[1] + 3) / 7);
    } else {
        for (int i = 1; i < 5; i++)
            a[i + 1] = (uint8_t)(((5 - i) * a[0] + i * a[1] + 2) / 5);
        a[6] = 0;
        a[7] = 255;
    }
    uint64_t bits = 0;
    for (int i = 0; i < 6; i++)
        bits |= (uint64_t)b[2 + i] << (8 * i);
    for (int i = 0; i < 16; i++)
        px[i][3] = a[(bits >> (3 * i)) & 7];
}

void bc_decode_rgba8(int fmt, const uint8_t *src, size_t src_bpr, int w, int h, uint8_t *dst)
{
    int block_bytes = fmt == 1 ? 8 : 16;
    int bw = (w + 3) / 4, bh = (h + 3) / 4;
    for (int by = 0; by < bh; by++) {
        const uint8_t *row = src + (size_t)by * src_bpr;
        for (int bx = 0; bx < bw; bx++) {
            const uint8_t *blk = row + (size_t)bx * block_bytes;
            uint8_t px[16][4];
            if (fmt == 1) {
                color_block(blk, 1, px);
            } else {
                color_block(blk + 8, 0, px);
                if (fmt == 2)
                    alpha_bc2(blk, px);
                else
                    alpha_bc3(blk, px);
            }
            for (int y = 0; y < 4; y++) {
                int py = by * 4 + y;
                if (py >= h)
                    break;
                for (int x = 0; x < 4; x++) {
                    int pxx = bx * 4 + x;
                    if (pxx >= w)
                        break;
                    memcpy(dst + ((size_t)py * w + pxx) * 4, px[y * 4 + x], 4);
                }
            }
        }
    }
}
