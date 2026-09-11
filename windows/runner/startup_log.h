#ifndef RUNNER_STARTUP_LOG_H_
#define RUNNER_STARTUP_LOG_H_

#include <windows.h>

#include <string>

constexpr DWORD kStartupLogMaxBytes = 128 * 1024;

// Startup diagnostics must work before the Dart application is initialized.
void InitializeWindowsStartupLog();
void LogWindowsStartup(const char* event, DWORD error = ERROR_SUCCESS);

// The caller supplies a directory so file rotation can be tested in isolation.
bool WriteWindowsStartupLog(const std::wstring& directory, const char* event,
                            DWORD error = ERROR_SUCCESS);

#endif  // RUNNER_STARTUP_LOG_H_
