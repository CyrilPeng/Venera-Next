#ifndef RUNNER_STARTUP_LOG_H_
#define RUNNER_STARTUP_LOG_H_

#include <windows.h>

#include <string>

constexpr DWORD kStartupLogMaxBytes = 128 * 1024;

// Startup diagnostics must work before the Dart application is initialized.
void InitializeWindowsStartupLog(const std::wstring& directory = {});
void ShutdownWindowsStartupLog();
void LogWindowsStartup(const char* event, DWORD error = ERROR_SUCCESS);

// Stage names must be string literals: the exception path retains their address.
void LogWindowsStartupStage(const char* stage);
void LogWindowsStartupPlatform();

// Record an escaping main-thread fault without handling it or suppressing WER.
LONG LogWindowsStartupException(EXCEPTION_POINTERS* exception) noexcept;

// The caller supplies a directory so file rotation can be tested in isolation.
bool WriteWindowsStartupLog(const std::wstring& directory, const char* event,
                            DWORD error = ERROR_SUCCESS);

#endif  // RUNNER_STARTUP_LOG_H_
