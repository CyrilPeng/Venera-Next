//
// Created by yangbin on 2021/10/20.
//

#ifndef _WEBVIEW_WINDOW_WEBVIEW_WINDOW_H_
#define _WEBVIEW_WINDOW_WEBVIEW_WINDOW_H_

#include <Windows.h>

#include <flutter/dart_project.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>

#include <string>
#include <memory>
#include <functional>

#include <wrl.h>
#include "wil/com.h"
#include "WebView2.h"

#include "flutter_view.h"
#include "web_view.h"

class WebviewWindow {

 public:

  using MethodChannelPtr = std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>>;

  WebviewWindow(MethodChannelPtr method_channel,
                int64_t window_id,
                int title_bar_height,
                std::function<void()> on_close_callback);

  virtual ~WebviewWindow();

  using CreateCallback = std::function<void(bool success)>;

  void CreateAndShow(const std::wstring &title, int height, int width,
                     const std::wstring &userDataFolder,
                     int windowPosX, int windowPosY, bool useWindowPositionAndSize,
                     bool openMaximized, CreateCallback callback, const std::wstring &proxy);


  // OS callback called by message pump. Handles the WM_NCCREATE message which
  // is passed when the non-client area is being created and enables automatic
  // non-client DPI scaling so that the non-client area automatically
  // responsponds to changes in DPI. All other messages are handled by
  // MessageHandler.
  static LRESULT CALLBACK WndProc(HWND window,
                                  UINT message,
                                  WPARAM wparam,
                                  LPARAM lparam) noexcept;

  void SetBrightness(int brightness);

  void setVisibility(bool visible);

  void moveWebviewWindow(int left, int top, int width, int height);

  void bringToForeground(bool maximized);

  void getPositionalParameters(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> completer);

  [[nodiscard]] const std::unique_ptr<webview_window::WebView> &GetWebView() const {
    return web_view_;
  }

 private:

  // Retrieves a class instance pointer for |window|
  static WebviewWindow *GetThisFromHandle(HWND window) noexcept;

  MethodChannelPtr method_channel_;

  wil::unique_hwnd hwnd_;

  int64_t window_id_;

  std::function<void()> on_close_callback_;

  std::unique_ptr<webview_window::FlutterView> flutter_action_bar_;

  std::unique_ptr<webview_window::WebView> web_view_;

  int last_title_bar_width_ = 0;

  bool destroyed_ = false;

  int title_bar_height_;

  // Processes and route salient window messages for mouse handling,
  // size change and DPI. Delegates handling of these to member overloads that
  // inheriting classes can handle.
  LRESULT MessageHandler(HWND window,
                         UINT message,
                         WPARAM wparam,
                         LPARAM lparam) noexcept;

  LRESULT HandleNCHitTest(int x, int y) noexcept;

  void SetBorderless() noexcept;

};

#endif //_WEBVIEW_WINDOW_WEBVIEW_WINDOW_H_
