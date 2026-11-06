//
// Created by yangbin on 2021/10/20.
//

#include <windows.h>

#include "webview_window.h"

#include <tchar.h>
#include <utility>

#include "strconv.h"
#include "utils.h"

#include "include/desktop_webview_window/desktop_webview_window_plugin.h"

namespace {

TCHAR kWebViewWindowClassName[] = _T("WebviewWindow");

using namespace webview_window;

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

}

using namespace Microsoft::WRL;

WebviewWindow::WebviewWindow(
    MethodChannelPtr method_channel,
    int64_t window_id,
    int title_bar_height,
    std::function<void()> on_close_callback
) : method_channel_(std::move(method_channel)),
    window_id_(window_id),
    on_close_callback_(std::move(on_close_callback)),
    hwnd_(),
    title_bar_height_(title_bar_height) {

}

WebviewWindow::~WebviewWindow() {
  flutter_action_bar_.reset();
  web_view_.reset();
  SetWindowLongPtr(hwnd_.get(), GWLP_USERDATA, 0);
  hwnd_.reset();
}

void WebviewWindow::CreateAndShow(const std::wstring &title, int height, int width,
                                  const std::wstring &userDataFolder,
                                  int windowPosX, int windowPosY, bool useWindowPositionAndSize,
                                  bool openMaximized, CreateCallback callback, const std::wstring &proxy) {

  RegisterWindowClass(kWebViewWindowClassName, WebviewWindow::WndProc);

  // the same as flutter default main.cpp
  const POINT target_point = {static_cast<LONG>(10),
                              static_cast<LONG>(10)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);

  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  DWORD dwStyle = WS_OVERLAPPEDWINDOW | WS_VISIBLE;
  if (openMaximized)
    dwStyle |= WS_MAXIMIZE;

  if (useWindowPositionAndSize) {
    hwnd_ = wil::unique_hwnd(::CreateWindow(
      kWebViewWindowClassName, title.c_str(),
      dwStyle,
      windowPosX, windowPosY,
      width, height,
      nullptr, nullptr, GetModuleHandle(nullptr), this));
  } else {
    hwnd_ = wil::unique_hwnd(::CreateWindow(
      kWebViewWindowClassName, title.c_str(),
      dwStyle,
      CW_USEDEFAULT, CW_USEDEFAULT,
      Scale(width, scale_factor), Scale(height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this));
  }
  if (!hwnd_) {
    callback(false);
    return;
  }

  // Centered window on screen.
  RECT rc;
  GetClientRect(hwnd_.get(), &rc);
  if (!useWindowPositionAndSize && !openMaximized) {
    ClipOrCenterRectToMonitor(&rc, MONITOR_CENTER);
    SetWindowPos(hwnd_.get(), nullptr, rc.left, rc.top, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  }

  auto title_bar_height = Scale(title_bar_height_, scale_factor);

  // Create the browser view.
  web_view_ = std::make_unique<webview_window::WebView>(
      method_channel_, window_id_, userDataFolder,
      [callback](HRESULT hr) {
        if (SUCCEEDED(hr)) {
          callback(true);
        } else {
          callback(false);
        }
      }, proxy);

  auto web_view_handle = web_view_->NativeWindow().get();
  SetParent(web_view_handle, hwnd_.get());
  MoveWindow(web_view_handle, 0, title_bar_height,
             rc.right - rc.left,
             rc.bottom - rc.top - title_bar_height,
             true);
  ShowWindow(web_view_handle, SW_SHOW);

  // Create the title bar view.
  std::vector<std::string> args = {"web_view_title_bar", std::to_string(window_id_)};
  flutter_action_bar_ = std::make_unique<webview_window::FlutterView>(std::move(args));
  auto title_bar_handle = flutter_action_bar_->GetWindow();
  SetParent(title_bar_handle, hwnd_.get());
  MoveWindow(title_bar_handle, 0, 0, rc.right - rc.left, title_bar_height, true);
  ShowWindow(title_bar_handle, SW_SHOW);

  assert(hwnd_ != nullptr);

  ShowWindow(hwnd_.get(), SW_SHOW);
  UpdateWindow(hwnd_.get());

}

void WebviewWindow::SetBrightness(int brightness) {
}

void WebviewWindow::setVisibility(bool visible)
{
  if(visible)
    ::ShowWindow(hwnd_.get(), SW_SHOW);
  else
    ::ShowWindow(hwnd_.get(), SW_HIDE);
}

void WebviewWindow::moveWebviewWindow(int left, int top, int width, int height) {
  ::SetWindowPos(hwnd_.get(), nullptr, left, top, width, height, SWP_NOZORDER | SWP_NOACTIVATE);
}

void WebviewWindow::bringToForeground(bool maximized) {
  SetForegroundWindow(hwnd_.get());
  if (maximized) {
    ::ShowWindow(hwnd_.get(), SW_MAXIMIZE);
  }
}

void WebviewWindow::getPositionalParameters(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> completer) {
  RECT rc;
  GetWindowRect(hwnd_.get(), &rc);

  std::unique_ptr<WINDOWPLACEMENT> wp(new WINDOWPLACEMENT);
  GetWindowPlacement(hwnd_.get(), wp.get());
  std::map<flutter::EncodableValue, flutter::EncodableValue> m{
    {"left", rc.left},
    {"top", rc.top},
    {"width", rc.right-rc.left},
    {"height", rc.bottom-rc.top},
    {"maximized", wp->showCmd==SW_MAXIMIZE}};
  completer->Success(flutter::EncodableValue(m));
}

// static
LRESULT CALLBACK
WebviewWindow::WndProc(
    HWND window,
    UINT message,
    WPARAM wparam,
    LPARAM lparam
) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT *>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

//    auto that = static_cast<WebviewWindow *>(window_struct->lpCreateParams);
//    that->hwnd_ = window;
  } else if (WebviewWindow *that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
WebviewWindow::MessageHandler(
    HWND hwnd,
    UINT message,
    WPARAM wparam,
    LPARAM lparam
) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_action_bar_) {
    std::optional<LRESULT> result = flutter_action_bar_->HandleTopLevelWindowProc(hwnd, message, wparam, lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_DESTROY: {
      flutter_action_bar_.reset();
      web_view_.reset();

      // might receive multiple WM_DESTROY messages.
      if (!destroyed_) {
        destroyed_ = true;
        auto args = flutter::EncodableMap{
            {flutter::EncodableValue("id"), flutter::EncodableValue(window_id_)}
        };
        method_channel_->InvokeMethod(
            "onWindowClose",
            std::make_unique<flutter::EncodableValue>(args)
        );
        if (on_close_callback_) {
          on_close_callback_();
        }
      }
      return 0;
    }
    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT *>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);
      return 0;
    }
    case WM_SIZE: {
      RECT rect;
      GetClientRect(hwnd, &rect);
      HMONITOR monitor = MonitorFromRect(&rect, MONITOR_DEFAULTTONEAREST);
      UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
      double scale_factor = dpi / 96.0;

      auto title_bar_height = Scale(title_bar_height_, scale_factor);

      if (web_view_ != nullptr) {
        MoveWindow(web_view_->NativeWindow().get(), 0, title_bar_height,
                   rect.right - rect.left, rect.bottom - rect.top - title_bar_height,
                   true);
        web_view_->UpdateBounds();
      }

      if (flutter_action_bar_) {
        // FIXME(BOYAN) remove this trick if flutter provide a properly way to force redraw the flutter view.
        // When user only change the height of window, flutter title bar height will not change, because the title_bar_height
        // is a fixed value. In this situation, the flutter view will not perform draw since no size changed. So we need
        // perform a force redraw to flutter view. Although flutter provide a function FlutterDesktopViewControllerForceRedraw.
        // https://github.com/flutter/engine/pull/24186 But we can not use this because it not provided on wrapper.
        if (last_title_bar_width_ != rect.right - rect.left) {
          // Size and position the flutter window.
          last_title_bar_width_ = rect.right - rect.left;
          MoveWindow(flutter_action_bar_->GetWindow(), 0, 0,
                     last_title_bar_width_, title_bar_height, true);
        } else {
          last_title_bar_width_ = rect.right - rect.left + 1;
          MoveWindow(flutter_action_bar_->GetWindow(), 0, 0,
                     last_title_bar_width_, title_bar_height, true);
        }
      }
      return 0;
    }
    case WM_FONTCHANGE: {
      if (flutter_action_bar_) {
        flutter_action_bar_->ReloadSystemFonts();
      }
      break;
    }
    case WM_ACTIVATE: {
      return 0;
    }
  }

  return DefWindowProc(hwnd, message, wparam, lparam);
}

// static
WebviewWindow *WebviewWindow::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<WebviewWindow *>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

