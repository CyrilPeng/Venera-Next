#include "window_startup.h"

#include <cstdlib>

#include "startup_log.h"

int RunWindowsApplication(Win32Window& window, const std::wstring& title) {
  const Win32Window::Point origin(10, 10);
  const Win32Window::Size size(1280, 720);
  const auto result = window.Create(title, origin, size);
  if (result == Win32Window::CreateResult::kExistingInstance) {
    LogWindowsStartup("Existing instance handled; exiting successfully");
    return EXIT_SUCCESS;
  }
  if (result == Win32Window::CreateResult::kFailed) {
    LogWindowsStartup("Startup failed");
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  MSG msg{};
  BOOL received;
  while ((received = GetMessage(&msg, nullptr, 0, 0)) > 0) {
    TranslateMessage(&msg);
    DispatchMessage(&msg);
  }
  if (received == -1) {
    LogWindowsStartup("Message loop failed", GetLastError());
    return EXIT_FAILURE;
  }
  LogWindowsStartup("Window closed");
  return EXIT_SUCCESS;
}
