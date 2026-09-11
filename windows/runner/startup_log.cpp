#include "startup_log.h"

#include <shlobj.h>

#include <cstdio>
#include <filesystem>
#include <system_error>

namespace {

std::wstring log_directory;

std::string FormatEntry(const char* event, DWORD error) {
  SYSTEMTIME time{};
  GetSystemTime(&time);
  char line[512]{};
  _snprintf_s(line, sizeof(line), _TRUNCATE,
              "%04u-%02u-%02uT%02u:%02u:%02u.%03uZ pid=%lu %s error=0x%08lX\r\n",
              time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute,
              time.wSecond, time.wMilliseconds, GetCurrentProcessId(), event,
              error);
  return line;
}

std::wstring LogDirectory() {
  PWSTR local_app_data = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_DEFAULT,
                                 nullptr, &local_app_data))) {
    return {};
  }
  std::filesystem::path directory(local_app_data);
  CoTaskMemFree(local_app_data);
  return (directory / L"com.github.cyrilpeng" / L"VeneraNext" / L"logs").wstring();
}

bool WriteEntry(const std::wstring& directory, const std::string& entry) {
  if (directory.empty()) {
    return false;
  }
  std::error_code error;
  std::filesystem::create_directories(directory, error);
  if (error) {
    return false;
  }
  const auto path = std::filesystem::path(directory) / L"windows-startup.log";
  const auto previous = std::filesystem::path(directory) /
                        L"windows-startup.previous.log";
  HANDLE file = INVALID_HANDLE_VALUE;
  // Only one process may write or rotate the log at a time. Logging never
  // blocks startup indefinitely when another instance owns the file.
  for (int attempt = 0; attempt < 3; ++attempt) {
    file = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE,
                       FILE_SHARE_READ, nullptr, OPEN_ALWAYS,
                       FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file != INVALID_HANDLE_VALUE ||
        GetLastError() != ERROR_SHARING_VIOLATION) {
      break;
    }
    Sleep(5);
  }
  if (file == INVALID_HANDLE_VALUE) {
    return false;
  }
  LARGE_INTEGER size{};
  bool success = GetFileSizeEx(file, &size) != FALSE;
  if (success && size.QuadPart + entry.size() > kStartupLogMaxBytes) {
    if (size.QuadPart <= kStartupLogMaxBytes) {
      CopyFileW(path.c_str(), previous.c_str(), FALSE);
    }
    LARGE_INTEGER beginning{};
    success = SetFilePointerEx(file, beginning, nullptr, FILE_BEGIN) &&
              SetEndOfFile(file);
  }
  LARGE_INTEGER end{};
  DWORD written = 0;
  success = success && SetFilePointerEx(file, end, nullptr, FILE_END) &&
            WriteFile(file, entry.data(), static_cast<DWORD>(entry.size()),
                      &written, nullptr) && written == entry.size();
  CloseHandle(file);
  return success;
}

}  // namespace

void InitializeWindowsStartupLog() {
  const DWORD saved_error = GetLastError();
  log_directory = LogDirectory();
  SetLastError(saved_error);
}

bool WriteWindowsStartupLog(const std::wstring& directory, const char* event,
                            DWORD error) {
  const DWORD saved_error = GetLastError();
  const bool success = WriteEntry(directory, FormatEntry(event, error));
  SetLastError(saved_error);
  return success;
}

void LogWindowsStartup(const char* event, DWORD error) {
  const DWORD saved_error = GetLastError();
  const auto entry = FormatEntry(event, error);
  OutputDebugStringA(entry.c_str());
  std::fputs(entry.c_str(), stderr);
  std::fflush(stderr);
  WriteEntry(log_directory, entry);
  SetLastError(saved_error);
}
