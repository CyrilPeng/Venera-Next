//
// Created by yangbin on 2021/11/12.
//

#ifndef WEBVIEW_WINDOW_WINDOWS_FLUTTER_VIEW_H_
#define WEBVIEW_WINDOW_WINDOWS_FLUTTER_VIEW_H_

#include "windows.h"

#include <flutter/flutter_view_controller.h>

namespace webview_window {

class FlutterView {

 public:

  FlutterView(std::vector<std::string> arguments);

  virtual ~FlutterView();

  std::optional<LRESULT> HandleTopLevelWindowProc(HWND hwnd, UINT message, WPARAM w_param, LPARAM l_param);

  [[nodiscard]] HWND GetWindow() const { return flutter_controller_->view()->GetNativeWindow(); }

  void ReloadSystemFonts();

  void ForceRedraw();

 private:

  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

};

}

#endif //WEBVIEW_WINDOW_WINDOWS_FLUTTER_VIEW_H_
