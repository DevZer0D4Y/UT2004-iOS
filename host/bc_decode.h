#pragma once
#include <stddef.h>
#include <stdint.h>

// CPU decoders for BC1/BC2/BC3 (DXT1/DXT3/DXT5) to RGBA8, for GPUs without
// BC texture support. `fmt`: 1, 2 or 3. Source rows are rows of 4x4 blocks
// (`src_bpr` bytes each); output is w*h RGBA8 pixels, tightly packed.
void bc_decode_rgba8(int fmt, const uint8_t *src, size_t src_bpr, int w, int h, uint8_t *dst);
