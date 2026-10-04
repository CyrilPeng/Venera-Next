#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include "share_plus_windows_plugin.h"

namespace share_plus_windows {
namespace {
void ReportFailure(flutter::MethodResult<flutter::EncodableValue>* result,
                   const char* stage, HRESULT operation,
                   HRESULT cleanup = S_OK) {
  flutter::EncodableMap details{
      {flutter::EncodableValue("stage"), flutter::EncodableValue(stage)},
      {flutter::EncodableValue("hresult"),
       flutter::EncodableValue(static_cast<int64_t>(operation))}};
  if (FAILED(cleanup)) {
    details[flutter::EncodableValue("cleanupHresult")] =
        flutter::EncodableValue(static_cast<int64_t>(cleanup));
  }
  result->Error("share_failed", stage, flutter::EncodableValue(details));
}
}  // namespace

void SharePlusWindowsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), kSharePlusChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  auto plugin = std::make_unique<SharePlusWindowsPlugin>(registrar);
  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });
  registrar->AddPlugin(std::move(plugin));
}

SharePlusWindowsPlugin::SharePlusWindowsPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar) {}

SharePlusWindowsPlugin::~SharePlusWindowsPlugin() = default;

HWND SharePlusWindowsPlugin::GetWindow() {
  auto* view = registrar_->GetView();
  return view ? GetAncestor(view->GetNativeWindow(), GA_ROOT) : nullptr;
}

HRESULT SharePlusWindowsPlugin::InitializeManager(HWND window) {
  if (!window) return E_HANDLE;
  if (subscription_) return S_OK;
  WRL::ComPtr<IDataTransferManagerInterop> interop;
  HRESULT hr = RoGetActivationFactory(
      WRL::Wrappers::HStringReference(
          RuntimeClass_Windows_ApplicationModel_DataTransfer_DataTransferManager)
          .Get(),
      IID_PPV_ARGS(&interop));
  if (FAILED(hr)) return hr;
  if (!interop) return E_UNEXPECTED;
  WRL::ComPtr<DataTransfer::IDataTransferManager> manager;
  hr = interop->GetForWindow(window, IID_PPV_ARGS(&manager));
  if (FAILED(hr)) return hr;
  if (!manager) return E_UNEXPECTED;
  subscription_ = std::make_unique<ShareRequestSubscription>(manager.Get());
  interop_ = std::move(interop);
  return S_OK;
}

void SharePlusWindowsPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name() != "share") {
    result->NotImplemented();
    return;
  }
  try {
    ShareRequest request;
    HRESULT hr = ParseShareRequest(method_call.arguments(), &request);
    if (FAILED(hr)) {
      ReportFailure(result.get(), "Invalid share arguments", hr);
      return;
    }
    std::shared_ptr<const PreparedShare> prepared;
    hr = PrepareShare(std::move(request), &prepared);
    if (FAILED(hr)) {
      ReportFailure(result.get(), "Unable to open shared files", hr);
      return;
    }
    const HWND window = GetWindow();
    hr = InitializeManager(window);
    if (FAILED(hr)) {
      ReportFailure(result.get(), "Unable to initialize Windows sharing", hr);
      return;
    }
    const auto started = subscription_->Start(
        std::move(prepared),
        [this, window] { return interop_->ShowShareUIForWindow(window); });
    if (FAILED(started.operation)) {
      ReportFailure(result.get(), "Unable to start Windows sharing",
                    started.operation, started.cleanup);
      return;
    }
    // The native API acknowledges showing the panel, not receiver completion.
    result->Success(flutter::EncodableValue(kShareResultUnavailable));
  } catch (const std::bad_alloc&) {
    ReportFailure(result.get(), "Unable to allocate Windows share request",
                  E_OUTOFMEMORY);
  } catch (...) {
    ReportFailure(result.get(), "Unable to start Windows sharing",
                  E_UNEXPECTED);
  }
}
}  // namespace share_plus_windows
