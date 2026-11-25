#include "startup_log.h"

#include <shlobj.h>

#if defined(_M_X64) || defined(_M_IX86)
#include <intrin.h>
#endif

#include <atomic>
#include <cstdio>
#include <cstdint>
#include <filesystem>
#include <system_error>

namespace {

std::wstring log_directory;
HANDLE exception_log = INVALID_HANDLE_VALUE;
std::atomic<const char*> startup_stage{"Process entry"};
std::atomic<bool> exception_recorded{false};

constexpr DWORD kExceptionEntryBytes = 1024;

const char* ArchitectureName(WORD architecture) {
  switch (architecture) {
    case PROCESSOR_ARCHITECTURE_AMD64:
      return "x64";
    case PROCESSOR_ARCHITECTURE_ARM64:
      return "arm64";
    case PROCESSOR_ARCHITECTURE_INTEL:
      return "x86";
    default:
      return "unknown";
  }
}

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

HANDLE PrepareExceptionLog(const std::wstring& directory) {
  if (directory.empty()) return INVALID_HANDLE_VALUE;
  std::error_code error;
  std::filesystem::create_directories(directory, error);
  if (error) return INVALID_HANDLE_VALUE;
  const auto path = std::filesystem::path(directory) / L"windows-startup-crash.log";
  const auto size = std::filesystem::file_size(path, error);
  DWORD creation = OPEN_ALWAYS;
  if (!error && size > kStartupLogMaxBytes - kExceptionEntryBytes) {
    const auto previous = std::filesystem::path(directory) /
                          L"windows-startup-crash.previous.log";
    if (!CopyFileW(path.c_str(), previous.c_str(), FALSE)) {
      return INVALID_HANDLE_VALUE;
    }
    creation = CREATE_ALWAYS;
  }
  // Reserve the handle before a fault. The exception filter uses only stack
  // buffers and Win32 calls, not filesystem allocation or the normal logger.
  return CreateFileW(path.c_str(), FILE_APPEND_DATA | FILE_READ_ATTRIBUTES,
                     FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                     nullptr, creation, FILE_ATTRIBUTE_NORMAL, nullptr);
}

}  // namespace

void InitializeWindowsStartupLog(const std::wstring& directory) {
  const DWORD saved_error = GetLastError();
  ShutdownWindowsStartupLog();
  log_directory = directory.empty() ? LogDirectory() : directory;
  startup_stage.store("Process entry");
  exception_recorded.store(false);
  exception_log = PrepareExceptionLog(log_directory);
  SetLastError(saved_error);
}

void ShutdownWindowsStartupLog() {
  const DWORD saved_error = GetLastError();
  if (exception_log != INVALID_HANDLE_VALUE) {
    CloseHandle(exception_log);
    exception_log = INVALID_HANDLE_VALUE;
  }
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

void LogWindowsStartupStage(const char* stage) {
  startup_stage.store(stage);
  LogWindowsStartup(stage);
}

void LogWindowsStartupPlatform() {
  const DWORD saved_error = GetLastError();
  SYSTEM_INFO process{}, native{};
  GetSystemInfo(&process);
  GetNativeSystemInfo(&native);
  OSVERSIONINFOW version{};
  version.dwOSVersionInfoSize = sizeof(version);
  using RtlGetVersionFunction = LONG(WINAPI*)(OSVERSIONINFOW*);
  const auto get_version = reinterpret_cast<RtlGetVersionFunction>(
      GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion"));
  const bool has_version = get_version && get_version(&version) == 0;
  unsigned cpu_known = 0, cpu_ecx = 0, cpu_edx = 0;
#if defined(_M_X64) || defined(_M_IX86)
  // Query the CPU directly: newer PF_* constants can be unknown to older
  // Windows versions even when the processor implements the instructions.
  int registers[4]{};
  __cpuid(registers, 0);
  if (registers[0] >= 1) {
    __cpuid(registers, 1);
    cpu_known = 1;
    cpu_ecx = static_cast<unsigned>(registers[2]);
    cpu_edx = static_cast<unsigned>(registers[3]);
  }
#endif
  char event[256]{};
  _snprintf_s(event, sizeof(event), _TRUNCATE,
              "Runtime platform process=%s native=%s windows=%lu.%lu.%lu "
              "version_known=%u cpu_known=%u sse2=%u sse3=%u sse41=%u sse42=%u",
              ArchitectureName(process.wProcessorArchitecture),
              ArchitectureName(native.wProcessorArchitecture),
              version.dwMajorVersion, version.dwMinorVersion,
              version.dwBuildNumber, static_cast<unsigned>(has_version),
              cpu_known, (cpu_edx >> 26) & 1, cpu_ecx & 1,
              (cpu_ecx >> 19) & 1, (cpu_ecx >> 20) & 1);
  LogWindowsStartup(event);
  SetLastError(saved_error);
}

LONG LogWindowsStartupException(EXCEPTION_POINTERS* exception) noexcept {
  const DWORD saved_error = GetLastError();
  if (!exception || !exception->ExceptionRecord ||
      exception_log == INVALID_HANDLE_VALUE || exception_recorded.exchange(true)) {
    SetLastError(saved_error);
    return EXCEPTION_CONTINUE_SEARCH;
  }
  const auto* record = exception->ExceptionRecord;
  char module[256] = "unknown";
  unsigned long long offset = 0;
  MEMORY_BASIC_INFORMATION memory{};
  if (VirtualQuery(record->ExceptionAddress, &memory, sizeof(memory)) &&
      memory.Type == MEM_IMAGE) {
    wchar_t path[MAX_PATH]{};
    const DWORD length = GetModuleFileNameW(
        static_cast<HMODULE>(memory.AllocationBase), path, MAX_PATH);
    if (length > 0 && length < MAX_PATH) {
      const wchar_t* basename = path;
      for (const wchar_t* current = path; *current; ++current) {
        if (*current == L'\\' || *current == L'/') basename = current + 1;
      }
      WideCharToMultiByte(CP_UTF8, 0, basename, -1, module,
                          static_cast<int>(sizeof(module)), nullptr, nullptr);
      offset = static_cast<unsigned long long>(
          reinterpret_cast<std::uintptr_t>(record->ExceptionAddress) -
          reinterpret_cast<std::uintptr_t>(memory.AllocationBase));
    }
  }
  SYSTEMTIME time{};
  GetSystemTime(&time);
  char line[kExceptionEntryBytes]{};
  const int length = _snprintf_s(
      line, sizeof(line), _TRUNCATE,
      "%04u-%02u-%02uT%02u:%02u:%02u.%03uZ pid=%lu "
      "Native startup exception stage=\"%s\" exception=0x%08lX "
      "module=%s offset=0x%llX\r\n",
      time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute,
      time.wSecond, time.wMilliseconds, GetCurrentProcessId(),
      startup_stage.load(), record->ExceptionCode, module, offset);
  if (length > 0) {
    DWORD written = 0;
    WriteFile(exception_log, line, static_cast<DWORD>(length), &written, nullptr);
    FlushFileBuffers(exception_log);
  }
  SetLastError(saved_error);
  return EXCEPTION_CONTINUE_SEARCH;
}
