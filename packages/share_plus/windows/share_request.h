#ifndef SHARE_PLUS_WINDOWS_SHARE_REQUEST_H_
#define SHARE_PLUS_WINDOWS_SHARE_REQUEST_H_

#include <Windows.h>
#include <flutter/encodable_value.h>
#include <windows.applicationmodel.datatransfer.h>
#include <windows.storage.h>
#include <wrl.h>
#include <wrl/client.h>

#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace share_plus_windows {
namespace DataTransfer = ABI::Windows::ApplicationModel::DataTransfer;
namespace WindowsFoundation = ABI::Windows::Foundation;
namespace WindowsStorage = ABI::Windows::Storage;
namespace WRL = Microsoft::WRL;

struct ShareRequest {
  std::wstring title;
  std::wstring text;
  std::vector<std::wstring> paths;
};

// Parsing starts with fresh fields; no request inherits omitted arguments.
HRESULT ParseShareRequest(const flutter::EncodableValue* arguments,
                          ShareRequest* request) noexcept;

using StorageItemResolver =
    std::function<HRESULT(const std::wstring&, WindowsStorage::IStorageItem**)>;
HRESULT ResolveStorageItem(const std::wstring& path,
                           WindowsStorage::IStorageItem** item) noexcept;

struct PreparedShare {
  ShareRequest request;
  std::vector<WRL::ComPtr<WindowsStorage::IStorageItem>> files;
};

using StorageItems =
    WindowsFoundation::Collections::IIterable<WindowsStorage::IStorageItem*>;
HRESULT CreateStorageItems(
    const std::vector<WRL::ComPtr<WindowsStorage::IStorageItem>>& files,
    StorageItems** items) noexcept;

// The returned snapshot and its COM references belong to this request only.
// StorageFile is a reference to the original path, not a copy of its content.
HRESULT PrepareShare(
    ShareRequest request, std::shared_ptr<const PreparedShare>* prepared,
    const StorageItemResolver& resolve = ResolveStorageItem) noexcept;
HRESULT PopulateShare(const PreparedShare& share,
                      DataTransfer::IDataRequestedEventArgs* args) noexcept;

struct ShareStartResult {
  HRESULT operation = S_OK;
  HRESULT cleanup = S_OK;
};

// Owns at most one DataRequested subscription. Callbacks own immutable snapshots
// and never reference this object or the plugin. A failed replacement serves the
// last accepted snapshot, including when its panel has not requested data yet.
class ShareRequestSubscription {
 public:
  explicit ShareRequestSubscription(
      DataTransfer::IDataTransferManager* manager);
  ~ShareRequestSubscription();
  ShareRequestSubscription(const ShareRequestSubscription&) = delete;
  ShareRequestSubscription& operator=(const ShareRequestSubscription&) = delete;

  ShareStartResult Start(std::shared_ptr<const PreparedShare> share,
                         const std::function<HRESULT()>& show) noexcept;
  HRESULT Reset() noexcept;

 private:
  WRL::ComPtr<DataTransfer::IDataTransferManager> manager_;
  WRL::ComPtr<WindowsFoundation::ITypedEventHandler<
      DataTransfer::DataTransferManager*, DataTransfer::DataRequestedEventArgs*>>
      callback_;
  std::shared_ptr<const PreparedShare> share_;
  EventRegistrationToken token_{};
  bool subscribed_ = false;
};

}  // namespace share_plus_windows
#endif
