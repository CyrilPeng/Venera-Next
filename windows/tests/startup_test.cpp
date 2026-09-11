#include <windows.h>

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>

#include "startup_log.h"
#include "window_startup.h"

namespace {

void Check(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAILED: " << message << '\n';
    std::exit(EXIT_FAILURE);
  }
}

class TestWindow : public Win32Window {
 public:
  bool fail_initialization = false;
  bool close_after_create = false;
  int initialization_count = 0;

 protected:
  bool OnCreate() override {
    ++initialization_count;
    if (fail_initialization) {
      return false;
    }
    if (close_after_create) {
      Check(SetTimer(GetHandle(), 1, 10, nullptr) != 0, "SetTimer failed");
    }
    return true;
  }

  LRESULT MessageHandler(HWND hwnd, UINT message, WPARAM wparam,
                         LPARAM lparam) noexcept override {
    if (message == WM_TIMER) {
      KillTimer(hwnd, 1);
      Destroy();
      return 0;
    }
    return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  }
};

void TestStartupResults(const std::wstring& title) {
  {
    TestWindow window;
    window.close_after_create = true;
    Check(RunWindowsApplication(window, title) == EXIT_SUCCESS,
          "new window must exit successfully after closing");
    Check(window.initialization_count == 1, "new window must initialize once");
  }
  {
    TestWindow window;
    window.fail_initialization = true;
    Check(RunWindowsApplication(window, title) == EXIT_FAILURE,
          "real initialization failure must remain a nonzero exit");
  }
  {
    TestWindow primary;
    Check(primary.Create(title, {10, 10}, {120, 80}) ==
              Win32Window::CreateResult::kCreated,
          "primary window must be created");
    ShowWindow(primary.GetHandle(), SW_MINIMIZE);
    Check(IsIconic(primary.GetHandle()), "primary must be minimized");
    {
      TestWindow secondary;
      Check(RunWindowsApplication(secondary, title) == EXIT_SUCCESS,
            "repeated launch must exit successfully");
      Check(secondary.initialization_count == 0,
            "repeated launch must not initialize a second window");
      Check(secondary.GetHandle() == nullptr,
            "repeated launch must not own the primary window");
      Check(!IsIconic(primary.GetHandle()), "primary must be restored");
    }
    Check(IsWindow(primary.GetHandle()), "primary must survive secondary exit");
    ShowWindow(primary.GetHandle(), SW_MAXIMIZE);
    {
      TestWindow secondary;
      Check(RunWindowsApplication(secondary, title) == EXIT_SUCCESS,
            "maximized instance must also accept repeated launches");
      Check(IsZoomed(primary.GetHandle()), "maximized state must be preserved");
    }
  }
}

std::string ReadText(const std::filesystem::path& path) {
  std::ifstream file(path, std::ios::binary);
  return {std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
}

void TestStartupLog(const std::filesystem::path& directory) {
  SetLastError(ERROR_INVALID_HANDLE);
  Check(WriteWindowsStartupLog(directory.wstring(), "diagnostic test",
                               ERROR_ACCESS_DENIED), "log must be written");
  Check(GetLastError() == ERROR_INVALID_HANDLE,
        "logging must preserve the caller's Windows error");
  const auto path = directory / "windows-startup.log";
  const auto text = ReadText(path);
  Check(text.find("diagnostic test error=0x00000005") != std::string::npos,
        "log must include the failed stage and error code");
  Check(text.find("pid=") != std::string::npos, "log must identify the process");
  {
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    file << std::string(kStartupLogMaxBytes, 'x');
  }
  Check(WriteWindowsStartupLog(directory.wstring(), "after rotation"),
        "full log must rotate");
  Check(std::filesystem::file_size(path) < kStartupLogMaxBytes,
        "active log must stay bounded");
  Check(std::filesystem::file_size(directory / "windows-startup.previous.log") ==
            kStartupLogMaxBytes, "previous log must be retained once");
  Check(ReadText(path).find("after rotation") != std::string::npos,
        "new event must survive rotation");
  Check(!WriteWindowsStartupLog(path.wstring(), "invalid directory"),
        "an unavailable log directory must fail without throwing");
  HANDLE locked = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0,
                              nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                              nullptr);
  Check(locked != INVALID_HANDLE_VALUE, "test must lock the log");
  Check(!WriteWindowsStartupLog(directory.wstring(), "locked file"),
        "a locked log must not block startup");
  CloseHandle(locked);
}

}  // namespace

int main() {
  const auto unique_name = L"VeneraNext-startup-test-" +
                           std::to_wstring(GetCurrentProcessId());
  const auto directory = std::filesystem::temp_directory_path() / unique_name;
  Check(!std::filesystem::exists(directory), "test directory must be new");
  // No Dart entry point or application data is loaded by these native tests.
  TestStartupResults(unique_name);
  TestStartupLog(directory);
  std::filesystem::remove(directory / "windows-startup.log");
  std::filesystem::remove(directory / "windows-startup.previous.log");
  std::filesystem::remove(directory);
  std::cout << "Windows startup and log regression tests passed.\n";
  return EXIT_SUCCESS;
}
