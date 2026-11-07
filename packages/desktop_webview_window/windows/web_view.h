//
// Created by yangbin on 2021/11/12.
//

#ifndef WEBVIEW_WINDOW_WINDOWS_WEB_VIEW_H_
#define WEBVIEW_WINDOW_WINDOWS_WEB_VIEW_H_

#include <windows.h>

#include <string>

#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include "wil/resource.h"
#include "wil/com.h"

#include "WebView2.h"

namespace webview_window {

class WebView {

 public:

  WebView(std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>> method_channel,
          int64_t web_view_id,
          std::wstring userDataFolder,
          std::function<void(HRESULT)> on_web_view_created_callback,
          std::wstring proxy
  );

  virtual ~WebView();

  [[nodiscard]] const wil::unique_hwnd &NativeWindow() const { return view_window_; }

  void UpdateBounds();

  void Navigate(const std::wstring &url);

  void AddScriptToExecuteOnDocumentCreated(const std::wstring &javaScript);

  void SetApplicationNameForUserAgent(const std::wstring &application_name);

  void GoBack();

  void GoForward();

  void Reload();

  void Stop();

  void GetAllCookies(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> completer);

  void openDevToolsWindow();

  void ExecuteJavaScript(const std::wstring &javaScript,
                         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> completer);

  void PostWebMessageAsString(const std::wstring &webmessage,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> completer);

  void PostWebMessageAsJson(const std::wstring &webmessage,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> completer);

  void setTriggerOnUrlRequestedEvent(const bool value);

  bool shouldBlockUri(std::wstring uri);

  void setProxy(std::wstring uri);

 private:
  wil::unique_hwnd view_window_;

  // Pointer to WebViewController
  wil::com_ptr<ICoreWebView2Controller> webview_controller_;

  // Pointer to WebView
  wil::com_ptr<ICoreWebView2> webview_;

  std::wstring default_user_agent_;

  std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>> method_channel_;

  int64_t web_view_id_;

  std::function<void(HRESULT)> on_web_view_created_callback_;

  std::wstring user_data_folder_;

  bool triggerOnUrlRequestedEvent{false};

  void OnWebviewControllerCreated();

  [[nodiscard]] bool CanGoBack() const;

  [[nodiscard]] bool CanGoForward() const;

};

}

#endif //WEBVIEW_WINDOW_WINDOWS_WEB_VIEW_H_
