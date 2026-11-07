// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 VeneraNext contributors

#include "handles.h"
#include <cstdlib>
#include <cerrno>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <sys/stat.h>
#include <unordered_map>
#ifdef _WIN32
#include <io.h>
#define close_descriptor _close
#define read_descriptor _read
#define write_descriptor _write
#define seek_descriptor _lseeki64
#define flush_descriptor _commit
#else
#include <unistd.h>
#define close_descriptor close
#define read_descriptor read
#define write_descriptor write
#define seek_descriptor lseek
#define flush_descriptor fsync
#endif

namespace {
struct Resource {
  int descriptor;
  void *owner;
  SafCloseCallback close;
  std::mutex operations;
  bool closed = false;
  Resource(int fd, void *owner, SafCloseCallback close)
      : descriptor(fd), owner(owner), close(close) {}
  void finish(std::string *error) noexcept {
    if (!closed) { closed = true; close(descriptor, owner, error); }
  }
  ~Resource() { finish(nullptr); }
};
struct Entry { std::shared_ptr<Resource> resource; size_t owners; };
std::mutex registry_mutex;
std::unordered_map<uint64_t, Entry> registry;
uint64_t next_token = 1;

void close_native(int descriptor, void *, std::string *error) noexcept {
  if (close_descriptor(descriptor) != 0 && error) {
    try { *error = std::strerror(errno); } catch (...) {}
  }
}

std::shared_ptr<Resource> borrow(uint64_t token, int32_t *error) {
  if (error) *error = 0;
  std::lock_guard<std::mutex> lock(registry_mutex);
  auto found = registry.find(token);
  if (found == registry.end()) {
    if (error) *error = EBADF;
    return nullptr;
  }
  return found->second.resource;
}

void release(void *payload, std::string *error) {
  if (!payload) return;
  const uint64_t token = *static_cast<uint64_t *>(payload);
  std::shared_ptr<Resource> resource;
  {
    std::lock_guard<std::mutex> lock(registry_mutex);
    auto found = registry.find(token);
    if (found != registry.end() && --found->second.owners == 0) {
      resource = std::move(found->second.resource);
      registry.erase(found);
    }
  }
  // In-flight operations retain the resource until their syscall finishes.
  // Removing the generation now prevents new calls or an FD-reuse race.
  if (resource && resource.use_count() == 1) resource->finish(error);
  std::free(payload);
}
}

uint64_t *saf_take_descriptor(int fd) noexcept {
  return saf_take_provider_descriptor(fd, nullptr, close_native);
}

uint64_t *saf_take_provider_descriptor(int fd, void *owner, SafCloseCallback close) noexcept {
  if (fd < 0) return nullptr;
  auto *payload = static_cast<uint64_t *>(std::malloc(sizeof(uint64_t)));
  if (!payload) { close(fd, owner, nullptr); return nullptr; }
  std::shared_ptr<Resource> resource;
  try {
    resource = std::make_shared<Resource>(fd, owner, close);
    std::lock_guard<std::mutex> lock(registry_mutex);
    // Never wrap around and reuse a stale generation ID.
    if (next_token == UINT64_MAX) {
      std::free(payload); return nullptr;
    }
    const uint64_t token = next_token++;
    registry.emplace(token, Entry{resource, 1});
    *payload = token;
    return payload;
  } catch (...) {
    std::free(payload);
    if (!resource) close(fd, owner, nullptr);
    return nullptr;
  }
}

uint64_t *venera_saf_retain(uint64_t token) try {
  std::unique_ptr<uint64_t, decltype(&std::free)> payload(
      static_cast<uint64_t *>(std::malloc(sizeof(uint64_t))), &std::free);
  if (!payload) return nullptr;
  std::lock_guard<std::mutex> lock(registry_mutex);
  auto found = registry.find(token);
  if (found == registry.end() || found->second.owners == SIZE_MAX) {
    return nullptr;
  }
  ++found->second.owners;
  *payload = token;
  return payload.release();
} catch (...) { return nullptr; }

int32_t venera_saf_descriptor(uint64_t token) try {
  std::lock_guard<std::mutex> lock(registry_mutex);
  auto found = registry.find(token);
  return found == registry.end() ? -1 : found->second.resource->descriptor;
} catch (...) { return -1; }

void venera_saf_release(void *payload) try {
  release(payload, nullptr);
} catch (...) {}

int32_t venera_saf_close_payload(void *payload, char **error) try {
  if (error) *error = nullptr;
  std::string message;
  release(payload, &message);
  if (message.empty()) return 0;
  if (error) {
    *error = static_cast<char *>(std::malloc(message.size() + 1));
    if (*error) std::memcpy(*error, message.c_str(), message.size() + 1);
  }
  return 1;
} catch (...) { return 1; }

int64_t venera_saf_read(uint64_t token, uint8_t *bytes, size_t count, int32_t *error) try {
  if (!error) return -1;
  auto resource = borrow(token, error);
  if (!resource) return -1;
  if ((!bytes && count) || count > INT32_MAX) { *error = EINVAL; return -1; }
  std::lock_guard<std::mutex> lock(resource->operations);
  int64_t result;
  do { result = read_descriptor(resource->descriptor, bytes, count); }
  while (result < 0 && errno == EINTR);
  if (result < 0) *error = errno;
  return result;
} catch (...) { if (error) *error = EIO; return -1; }

int64_t venera_saf_write(uint64_t token, const uint8_t *bytes, size_t count, int32_t *error) try {
  if (!error) return -1;
  auto resource = borrow(token, error);
  if (!resource) return -1;
  if ((!bytes && count) || count > INT32_MAX) { *error = EINVAL; return -1; }
  std::lock_guard<std::mutex> lock(resource->operations);
  size_t written = 0;
  while (written < count) {
    const int64_t result = write_descriptor(resource->descriptor, bytes + written, count - written);
    if (result < 0 && errno == EINTR) continue;
    if (result <= 0) { *error = result < 0 ? errno : EIO; return -1; }
    written += static_cast<size_t>(result);
  }
  return static_cast<int64_t>(written);
} catch (...) { if (error) *error = EIO; return -1; }

int64_t venera_saf_value(uint64_t token, int32_t operation, int64_t value, int32_t *error) try {
  if (!error) return -1;
  auto resource = borrow(token, error);
  if (!resource) return -1;
  std::lock_guard<std::mutex> lock(resource->operations);
  int64_t result = -1;
  switch (operation) {
    case 0: result = seek_descriptor(resource->descriptor, 0, SEEK_CUR); break;
    case 1:
      if (value < 0) { *error = EINVAL; return -1; }
      result = seek_descriptor(resource->descriptor, value, SEEK_SET); break;
    case 2: {
#ifdef _WIN32
      struct _stat64 info;
      if (_fstat64(resource->descriptor, &info) == 0) {
        if ((info.st_mode & _S_IFMT) != _S_IFREG) { *error = EINVAL; return -1; }
#else
      struct stat info;
      if (fstat(resource->descriptor, &info) == 0) {
        if (!S_ISREG(info.st_mode)) { *error = EINVAL; return -1; }
#endif
        return info.st_size;
      }
      break;
    }
    case 3:
      if (value < 0) { *error = EINVAL; return -1; }
#ifdef _WIN32
      *error = _chsize_s(resource->descriptor, value);
      return *error ? -1 : 0;
#else
      result = ftruncate(resource->descriptor, value); break;
#endif
    case 4: result = flush_descriptor(resource->descriptor); break;
    default: *error = EINVAL; return -1;
  }
  if (result < 0) *error = errno;
  return result;
} catch (...) { if (error) *error = EIO; return -1; }

uint64_t venera_saf_descriptor_count() try {
  std::lock_guard<std::mutex> lock(registry_mutex);
  return registry.size();
} catch (...) { return 0; }

void venera_saf_free(void *allocation) { std::free(allocation); }
