//
// Created by yangbin on 2021/11/12.
//

#include <windows.h>
#include "flutter_view.h"

#include <iostream>

#include "utils.h"
#include "message_channel_plugin.h"

namespace webview_window {

FlutterView::FlutterView(std::vector<std::string> arguments) {

  flutter::DartProject project(L"data");
  project.set_dart_entrypoint_arguments(std::move(arguments));
  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(0, 0, project);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    std::cerr << "Failed to setup Flutter engine." << std::endl;
    return;
  }
  RegisterClientMessageChannelPlugin(flutter_controller_->engine()->GetRegistrarForPlugin("DesktopWebviewWindowPlugin"));
}

FlutterView::~FlutterView() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }
}

std::optional<LRESULT> FlutterView::HandleTopLevelWindowProc(HWND hwnd, UINT message, WPARAM w_param, LPARAM l_param) {
  return flutter_controller_->HandleTopLevelWindowProc(hwnd, message, w_param, l_param);
}

void FlutterView::ReloadSystemFonts() {
  flutter_controller_->engine()->ReloadSystemFonts();
}

void FlutterView::ForceRedraw() {

}

}

