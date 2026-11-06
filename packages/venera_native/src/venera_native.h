// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 VeneraNext contributors
#ifndef VENERA_NATIVE_H
#define VENERA_NATIVE_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#define VENERA_EXPORT __declspec(dllexport)
#else
#define VENERA_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
extern "C" {
#endif

VENERA_EXPORT unsigned venera_png_encode(const uint8_t *pixels, size_t length,
    uint32_t width, uint32_t height, uint8_t **output, size_t *output_length);
VENERA_EXPORT const char *venera_png_error_text(unsigned code);
VENERA_EXPORT void venera_native_free(void *allocation);

VENERA_EXPORT void *venera_7z_open(const char *path, uint32_t *status);
VENERA_EXPORT void venera_7z_close(void *archive);
VENERA_EXPORT uint32_t venera_7z_count(void *archive);
VENERA_EXPORT size_t venera_7z_name(void *archive, uint32_t index,
    uint16_t *buffer, size_t capacity);
// 0: regular file, 1: directory, 2: link/reparse point, -1: invalid index.
VENERA_EXPORT int32_t venera_7z_kind(void *archive, uint32_t index);
// The returned data is borrowed until the next read or archive close.
VENERA_EXPORT unsigned venera_7z_read(void *archive, uint32_t index,
    const uint8_t **output, size_t *length);

#ifdef __cplusplus
}
#endif
#endif
