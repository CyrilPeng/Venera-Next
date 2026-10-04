#include "share_request.h"

#include <roapi.h>
#include <wrl/wrappers/corewrappers.h>

#include <limits>
#include <new>
#include <utility>

#include "vector.h"

namespace share_plus_windows {
namespace {
using WRL::Wrappers::HStringReference;

HRESULT Utf16(const std::string& value, std::wstring* converted) {
  if (value.empty()) {
    converted->clear();
    return S_OK;
  }
  if (value.size() > static_cast<size_t>((std::numeric_limits<int>::max)())) {
    return E_INVALIDARG;
  }
  // HSTRING can contain NUL, but file paths and share fields must not silently
  // truncate at an embedded NUL when passed to other Windows APIs.
  if (value.find('\0') != std::string::npos) return E_INVALIDARG;
  const int length = static_cast<int>(value.size());
  const int required = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                           value.data(), length, nullptr, 0);
  if (required == 0) return HRESULT_FROM_WIN32(GetLastError());
  converted->resize(required);
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), length,
                          converted->data(), required) == 0) {
    return HRESULT_FROM_WIN32(GetLastError());
  }
  return S_OK;
}

HRESULT ReadString(const flutter::EncodableMap& args, const char* name,
                   std::wstring* value) {
  const auto found = args.find(flutter::EncodableValue(name));
  if (found == args.end() ||
      std::holds_alternative<std::monostate>(found->second)) {
    value->clear();
    return S_OK;
  }
  const auto* text = std::get_if<std::string>(&found->second);
  return text ? Utf16(*text, value) : E_INVALIDARG;
}

HRESULT PopulatePackage(const PreparedShare& share,
                        DataTransfer::IDataRequest* request) {
  WRL::ComPtr<DataTransfer::IDataPackage> data;
  HRESULT hr = request->get_Data(&data);
  if (FAILED(hr)) return hr;
  if (!data) return E_UNEXPECTED;
  WRL::ComPtr<DataTransfer::IDataPackagePropertySet> properties;
  hr = data->get_Properties(&properties);
  if (FAILED(hr)) return hr;
  if (!properties) return E_UNEXPECTED;
  hr = properties->put_Title(
      HStringReference(share.request.title.c_str()).Get());
  if (FAILED(hr)) return hr;
  if (!share.request.text.empty()) {
    const HStringReference text(share.request.text.c_str());
    hr = properties->put_Description(text.Get());
    if (FAILED(hr)) return hr;
    hr = data->SetText(text.Get());
    if (FAILED(hr)) return hr;
  }
  if (!share.files.empty()) {
    // Vector<T*>::Wrap stores a ComPtr (AddRef). Heap allocation is required:
    // DataPackage may retain the iterable or its iterator after this returns.
    WRL::ComPtr<StorageItems> items;
    hr = CreateStorageItems(share.files, &items);
    if (FAILED(hr)) return hr;
    hr = data->SetStorageItemsReadOnly(items.Get());
    if (FAILED(hr)) return hr;
  }
  return S_OK;
}

void ReportCleanupFailure(HRESULT hr) noexcept {
  if (FAILED(hr)) {
    wchar_t text[96];
    swprintf_s(text, L"share_plus: DataRequested cleanup failed (0x%08lX)\n",
               static_cast<unsigned long>(hr));
    OutputDebugStringW(text);
  }
}

HRESULT ReportDataFailure(DataTransfer::IDataRequest* request,
                          HRESULT error) noexcept {
  if (request) {
    wchar_t text[96];
    swprintf_s(text, L"Unable to provide shared data (0x%08lX).",
               static_cast<unsigned long>(error));
    ReportCleanupFailure(
        request->FailWithDisplayText(HStringReference(text).Get()));
  }
  return error;
}

HRESULT RejectShare(DataTransfer::IDataRequestedEventArgs* args,
                     HRESULT error) noexcept {
  WRL::ComPtr<DataTransfer::IDataRequest> request;
  if (args && SUCCEEDED(args->get_Request(&request))) {
    ReportDataFailure(request.Get(), error);
  }
  return error;
}

class ExclusiveLock {
 public:
  explicit ExclusiveLock(SRWLOCK& lock) noexcept : lock_(lock) {
    AcquireSRWLockExclusive(&lock_);
  }
  ~ExclusiveLock() { ReleaseSRWLockExclusive(&lock_); }
  ExclusiveLock(const ExclusiveLock&) = delete;
  ExclusiveLock& operator=(const ExclusiveLock&) = delete;

 private:
  SRWLOCK& lock_;
};

struct DeferredShareRequest {
  WRL::ComPtr<DataTransfer::IDataRequestedEventArgs> args;
  WRL::ComPtr<DataTransfer::IDataRequestDeferral> deferral;
  DeferredShareRequest() = default;
  DeferredShareRequest(DeferredShareRequest&&) noexcept = default;
  DeferredShareRequest& operator=(DeferredShareRequest&&) noexcept = default;
  DeferredShareRequest(const DeferredShareRequest&) = delete;
  DeferredShareRequest& operator=(const DeferredShareRequest&) = delete;
  ~DeferredShareRequest() {
    if (deferral) ReportCleanupFailure(deferral->Complete());
  }
};

// A newly installed callback can run synchronously inside ShowShareUIForWindow.
// Defer its data until that call decides whether the new or previous immutable
// payload owns the panel. Settled callbacks never depend on plugin lifetime.
class ShareCallbackState {
 public:
  HRESULT Invoke(DataTransfer::IDataRequestedEventArgs* args) noexcept {
    if (!args) return E_POINTER;
    DeferredShareRequest deferred;
    try {
      std::shared_ptr<const PreparedShare> selected;
      bool settled;
      {
        ExclusiveLock lock(lock_);
        settled = settled_;
        selected = selected_;
      }
      if (settled) return Deliver(selected, args);

      deferred.args = args;
      WRL::ComPtr<DataTransfer::IDataRequest> request;
      HRESULT hr = args->get_Request(&request);
      if (FAILED(hr)) return hr;
      if (!request) return E_UNEXPECTED;
      hr = request->GetDeferral(&deferred.deferral);
      if (FAILED(hr)) return ReportDataFailure(request.Get(), hr);
      if (!deferred.deferral) {
        return ReportDataFailure(request.Get(), E_UNEXPECTED);
      }
      {
        ExclusiveLock lock(lock_);
        if (!settled_) {
          pending_.push_back(std::move(deferred));
          return S_OK;
        }
        selected = selected_;
      }
      // Show may settle while GetDeferral is running. The local owner then
      // supplies the decided payload and completes its own deferral on return.
      return Deliver(selected, args);
    } catch (const std::bad_alloc&) {
      return RejectShare(args, E_OUTOFMEMORY);
    } catch (...) {
      return RejectShare(args, E_UNEXPECTED);
    }
  }

  void Settle(std::shared_ptr<const PreparedShare> selected) noexcept {
    std::vector<DeferredShareRequest> pending;
    {
      ExclusiveLock lock(lock_);
      selected_ = selected;
      settled_ = true;
      pending.swap(pending_);
    }
    for (const auto& request : pending) {
      // The original callback already returned after taking a deferral, so
      // native failure reporting owns these later errors, not the Show ack.
      ReportCleanupFailure(Deliver(selected, request.args.Get()));
    }
    // Each owned deferral completes exactly once, including failed delivery.
  }

 private:
  static HRESULT Deliver(const std::shared_ptr<const PreparedShare>& selected,
                          DataTransfer::IDataRequestedEventArgs* args) noexcept {
    return selected ? PopulateShare(*selected, args) : RejectShare(args, E_ABORT);
  }
  SRWLOCK lock_ = SRWLOCK_INIT;
  bool settled_ = false;
  std::shared_ptr<const PreparedShare> selected_;
  std::vector<DeferredShareRequest> pending_;
};
}  // namespace

HRESULT CreateStorageItems(
    const std::vector<WRL::ComPtr<WindowsStorage::IStorageItem>>& files,
    StorageItems** items) noexcept {
  if (!items) return E_POINTER;
  *items = nullptr;
  try {
    auto collection = WRL::Make<Vector<WindowsStorage::IStorageItem*>>();
    if (!collection) return E_OUTOFMEMORY;
    for (const auto& item : files) {
      if (!item) return E_INVALIDARG;
      const HRESULT hr = collection->Append(item.Get());
      if (FAILED(hr)) return hr;
    }
    return collection.CopyTo(items);
  } catch (const std::bad_alloc&) {
    return E_OUTOFMEMORY;
  } catch (...) {
    return E_UNEXPECTED;
  }
}

HRESULT ParseShareRequest(const flutter::EncodableValue* arguments,
                          ShareRequest* request) noexcept {
  if (!arguments || !request) return E_POINTER;
  try {
    const auto* args = std::get_if<flutter::EncodableMap>(arguments);
    if (!args) return E_INVALIDARG;
    ShareRequest parsed;
    std::wstring subject;
    std::wstring uri;
    HRESULT hr = ReadString(*args, "title", &parsed.title);
    if (FAILED(hr)) return hr;
    hr = ReadString(*args, "subject", &subject);
    if (FAILED(hr)) return hr;
    hr = ReadString(*args, "text", &parsed.text);
    if (FAILED(hr)) return hr;
    hr = ReadString(*args, "uri", &uri);
    if (FAILED(hr)) return hr;
    if (!uri.empty()) parsed.text = std::move(uri);
    const auto paths = args->find(flutter::EncodableValue("paths"));
    if (paths != args->end()) {
      const auto* values = std::get_if<flutter::EncodableList>(&paths->second);
      if (!values) return E_INVALIDARG;
      for (const auto& value : *values) {
        const auto* path = std::get_if<std::string>(&value);
        if (!path || path->empty()) return E_INVALIDARG;
        std::wstring converted;
        hr = Utf16(*path, &converted);
        if (FAILED(hr)) return hr;
        parsed.paths.push_back(std::move(converted));
      }
    }
    if (parsed.text.empty() && parsed.paths.empty()) return E_INVALIDARG;
    if (parsed.title.empty()) parsed.title = std::move(subject);
    if (parsed.title.empty()) parsed.title = parsed.text;
    if (parsed.title.empty()) {
      const auto& path = parsed.paths.front();
      const auto separator = path.find_last_of(L"/\\");
      parsed.title =
          path.substr(separator == std::wstring::npos ? 0 : separator + 1);
    }
    if (parsed.title.empty()) parsed.title = L"Share";
    *request = std::move(parsed);
    return S_OK;
  } catch (const std::bad_alloc&) {
    return E_OUTOFMEMORY;
  } catch (...) {
    return E_UNEXPECTED;
  }
}

HRESULT ResolveStorageItem(const std::wstring& path,
                           WindowsStorage::IStorageItem** item) noexcept {
  if (!item) return E_POINTER;
  *item = nullptr;
  WRL::ComPtr<WindowsStorage::IStorageFileStatics> factory;
  HRESULT hr = RoGetActivationFactory(
      HStringReference(RuntimeClass_Windows_Storage_StorageFile).Get(),
      IID_PPV_ARGS(&factory));
  if (FAILED(hr)) return hr;
  if (!factory) return E_UNEXPECTED;
  WRL::ComPtr<WindowsFoundation::IAsyncOperation<WindowsStorage::StorageFile*>>
      operation;
  hr = factory->GetFileFromPathAsync(HStringReference(path.c_str()).Get(),
                                     &operation);
  if (FAILED(hr)) return hr;
  if (!operation) return E_UNEXPECTED;
  WRL::ComPtr<IAsyncInfo> info;
  hr = operation.As(&info);
  if (FAILED(hr)) return hr;
  AsyncStatus status = AsyncStatus::Started;
  while (true) {
    hr = info->get_Status(&status);
    if (FAILED(hr)) return hr;
    if (status != AsyncStatus::Started) break;
    SleepEx(1, TRUE);
  }
  if (status != AsyncStatus::Completed) {
    HRESULT operation_error = E_FAIL;
    hr = info->get_ErrorCode(&operation_error);
    if (FAILED(hr)) return hr;
    if (FAILED(operation_error)) return operation_error;
    return status == AsyncStatus::Canceled ? HRESULT_FROM_WIN32(ERROR_CANCELLED)
                                           : E_FAIL;
  }
  WRL::ComPtr<WindowsStorage::IStorageFile> file;
  hr = operation->GetResults(&file);
  if (FAILED(hr)) return hr;
  if (!file) return E_UNEXPECTED;
  // IStorageFile and IStorageItem are separate interfaces. QueryInterface owns
  // the returned reference; reinterpret_cast neither adjusts nor retains it.
  return file->QueryInterface(IID_PPV_ARGS(item));
}

HRESULT PrepareShare(ShareRequest request,
                     std::shared_ptr<const PreparedShare>* prepared,
                     const StorageItemResolver& resolve) noexcept {
  if (!prepared) return E_POINTER;
  prepared->reset();
  try {
    PreparedShare result;
    result.request = std::move(request);
    for (const auto& path : result.request.paths) {
      WRL::ComPtr<WindowsStorage::IStorageItem> item;
      const HRESULT hr = resolve(path, &item);
      if (FAILED(hr)) return hr;
      if (!item) return E_UNEXPECTED;
      result.files.push_back(std::move(item));
    }
    *prepared = std::make_shared<const PreparedShare>(std::move(result));
    return S_OK;
  } catch (const std::bad_alloc&) {
    return E_OUTOFMEMORY;
  } catch (...) {
    return E_UNEXPECTED;
  }
}

HRESULT PopulateShare(const PreparedShare& share,
                      DataTransfer::IDataRequestedEventArgs* args) noexcept {
  if (!args) return E_POINTER;
  WRL::ComPtr<DataTransfer::IDataRequest> request;
  HRESULT hr = args->get_Request(&request);
  if (FAILED(hr)) return hr;
  if (!request) return E_UNEXPECTED;
  try {
    hr = PopulatePackage(share, request.Get());
  } catch (const std::bad_alloc&) {
    hr = E_OUTOFMEMORY;
  } catch (...) {
    hr = E_UNEXPECTED;
  }
  if (FAILED(hr)) {
    ReportDataFailure(request.Get(), hr);
  }
  return hr;
}

ShareRequestSubscription::ShareRequestSubscription(
    DataTransfer::IDataTransferManager* manager)
    : manager_(manager) {}

ShareRequestSubscription::~ShareRequestSubscription() {
  ReportCleanupFailure(Reset());
}

HRESULT ShareRequestSubscription::Reset() noexcept {
  if (!subscribed_) return S_OK;
  const HRESULT hr = manager_->remove_DataRequested(token_);
  if (SUCCEEDED(hr)) {
    subscribed_ = false;
    callback_.Reset();
    share_.reset();
  }
  // On failure retain the token so replacement cannot add another handler,
  // and a subsequent Reset/destruction can retry the same cleanup.
  return hr;
}

ShareStartResult ShareRequestSubscription::Start(
    std::shared_ptr<const PreparedShare> share,
    const std::function<HRESULT()>& show) noexcept {
  if (!manager_ || !share || !show) return {E_INVALIDARG};
  using Handler = WindowsFoundation::ITypedEventHandler<
      DataTransfer::DataTransferManager*, DataTransfer::DataRequestedEventArgs*>;
  const auto previous_callback = callback_;
  const auto previous_share = share_;
  WRL::ComPtr<Handler> callback;
  std::shared_ptr<ShareCallbackState> state;
  // Allocate before removing the accepted request's subscription. No callback
  // reads mutable plugin state, even while Show has not yet chosen its payload.
  try {
    state = std::make_shared<ShareCallbackState>();
    callback = WRL::Callback<Handler>(
        [state](
            auto*, DataTransfer::IDataRequestedEventArgs* args) {
          return state->Invoke(args);
        });
    if (!callback) return {E_OUTOFMEMORY};
  } catch (const std::bad_alloc&) {
    return {E_OUTOFMEMORY};
  } catch (...) {
    return {E_UNEXPECTED};
  }
  HRESULT hr = Reset();
  if (FAILED(hr)) return {hr};
  hr = manager_->add_DataRequested(callback.Get(), &token_);
  if (FAILED(hr)) {
    // The old panel may still be waiting for its first DataRequested. Restore
    // its callback if registering the replacement failed after removal.
    HRESULT restored = S_OK;
    if (previous_callback && previous_share) {
      restored = manager_->add_DataRequested(previous_callback.Get(), &token_);
      if (SUCCEEDED(restored)) {
        subscribed_ = true;
        callback_ = previous_callback;
        share_ = previous_share;
      }
    }
    return {hr, restored};
  }
  subscribed_ = true;
  callback_ = callback;
  share_ = share;
  try {
    hr = show();
  } catch (const std::bad_alloc&) {
    hr = E_OUTOFMEMORY;
  } catch (...) {
    hr = E_UNEXPECTED;
  }
  if (FAILED(hr)) {
    share_ = previous_share;
    state->Settle(previous_share);
    // Keep this single registration serving the accepted payload. Removing
    // and re-adding it would introduce another failure window for the old panel.
    if (previous_share) return {hr};
    return {hr, Reset()};
  }
  state->Settle(share);
  // DataRequested provides the data; neither it nor TargetApplicationChosen
  // means a receiver has finished consuming the original file. Keep sources.
  return {};
}
}  // namespace share_plus_windows
