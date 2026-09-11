#ifndef RUNNER_WINDOW_STARTUP_H_
#define RUNNER_WINDOW_STARTUP_H_

#include "win32_window.h"

// Runs a new window or hands off to the existing instance. The caller owns the
// window so native resources can be destroyed before COM is uninitialized.
int RunWindowsApplication(Win32Window& window, const std::wstring& title);

#endif  // RUNNER_WINDOW_STARTUP_H_
