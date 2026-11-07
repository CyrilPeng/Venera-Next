//
// Created by yangbin on 2021/11/15.
//
#include "web_view_window_plugin.h"

#include <windows.h>

#include <map>

namespace {

int64_t next_window_id_ = 0;

bool IsWebViewRuntimeAvailable() {
  LPWSTR version_info;
  GetAvailableCoreWebView2BrowserVersionString(nullptr, &version_info);
  return version_info != nullptr;
}

}  // namespace

// static
void WebviewWindowPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "webview_window",
          &flutter::StandardMethodCodec::GetInstance());
  auto plugin = std::make_unique<WebviewWindowPlugin>(channel);

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

WebviewWindowPlugin::WebviewWindowPlugin(MethodChannelPtr method_channel)
    : method_channel_(std::move(method_channel)), windows_() {}

WebviewWindowPlugin::~WebviewWindowPlugin() = default;

void WebviewWindowPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name() == "create") {
    if (!IsWebViewRuntimeAvailable()) {
      result->Error("0", "WebView runtime not available");
      return;
    }
    auto *arguments =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    auto width =
        arguments->at(flutter::EncodableValue("windowWidth")).LongValue();
    auto height =
        arguments->at(flutter::EncodableValue("windowHeight")).LongValue();
    auto title =
        std::get<std::string>(arguments->at(flutter::EncodableValue("title")));
    auto titleBarHeight =
        arguments->at(flutter::EncodableValue("titleBarHeight")).LongValue();
    auto userDataFolder = std::get<std::string>(
        arguments->at(flutter::EncodableValue("userDataFolderWindows")));
    auto useWindowPositionAndSize = std::get<bool>(
        arguments->at(flutter::EncodableValue("useWindowPositionAndSize")));
    auto openMaximized =
        std::get<bool>(arguments->at(flutter::EncodableValue("openMaximized")));
    auto windowPosX =
        arguments->at(flutter::EncodableValue("windowPosX")).LongValue();
    auto windowPosY =
        arguments->at(flutter::EncodableValue("windowPosY")).LongValue();
    auto proxy = std::get<std::string>(arguments->at(flutter::EncodableValue("proxy")));

    auto window_id = next_window_id_;
    auto window = std::make_unique<WebviewWindow>(
        method_channel_, window_id, int(titleBarHeight),
        [this, window_id]() { windows_.erase(window_id); });
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> result2(
        std::move(result));
    window->CreateAndShow(
        utf8_to_wide(title), int(height), int(width),
        utf8_to_wide(userDataFolder), int(windowPosX), int(windowPosY),
        useWindowPositionAndSize, openMaximized,
        [this, window_id, result(result2)](bool succeed) mutable {
          if (!succeed) {
            result->Error("0", "failed to show window");
            windows_.erase(window_id);
            return;
          }
          result->Success(flutter::EncodableValue(window_id));
        }, utf8_to_wide(proxy));
    next_window_id_++;
    windows_[window_id] = std::move(window);
  } else if (method_call.method_name() == "launch") {
    auto *arguments =
        std::get_if<flutter::EncodableMap>(method_call.arguments());

    auto window_id =
        arguments->at(flutter::EncodableValue("viewId")).LongValue();
    auto url =
        std::get<std::string>(arguments->at(flutter::EncodableValue("url")));
    auto triggerOnUrlRequestEvent = std::get<bool>(
        arguments->at(flutter::EncodableValue("triggerOnUrlRequestEvent")));

    if (!windows_.count(window_id)) {
      result->Error("0", "can not find webview window for id");
      return;
    }
    if (!windows_[window_id]->GetWebView()) {
      result->Error("0", "webview window not ready");
      return;
    }
    windows_[window_id]->GetWebView()->setTriggerOnUrlRequestedEvent(
        triggerOnUrlRequestEvent);
    windows_[window_id]->GetWebView()->Navigate(utf8_to_wide(url));
    result->Success();
  } else if (method_call.method_name() ==
             "addScriptToExecuteOnDocumentCreated") {
    auto *arguments =
        std::get_if<flutter::EncodableMap>(method_call.arguments());

    auto window_id =
        arguments->at(flutter::EncodableValue("viewId")).LongValue();
    auto javaScript = std::get<std::string>(
        arguments->at(flutter::EncodableValue("javaScript")));

    if (!windows_.count(window_id)) {
      result->Error("0", "can not find webview window for id");
      return;
    }
    if (!windows_[window_id]->GetWebView()) {
      result->Error("0", "webview window not ready");
      return;
    }
    windows_[window_id]->GetWebView()->AddScriptToExecuteOnDocumentCreated(
        utf8_to_wide(javaScript));
    result->Success();
  } else if (method_call.method_name() == "clearAll") {
    std::map<int64_t, std::unique_ptr<WebviewWindow>> local;
    std::swap(local, windows_);
    local.clear();
    result->Success();
  } else if (method_call.method_name() == "setApplicationNameForUserAgent") {
    auto *arguments =
        std::get_if<flutter::EncodableMap>(method_call.arguments());

    auto window_id =
        arguments->at(flutter::EncodableValue("viewId")).LongValue();
    auto applicationName = std::get<std::string>(
        arguments->at(flutter::EncodableValue("applicationName")));

    if (!windows_.count(window_id)) {
      result->Error("0", "can not find webview window for id");
      return;
    }
    if (!windows_[window_id]->GetWebView()) {
      result->Error("0", "webview window not ready");
      return;
    }
    windows_[window_id]->GetWebView()->SetApplicationNameForUserAgent(
        utf8_to_wide(applicationName));
    result->Success();
  } else if (method_call.method_name() == "isWebviewAvailable") {
    result->Success(flutter::EncodableValue(IsWebViewRuntimeAvailable()));
  } else if (method_call.method_name() == "back") {
    auto *arguments =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    auto window_id =
        arguments->at(flutter::EncodableValue("viewId")).LongValue();
    if (!windows_.count(window_id)) {
      result->Error("0", "can not find webview window for id");
      return;
    }
    if (!windows_[window_id]->GetWebView()) {
      result->Error("0", "webview window not ready");
      return;
    }
    windows_[window_id]->GetWebView()->GoBack();
    result->Success();
  } else if (method_call.method_name() == "forward") {
    auto *arguments =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    auto window_id =
        arguments->at(flutter::EncodableValue("viewId")).LongValue();
    if (!windows_.count(window_id)) {
      result->Error("0", "can not find webview window for id");
      return;
    }
    if (!windows_[window_id]->GetWebView()) {
      result->Error("0", "webview window not ready");
      return;
    }
    windows_[window_id]->GetWebView()->GoForward();
    result->Success();
  } else if (method_call.method_name() == "setWebviewWindowVisibility") {
    auto *arguments =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    auto window_id =
        arguments->at(flutter::EncodableValue("viewId")).LongValue();
    auto visible =
        std::get<bool>(arguments->at(flutter::EncodableValue("visible")));
    if (!windows_.count(window_id)) {
      result->Error("0", "can not find webview window for id");
      return;
    }
    if (!windows_[window_id]->GetWebView()) {
      result->Error("0", "webview window not ready");
      return;
    }
    windows_[window_id]->setVisibility(visible);
    result->Success();
  } else if (method_call.method_name() == "moveWebviewWindow") {
    auto *arguments =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    auto window_id =
        arguments->at(flutter::EncodableValue("viewId")).LongValue();
    auto left = std::get<int>(arguments->at(flutter::EncodableValue("left")));
    auto top = std::get<int>(arguments->at(flutter::EncodableValue("top")));
    auto width = std::get<int>(arguments->at(flutter::EncodableValue("width")));
    auto height =
        std::get<int>(arguments->at(flutter::EncodableValue("height")));
    if (!windows_.count(window_id)) {
      result->Error("0", "can not find webview window for id");
      return;
    }
    if (!windows_[window_id]->GetWebView()) {
      result->Error("0", "webview window not ready");
      return;
    }
    windows_[window_id]->moveWebviewWindow(left, top, width, height);
    result->Success();
  } else if (method_call.method_name() == "bringToForeground") {
    auto *arguments =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    auto window_id =
        arguments->at(flutter::EncodableValue("viewId")).LongValue();
    auto maximized =
        std::get<bool>(arguments->at(flutter::EncodableValue("maximized")));
    if (!windows_.count(window_id)) {
      result->Error("0", "can not find webview window for id");
      return;
    }
    if (!windows_[window_id]->GetWebView()) {
      result->Error("0", "webview window not ready");
      return;
    }
    windows_[window_id]->bringToForeground(maximized);
    result->Success();
  } else if (method_call.method_name() == "getPositionalParameters") {
    auto *arguments =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    auto window_id =
        arguments->at(flutter::EncodableValue("viewId")).LongValue();
    if (!windows_.count(window_id)) {
      result->Error("0", "can not find webview window for id");
      return;
    }
    if (!windows_[window_id]->GetWebView()) {
      result->Error("0", "webview window not ready");
      return;
    }
    windows_[window_id]->getPositionalParameters(std::move(result));
  } else if (method_call.method_name() == "reload") {
    auto *arguments =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    auto window_id =
        arguments->at(flutter::EncodableValue("viewId")).LongValue();
    if (!windows_.count(window_id)) {
      result->Error("0", "can not find webview window for id");
      return;
    }
    if (!windows_[window_id]->GetWebView()) {
      result->Error("0", "webview window not ready");
      return;
    }
    windows_[window_id]->GetWebView()->Reload();
    result->Success();
  } else if (method_call.method_name() == "stop") {
    auto *arguments =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    auto window_id =
        arguments->at(flutter::EncodableValue("viewId")).LongValue();
    if (!windows_.count(window_id)) {
      result->Error("0", "can not find webview window for id");
      return;
    }
    if (!windows_[window_id]->GetWebView()) {
      result->Error("0", "webview window not ready");
      return;
    }
    windows_[window_id]->GetWebView()->Stop();
    result->Success();
  } else if (method_call.method_name() == "getAllCookies") {
    auto *arguments =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    auto window_id =
        arguments->at(flutter::EncodableValue("viewId")).LongValue();
    if (!windows_.count(window_id)) {
      result->Error("0", "can not find webview window for id");
      return;
    }
    if (!windows_[window_id]->GetWebView()) {
      result->Error("0", "webview window not ready");
      return;
    }
    windows_[window_id]->GetWebView()->GetAllCookies(std::move(result));
  } else if (method_call.method_name() == "close") {
    auto *arguments =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    auto window_id =
        arguments->at(flutter::EncodableValue("viewId")).LongValue();
    if (!windows_.count(window_id)) {
      result->Error("0", "can not find webview window for id");
      return;
    }
    windows_.erase(window_id);
    result->Success();
  } else if (method_call.method_name() == "evaluateJavaScript") {
    auto *arguments =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    auto window_id =
        arguments->at(flutter::EncodableValue("viewId")).LongValue();
    auto javascript = std::get<std::string>(
        arguments->at(flutter::EncodableValue("javaScriptString")));
    if (!windows_.count(window_id)) {
      result->Error("0", "can not find webview window for id");
      return;
    }
    if (!windows_[window_id]->GetWebView()) {
      result->Error("0", "webview window not ready");
      return;
    }
    windows_[window_id]->GetWebView()->ExecuteJavaScript(
        utf8_to_wide(javascript), std::move(result));
  } else if (method_call.method_name() == "postWebMessageAsString") {
    auto *arguments =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    auto window_id =
        arguments->at(flutter::EncodableValue("viewId")).LongValue();
    auto webmessage = std::get<std::string>(
        arguments->at(flutter::EncodableValue("webMessage")));
    if (!windows_.count(window_id)) {
      result->Error("0", "can not find webview window for id");
      return;
    }
    if (!windows_[window_id]->GetWebView()) {
      result->Error("0", "webview window not ready");
      return;
    }
    windows_[window_id]->GetWebView()->PostWebMessageAsString(
        utf8_to_wide(webmessage), std::move(result));
  } else if (method_call.method_name() == "postWebMessageAsJson") {
    auto *arguments =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    auto window_id =
        arguments->at(flutter::EncodableValue("viewId")).LongValue();
    auto webmessage = std::get<std::string>(
        arguments->at(flutter::EncodableValue("webMessage")));
    if (!windows_.count(window_id)) {
      result->Error("0", "can not find webview window for id");
      return;
    }
    if (!windows_[window_id]->GetWebView()) {
      result->Error("0", "webview window not ready");
      return;
    }
    windows_[window_id]->GetWebView()->PostWebMessageAsJson(
        utf8_to_wide(webmessage), std::move(result));
  } else if (method_call.method_name() == "openDevToolsWindow") {
    auto *arguments =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    auto window_id =
        arguments->at(flutter::EncodableValue("viewId")).LongValue();
    if (!windows_.count(window_id)) {
      result->Error("0", "can not find webview window for id");
      return;
    }
    if (!windows_[window_id]->GetWebView()) {
      result->Error("0", "webview window not ready");
      return;
    }
    windows_[window_id]->GetWebView()->openDevToolsWindow();
    result->Success();
  } else {
    result->NotImplemented();
  }
}
