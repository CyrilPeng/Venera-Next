// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 VeneraNext contributors
#pragma once
#include <cstddef>
#include <cstdint>
#include <string>

#ifdef _WIN32
#define SAF_EXPORT __declspec(dllexport)
#else
#define SAF_EXPORT __attribute__((visibility("default")))
#endif

// Takes ownership of fd even on allocation failure. Each returned payload owns
// one reference; a receiver retains before a sender releases its reference.
uint64_t *saf_take_descriptor(int fd) noexcept;
using SafCloseCallback = void (*)(int, void *, std::string *) noexcept;
uint64_t *saf_take_provider_descriptor(int fd, void *owner, SafCloseCallback close) noexcept;

extern "C" {
SAF_EXPORT uint64_t *venera_saf_retain(uint64_t token);
SAF_EXPORT int32_t venera_saf_descriptor(uint64_t token);
SAF_EXPORT void venera_saf_release(void *payload);
SAF_EXPORT int32_t venera_saf_close_payload(void *payload, char **error);
SAF_EXPORT int64_t venera_saf_read(uint64_t token, uint8_t *bytes, size_t count, int32_t *error);
SAF_EXPORT int64_t venera_saf_write(uint64_t token, const uint8_t *bytes, size_t count, int32_t *error);
SAF_EXPORT int64_t venera_saf_value(uint64_t token, int32_t operation, int64_t value, int32_t *error);
SAF_EXPORT uint64_t venera_saf_descriptor_count();
SAF_EXPORT void venera_saf_free(void *allocation);
}
