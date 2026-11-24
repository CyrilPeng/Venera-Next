#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "startup_log.h"
#include "utils.h"
#include "window_startup.h"

namespace {

int RunFlutterApplication() {
  LogWindowsStartup("Application version " FLUTTER_VERSION);
  LogWindowsStartupStage("Inspecting runtime platform");
  LogWindowsStartupPlatform();
  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  LogWindowsStartupStage("Initializing COM");
  const HRESULT com_result = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(com_result)) {
    LogWindowsStartup("COM initialization failed", static_cast<DWORD>(com_result));
    return EXIT_FAILURE;
  }
  LogWindowsStartupStage("COM initialized");

  LogWindowsStartupStage("Preparing Flutter project");
  flutter::DartProject project(L"data");

  LogWindowsStartupStage("Reading entrypoint arguments");
  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  // Destroy the Flutter window and plugins before releasing COM.
  int exit_code;
  {
    LogWindowsStartupStage("Constructing Flutter window");
    FlutterWindow window(project);
    exit_code = RunWindowsApplication(window, L"VeneraNext");
  }
  LogWindowsStartupStage("Releasing COM");
  ::CoUninitialize();
  return exit_code;
}

int RunWithStartupDiagnostics() {
  int exit_code;
  // This function must not create C++ objects, including temporary default
  // arguments. MSVC's SEH boundary must not require object unwinding.
  __try {
    exit_code = RunFlutterApplication();
  } __except (LogWindowsStartupException(GetExceptionInformation())) {
    exit_code = EXIT_FAILURE;
  }
  return exit_code;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }
  InitializeWindowsStartupLog();
  LogWindowsStartupStage("Process started");
  const int exit_code = RunWithStartupDiagnostics();
  ShutdownWindowsStartupLog();
  return exit_code;
}
