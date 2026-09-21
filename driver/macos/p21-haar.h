// SPDX-License-Identifier: GPL-2.0-only
#ifndef P21_HAAR_H
#define P21_HAAR_H
#include <stddef.h>
#include <stdint.h>

// One Firefly 64x16 colour strip, including its two-byte record length.
// BGRA input, 1920x1080. The final eight padded rows repeat the bottom row.
// Returns 0 on invalid arguments or insufficient output capacity.
#define P21_HAAR_STRIP_CAPACITY 8192
size_t p21_haar_strip(const uint8_t *bgra, size_t stride, unsigned x, unsigned y,
                     uint8_t *output, size_t capacity);
// Retaining four coarse coefficients is a bounded fallback for images whose
// full-detail encoded frame cannot fit in the P21's video memory.
size_t p21_haar_strip_detail(const uint8_t *bgra, size_t stride, unsigned x, unsigned y,
                            uint8_t *output, size_t capacity, unsigned coefficients);
#endif
