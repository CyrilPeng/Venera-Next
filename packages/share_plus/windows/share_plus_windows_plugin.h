#ifndef FLUTTER_PLUGIN_SHARE_PLUS_WINDOWS_PLUGIN_H_
#define FLUTTER_PLUGIN_SHARE_PLUS_WINDOWS_PLUGIN_H_

#include <ShObjIdl.h>
#include <Windows.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <roapi.h>
#include <wrl/wrappers/corewrappers.h>

#include "share_request.h"

#pragma comment(lib, "runtimeobject.lib")

namespace share_plus_windows {
class SharePlusWindowsPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);
  explicit SharePlusWindowsPlugin(flutter::PluginRegistrarWindows* registrar);
  ~SharePlusWindowsPlugin() override;
  SharePlusWindowsPlugin(const SharePlusWindowsPlugin&) = delete;
  SharePlusWindowsPlugin& operator=(const SharePlusWindowsPlugin&) = delete;

 private:
  static constexpr auto kSharePlusChannelName =
      "dev.fluttercommunity.plus/share";
  static constexpr auto kShareResultUnavailable =
      "dev.fluttercommunity.plus/share/unavailable";
  HWND GetWindow();
  HRESULT InitializeManager(HWND window);
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  flutter::PluginRegistrarWindows* registrar_;
  WRL::ComPtr<IDataTransferManagerInterop> interop_;
  // Destruction revokes the event before releasing the manager/interop.
  std::unique_ptr<ShareRequestSubscription> subscription_;
};
}  // namespace share_plus_windows
#endif
