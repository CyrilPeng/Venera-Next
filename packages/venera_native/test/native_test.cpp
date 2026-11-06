// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 VeneraNext contributors
#include "../src/venera_native.h"
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

static void check(bool condition, const char *message) {
  if (!condition) { std::cerr << message << '\n'; std::exit(1); }
}

int main(int argc, char **argv) {
  check(argc == 2, "Fixture directory is required");
  const std::string fixtures = argv[1];
  const uint8_t pixels[] = {255, 0, 0, 255, 0, 20, 255, 128};
  for (int i = 0; i < 100; ++i) {
    uint8_t *encoded = nullptr;
    size_t length = 0;
    check(venera_png_encode(pixels, sizeof(pixels), 2, 1, &encoded, &length) == 0,
        "PNG encoding failed");
    check(encoded && length > 8 && !std::memcmp(encoded, "\x89PNG\r\n\x1a\n", 8),
        "PNG signature is invalid");
    venera_native_free(encoded);
    encoded = reinterpret_cast<uint8_t *>(1);
    length = 100;
    check(venera_png_encode(pixels, sizeof(pixels) - 1, 2, 1, &encoded, &length) != 0,
        "Short RGBA input was accepted");
    check(!encoded && !length, "Failed encoder exposed an output buffer");
    check(venera_png_encode(nullptr, 0, 0, 0, &encoded, &length) != 0,
        "Null input was accepted");
    check(venera_png_encode(pixels, sizeof(pixels), UINT32_MAX, UINT32_MAX, &encoded, &length) != 0
        && !encoded && !length, "Overflowing RGBA dimensions were accepted");
    uint32_t status = 0;
    check(!venera_7z_open("venera-native-missing-test-file.7z", &status) && status != 0,
        "Missing archive was accepted");
    check(venera_7z_kind(nullptr, 0) == -1 && venera_7z_count(nullptr) == 0,
        "Null archive metadata is invalid");
    const uint8_t *data = reinterpret_cast<uint8_t *>(1);
    length = 100;
    check(venera_7z_read(nullptr, 0, &data, &length) != 0 && !data && !length,
        "Failed archive read exposed a byte buffer");
    venera_7z_close(nullptr);
    venera_native_free(nullptr);
    void *archive = venera_7z_open((fixtures + "/copy.7z").c_str(), &status);
    check(archive && status == 0 && venera_7z_count(archive) == 1,
        "Valid Copy archive failed to open");
    const size_t units = venera_7z_name(archive, 0, nullptr, 0);
    std::vector<uint16_t> name(units);
    check(units > 1 && venera_7z_name(archive, 0, name.data(), units) == units,
        "Archive filename could not be read");
    check(venera_7z_name(archive, 0, name.data(), units - 1) == 0,
        "Short filename buffer was accepted");
    check(venera_7z_read(archive, 0, &data, &length) == 0 && length == 13 &&
        !std::memcmp(data, "verified-data", length), "Valid archive bytes differ");
    check(venera_7z_read(archive, 1, &data, &length) != 0 && !data && !length,
        "Out-of-range archive read was accepted");
    venera_7z_close(archive);
    archive = venera_7z_open((fixtures + "/bad-crc.7z").c_str(), &status);
    check(archive && venera_7z_read(archive, 0, &data, &length) != 0 && !data && !length,
        "Corrupted archive payload was accepted");
    venera_7z_close(archive);
    archive = venera_7z_open((fixtures + "/symlink.7z").c_str(), &status);
    check(archive && venera_7z_kind(archive, 0) == 2, "Link attributes were not recognized");
    venera_7z_close(archive);
    archive = venera_7z_open((fixtures + "/missing-name.7z").c_str(), &status);
    check(archive && venera_7z_name(archive, 0, nullptr, 0) == 0,
        "Missing filename metadata was not rejected safely");
    venera_7z_close(archive);
    check(!venera_7z_open((fixtures + "/truncated.7z").c_str(), &status) && status,
        "Truncated archive was accepted");
  }
  std::cout << "Native ABI validation and repeated ownership checks passed\n";
}
