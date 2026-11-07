// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 VeneraNext contributors

#include "venera_native.h"
#include "../third_party/lodepng/lodepng.h"
#include <stdlib.h>

unsigned venera_png_encode(const uint8_t *pixels, size_t length,
    uint32_t width, uint32_t height, uint8_t **output, size_t *output_length) {
  if (output) *output = NULL;
  if (output_length) *output_length = 0;
  if (!output || !output_length || !pixels || !width || !height) return 1001;
  if ((size_t)width > SIZE_MAX / 4 / height) return 1002;
  if (length != (size_t)width * height * 4) return 1001;
  unsigned code = lodepng_encode32(output, output_length, pixels, width, height);
  if (code || !*output || !*output_length) {
    free(*output);
    *output = NULL;
    *output_length = 0;
    return code ? code : 1003;
  }
  return 0;
}

const char *venera_png_error_text(unsigned code) {
  switch (code) {
    case 1001: return "Invalid RGBA input or dimensions";
    case 1002: return "RGBA dimensions exceed native address space";
    case 1003: return "Native encoder returned no PNG";
    default: return lodepng_error_text(code);
  }
}

void venera_native_free(void *allocation) { free(allocation); }
