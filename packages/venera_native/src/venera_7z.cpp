// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 VeneraNext contributors

#include "venera_native.h"
#include "7z.h"
#include "7zAlloc.h"
#include "7zCrc.h"
#include "7zFile.h"
#include <cstdlib>
#include <mutex>
#include <new>
#include <string>
#ifdef _WIN32
#include <windows.h>
#endif

namespace {
std::once_flag crc_initialized;
const ISzAlloc allocator = {SzAlloc, SzFree};

struct Archive {
  CFileInStream stream{};
  CLookToRead2 look{};
  CSzArEx database{};
  UInt32 block_index = UINT32_MAX;
  Byte *block = nullptr;
  size_t block_size = 0;
  bool opened = false;

  Archive() {
    File_Construct(&stream.file);
    SzArEx_Init(&database);
  }
  ~Archive() {
    SzFree(nullptr, block);
    SzArEx_Free(&database, &allocator);
    std::free(look.buf);
    if (opened) File_Close(&stream.file);
  }
};

bool valid(Archive *archive, uint32_t index) {
  return archive && index < archive->database.NumFiles;
}
}  // namespace

void *venera_7z_open(const char *path, uint32_t *status) {
  if (!status) return nullptr;
  *status = SZ_ERROR_PARAM;
  if (!path || !*path) return nullptr;
  Archive *archive = nullptr;
  try {
    archive = new Archive;
    std::call_once(crc_initialized, CrcGenerateTable);
#ifdef _WIN32
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, nullptr, 0);
    if (!count) { delete archive; return nullptr; }
    std::wstring wide(static_cast<size_t>(count), L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide.data(), count);
    if (InFile_OpenW(&archive->stream.file, wide.c_str()) != 0) {
#else
    if (InFile_Open(&archive->stream.file, path) != 0) {
#endif
      *status = SZ_ERROR_READ;
      delete archive;
      return nullptr;
    }
    archive->opened = true;
    FileInStream_CreateVTable(&archive->stream);
    archive->look.realStream = &archive->stream.vt;
    archive->look.bufSize = 1 << 16;
    archive->look.buf = static_cast<Byte *>(std::malloc(archive->look.bufSize));
    if (!archive->look.buf) {
      *status = SZ_ERROR_MEM;
      delete archive;
      return nullptr;
    }
    LookToRead2_CreateVTable(&archive->look, False);
    LookToRead2_INIT(&archive->look);
    *status = SzArEx_Open(&archive->database, &archive->look.vt, &allocator, &allocator);
    if (*status != SZ_OK) { delete archive; return nullptr; }
    return archive;
  } catch (...) {
    delete archive;
    *status = SZ_ERROR_MEM;
    return nullptr;
  }
}

void venera_7z_close(void *archive) { delete static_cast<Archive *>(archive); }

uint32_t venera_7z_count(void *handle) {
  auto *archive = static_cast<Archive *>(handle);
  return archive ? archive->database.NumFiles : 0;
}

size_t venera_7z_name(void *handle, uint32_t index, uint16_t *buffer, size_t capacity) {
  auto *archive = static_cast<Archive *>(handle);
  if (!valid(archive, index) || !archive->database.FileNameOffsets) return 0;
  size_t count = SzArEx_GetFileNameUtf16(&archive->database, index, nullptr);
  if (!buffer) return count;
  if (capacity < count) return 0;
  return SzArEx_GetFileNameUtf16(&archive->database, index, buffer);
}

int32_t venera_7z_kind(void *handle, uint32_t index) {
  auto *archive = static_cast<Archive *>(handle);
  if (!valid(archive, index)) return -1;
  const auto &db = archive->database;
  if (db.Attribs.Defs && SzBitWithVals_Check(&db.Attribs, index)) {
    const uint32_t attributes = db.Attribs.Vals[index];
    if ((attributes & 0x400) || ((attributes >> 16) & 0170000) == 0120000) return 2;
  }
  return SzArEx_IsDir(&db, index) ? 1 : 0;
}

unsigned venera_7z_read(void *handle, uint32_t index,
    const uint8_t **output, size_t *length) {
  if (output) *output = nullptr;
  if (length) *length = 0;
  auto *archive = static_cast<Archive *>(handle);
  if (!output || !length || !valid(archive, index) || venera_7z_kind(handle, index) != 0)
    return SZ_ERROR_PARAM;
  const UInt64 expected = SzArEx_GetFileSize(&archive->database, index);
  if (expected > SIZE_MAX) return SZ_ERROR_MEM;
  size_t offset = 0, processed = 0;
  const SRes code = SzArEx_Extract(&archive->database, &archive->look.vt, index,
      &archive->block_index, &archive->block, &archive->block_size, &offset, &processed,
      &allocator, &allocator);
  if (code != SZ_OK) return code;
  if (processed != expected || processed > archive->block_size ||
      offset > archive->block_size - processed) return SZ_ERROR_DATA;
  if (processed && !archive->block) return SZ_ERROR_DATA;
  *output = processed ? archive->block + offset : nullptr;
  *length = processed;
  return SZ_OK;
}
