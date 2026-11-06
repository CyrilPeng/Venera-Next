// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 VeneraNext contributors
#include "../src/handles.h"
#include <cerrno>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <string>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#include <windows.h>
#include <winioctl.h>
#define close_fd _close
#else
#include <fcntl.h>
#include <unistd.h>
#define close_fd close
#endif

void require(bool condition, const char *message) {
  if (!condition) { std::cerr << message << '\n'; std::exit(1); }
}
int open_test(const std::filesystem::path &path) {
#ifdef _WIN32
  const int fd = _wopen(path.c_str(), _O_CREAT | _O_TRUNC | _O_RDWR | _O_BINARY,
                       _S_IREAD | _S_IWRITE);
  if (fd >= 0) {
    DWORD returned;
    require(DeviceIoControl(reinterpret_cast<HANDLE>(_get_osfhandle(fd)),
        FSCTL_SET_SPARSE, nullptr, 0, nullptr, 0, &returned, nullptr) != 0,
        "cannot mark the test file sparse");
  }
  return fd;
#else
  return open(path.c_str(), O_CREAT | O_TRUNC | O_RDWR, 0600);
#endif
}
struct Provider { int closes = 0; bool fail = false; };
void close_provider(int fd, void *owner, std::string *error) noexcept {
  auto *provider = static_cast<Provider *>(owner);
  ++provider->closes;
  close_fd(fd);
  if (provider->fail && error) {
    try { *error = "provider commit failed"; } catch (...) {}
  }
}

int main(int argc, char **argv) {
  require(argc == 2, "expected a test-only output path");
  const auto path = std::filesystem::u8path(argv[1]);
  for (int iteration = 0; iteration < 200; ++iteration) {
    Provider provider;
    const int fd = open_test(path);
    require(fd >= 0, "test open failed");
    auto *sender = saf_take_provider_descriptor(fd, &provider, close_provider);
    require(sender != nullptr, "cannot register descriptor");
    const uint64_t token = *sender;
    auto *receiver = venera_saf_retain(token);
    require(receiver != nullptr, "cannot retain descriptor");
    require(venera_saf_descriptor_count() == 1, "duplicate resource registration");
    venera_saf_release(sender);
    require(provider.closes == 0, "sender release committed the file prematurely");

    int32_t error = 0;
    const int64_t position = (INT64_C(1) << 31) + 117;
    require(venera_saf_value(token, 1, position, &error) == position && error == 0,
        "seek lost its 64-bit position");
    const uint8_t expected[] = {0xe4, 0xb8, 0xad, 0, 0xf0, 0x9f, 0x93, 0x96};
    require(venera_saf_write(token, expected, sizeof(expected), &error) == sizeof(expected),
        "full sparse-file write failed");
    require(venera_saf_value(token, 2, 0, &error) == position + sizeof(expected),
        "length lost its 64-bit value");
    require(venera_saf_value(token, 0, 0, &error) == position + sizeof(expected),
        "position did not advance after write");
    require(venera_saf_value(token, 1, position, &error) == position, "second seek failed");
    uint8_t bytes[sizeof(expected)]{};
    require(venera_saf_read(token, bytes, sizeof(bytes), &error) == sizeof(bytes), "read failed");
    require(std::string(reinterpret_cast<char *>(bytes), sizeof(bytes)) ==
        std::string(reinterpret_cast<const char *>(expected), sizeof(expected)), "read bytes differ");
    require(venera_saf_read(token, bytes, sizeof(bytes), &error) == 0, "EOF was not empty");
    require(venera_saf_value(token, 3, 7, &error) == 0, "truncate failed");
    require(venera_saf_value(token, 2, 0, &error) == 7, "truncate changed the wrong length");
    require(venera_saf_value(token, 4, 0, &error) == 0, "flush failed");
    require(venera_saf_value(token, 1, -1, &error) == -1 && error == EINVAL, "negative seek accepted");
    require(venera_saf_read(token, nullptr, 1, &error) == -1 && error == EINVAL, "null read accepted");
    char *close_error = nullptr;
    require(venera_saf_close_payload(receiver, &close_error) == 0 && close_error == nullptr,
        "ordinary provider close failed");
    require(provider.closes == 1, "provider was not closed exactly once");
    require(venera_saf_descriptor_count() == 0, "descriptor remained registered");
    require(venera_saf_retain(token) == nullptr && venera_saf_descriptor(token) == -1,
        "a stale generation remained accessible");

    const int reused_fd = open_test(path);
    auto *fresh = saf_take_descriptor(reused_fd);
    require(fresh && *fresh != token, "an OS descriptor number was used as a generation");
    require(venera_saf_value(token, 3, 0, &error) == -1 && error == EBADF,
        "a stale token affected a reused descriptor");
    venera_saf_release(fresh);
  }
  Provider failed{0, true};
  auto *lease = saf_take_provider_descriptor(open_test(path), &failed, close_provider);
  require(lease != nullptr, "cannot register failure fixture");
  char *message = nullptr;
  require(venera_saf_close_payload(lease, &message) == 1 && message &&
      std::string(message) == "provider commit failed", "provider close failure was swallowed");
  venera_saf_free(message);
  require(failed.closes == 1 && venera_saf_descriptor_count() == 0, "failed close leaked ownership");
  std::filesystem::remove(path);
  std::cout << "200 ownership/IO/error cycles and >2 GiB sparse-file checks passed\n";
}
