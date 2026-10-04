#include "share_request.h"

#include <roapi.h>
#include <wrl/wrappers/corewrappers.h>

#include <cstdio>
#include <future>
#include <iostream>
#include <map>
#include <stdexcept>
#include <thread>

using namespace share_plus_windows;
using WRL::Wrappers::HString;
using WRL::Wrappers::HStringReference;
using Handler = WindowsFoundation::ITypedEventHandler<
    DataTransfer::DataTransferManager*, DataTransfer::DataRequestedEventArgs*>;
using TargetHandler = WindowsFoundation::ITypedEventHandler<
    DataTransfer::DataTransferManager*,
    DataTransfer::TargetApplicationChosenEventArgs*>;

#define CHECK(condition)                                    \
  do {                                                      \
    if (!(condition)) throw std::runtime_error(#condition); \
  } while (0)
#define OK(expression)                                      \
  do {                                                      \
    const HRESULT hr_ = (expression);                       \
    if (FAILED(hr_)) {                                      \
      std::cerr << #expression << " HRESULT=0x" << std::hex \
                << static_cast<unsigned long>(hr_) << '\n'; \
      throw std::runtime_error(#expression);                \
    }                                                       \
  } while (0)

class Manager final
    : public WRL::RuntimeClass<DataTransfer::IDataTransferManager> {
  InspectableClass(L"Tests.Manager", BaseTrust);

 public:
  HRESULT add_result = S_OK;
  HRESULT next_add_result = S_OK;
  HRESULT remove_result = S_OK;
  int adds = 0;
  int removes = 0;
  size_t peak_handlers = 0;
  int64_t next = 1;
  std::map<int64_t, WRL::ComPtr<Handler>> handlers;
  HRESULT STDMETHODCALLTYPE
  add_DataRequested(Handler* handler, EventRegistrationToken* token) override {
    ++adds;
    const HRESULT next_result = next_add_result;
    next_add_result = S_OK;
    if (FAILED(next_result)) return next_result;
    if (FAILED(add_result)) return add_result;
    token->value = next++;
    handlers[token->value] = handler;
    if (handlers.size() > peak_handlers) peak_handlers = handlers.size();
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE
  remove_DataRequested(EventRegistrationToken token) override {
    ++removes;
    if (FAILED(remove_result)) return remove_result;
    return handlers.erase(token.value) == 1 ? S_OK : E_INVALIDARG;
  }
  HRESULT STDMETHODCALLTYPE add_TargetApplicationChosen(
      TargetHandler*, EventRegistrationToken*) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE
  remove_TargetApplicationChosen(EventRegistrationToken) override {
    return E_NOTIMPL;
  }
};

class Deferral final : public WRL::RuntimeClass<DataTransfer::IDataRequestDeferral> {
  InspectableClass(L"Tests.Deferral", BaseTrust);

 public:
  int completions = 0;
  HRESULT result = S_OK;
  HRESULT STDMETHODCALLTYPE Complete() override {
    ++completions;
    return result;
  }
};

class Request final : public WRL::RuntimeClass<DataTransfer::IDataRequest> {
  InspectableClass(L"Tests.Request", BaseTrust);

 public:
  Request() {
    WRL::ComPtr<IInspectable> instance;
    OK(RoActivateInstance(
        HStringReference(
            RuntimeClass_Windows_ApplicationModel_DataTransfer_DataPackage)
            .Get(),
        &instance));
    OK(instance.As(&data));
  }
  HRESULT data_result = S_OK;
  HRESULT report_result = S_OK;
  std::wstring failure;
  WRL::ComPtr<Deferral> deferral = WRL::Make<Deferral>();
  std::function<void()> before_deferral;
  WRL::ComPtr<DataTransfer::IDataPackage> data;
  HRESULT STDMETHODCALLTYPE
  get_Data(DataTransfer::IDataPackage** value) override {
    if (FAILED(data_result)) return data_result;
    return data.CopyTo(value);
  }
  HRESULT STDMETHODCALLTYPE
  put_Data(DataTransfer::IDataPackage* value) override {
    data = value;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE
  get_Deadline(WindowsFoundation::DateTime*) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE FailWithDisplayText(HSTRING value) override {
    failure = WindowsGetStringRawBuffer(value, nullptr);
    return report_result;
  }
  HRESULT STDMETHODCALLTYPE
  GetDeferral(DataTransfer::IDataRequestDeferral** value) override {
    if (before_deferral) before_deferral();
    return deferral.CopyTo(value);
  }
};

class Args final
    : public WRL::RuntimeClass<DataTransfer::IDataRequestedEventArgs> {
  InspectableClass(L"Tests.Args", BaseTrust);

 public:
  Args() : request(WRL::Make<Request>()) {}
  WRL::ComPtr<Request> request;
  HRESULT result = S_OK;
  HRESULT STDMETHODCALLTYPE
  get_Request(DataTransfer::IDataRequest** value) override {
    return FAILED(result) ? result : request.CopyTo(value);
  }
};

class Item final : public WRL::RuntimeClass<WindowsStorage::IStorageItem> {
  InspectableClass(L"Tests.Item", BaseTrust);

 public:
  explicit Item(int* destroyed) : destroyed_(destroyed) {}
  ~Item() override { ++*destroyed_; }
  HRESULT STDMETHODCALLTYPE RenameAsyncOverloadDefaultOptions(
      HSTRING, WindowsFoundation::IAsyncAction**) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE
  RenameAsync(HSTRING, WindowsStorage::NameCollisionOption,
              WindowsFoundation::IAsyncAction**) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE DeleteAsyncOverloadDefaultOptions(
      WindowsFoundation::IAsyncAction**) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE
  DeleteAsync(WindowsStorage::StorageDeleteOption,
              WindowsFoundation::IAsyncAction**) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE GetBasicPropertiesAsync(
      WindowsFoundation::IAsyncOperation<
          WindowsStorage::FileProperties::BasicProperties*>**) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE get_Name(HSTRING* value) override {
    return WindowsCreateString(L"owned.png", 9, value);
  }
  HRESULT STDMETHODCALLTYPE get_Path(HSTRING* value) override {
    return WindowsCreateString(L"C:\\owned.png", 12, value);
  }
  HRESULT STDMETHODCALLTYPE
  get_Attributes(WindowsStorage::FileAttributes*) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE
  get_DateCreated(WindowsFoundation::DateTime*) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE IsOfType(WindowsStorage::StorageItemTypes,
                                     boolean* value) override {
    *value = true;
    return S_OK;
  }

 private:
  int* destroyed_;
};

std::shared_ptr<const PreparedShare> Text(const char* text) {
  flutter::EncodableValue args(flutter::EncodableMap{
      {flutter::EncodableValue("text"), flutter::EncodableValue(text)}});
  ShareRequest request;
  OK(ParseShareRequest(&args, &request));
  std::shared_ptr<const PreparedShare> prepared;
  OK(PrepareShare(std::move(request), &prepared));
  return prepared;
}

WRL::ComPtr<DataTransfer::IDataPackageView> View(const Args& args) {
  WRL::ComPtr<DataTransfer::IDataPackageView> view;
  OK(args.request->data->GetView(&view));
  return view;
}

bool Contains(const Args& args, const wchar_t* format) {
  WRL::ComPtr<DataTransfer::IStandardDataFormatsStatics> formats;
  OK(RoGetActivationFactory(
      HStringReference(
          RuntimeClass_Windows_ApplicationModel_DataTransfer_StandardDataFormats)
          .Get(),
      IID_PPV_ARGS(&formats)));
  HString name;
  if (std::wstring(format) == L"StorageItems") {
    OK(formats->get_StorageItems(name.GetAddressOf()));
  } else {
    OK(formats->get_Text(name.GetAddressOf()));
  }
  boolean contains = false;
  OK(View(args)->Contains(name.Get(), &contains));
  return contains;
}

template <typename T>
void Wait(T* operation) {
  WRL::ComPtr<IAsyncInfo> info;
  OK(operation->QueryInterface(IID_PPV_ARGS(&info)));
  AsyncStatus status;
  do {
    OK(info->get_Status(&status));
    if (status == AsyncStatus::Started) SleepEx(1, TRUE);
  } while (status == AsyncStatus::Started);
  CHECK(status == AsyncStatus::Completed);
}

std::wstring ReadText(const Args& args) {
  WRL::ComPtr<WindowsFoundation::IAsyncOperation<HSTRING>> operation;
  OK(View(args)->GetTextAsync(&operation));
  Wait(operation.Get());
  HString text;
  OK(operation->GetResults(text.GetAddressOf()));
  return text.GetRawBuffer(nullptr);
}

void FreshArguments() {
  ShareRequest request;
  flutter::EncodableValue file(flutter::EncodableMap{
      {flutter::EncodableValue("title"), flutter::EncodableValue("old title")},
      {flutter::EncodableValue("text"), flutter::EncodableValue("old text")},
      {flutter::EncodableValue("paths"),
       flutter::EncodableValue(
           flutter::EncodableList{flutter::EncodableValue("C:\\first.png")})}});
  OK(ParseShareRequest(&file, &request));
  CHECK(request.paths.size() == 1);
  flutter::EncodableValue text(flutter::EncodableMap{
      {flutter::EncodableValue("text"), flutter::EncodableValue("new text")}});
  OK(ParseShareRequest(&text, &request));
  CHECK(request.paths.empty());
  CHECK(request.title == L"new text");
  CHECK(request.text == L"new text");
  flutter::EncodableValue file_only(
      flutter::EncodableMap{{flutter::EncodableValue("paths"),
                             flutter::EncodableValue(flutter::EncodableList{
                                 flutter::EncodableValue("C:\\next.png")})}});
  OK(ParseShareRequest(&file_only, &request));
  CHECK(request.text.empty());
  CHECK(request.title == L"next.png");
  flutter::EncodableValue invalid(
      flutter::EncodableMap{{flutter::EncodableValue("paths"),
                             flutter::EncodableValue(flutter::EncodableList{
                                 flutter::EncodableValue(4)})}});
  CHECK(ParseShareRequest(&invalid, &request) == E_INVALIDARG);
  flutter::EncodableValue utf8(flutter::EncodableMap{
      {flutter::EncodableValue("text"),
       flutter::EncodableValue(std::string("\xc0\x80", 2))}});
  CHECK(FAILED(ParseShareRequest(&utf8, &request)));
}

void RequestIsolationAndSubscriptionLifetime() {
  auto manager = WRL::Make<Manager>();
  WRL::ComPtr<Handler> queued;
  {
    ShareRequestSubscription subscription(manager.Get());
    auto first = Text("first");
    CHECK(subscription.Start(first, [] { return S_OK; }).operation == S_OK);
    queued = manager->handlers.begin()->second;
    for (int i = 0; i != 100; ++i) {
      CHECK(subscription.Start(Text("next"), [] { return S_OK; }).operation ==
            S_OK);
      CHECK(manager->handlers.size() == 1);
    }
    auto args = WRL::Make<Args>();
    OK(queued->Invoke(manager.Get(), args.Get()));
    CHECK(ReadText(*args.Get()) == L"first");
    auto current = WRL::Make<Args>();
    OK(manager->handlers.begin()->second->Invoke(manager.Get(), current.Get()));
    CHECK(ReadText(*current.Get()) == L"next");
    CHECK(!Contains(*current.Get(), L"StorageItems"));
  }
  CHECK(manager->handlers.empty());
  // An OS-dispatched callback may outlive its subscription/plugin; no `this`
  // or current mutable request is needed to provide its original data.
  auto late = WRL::Make<Args>();
  OK(queued->Invoke(manager.Get(), late.Get()));
  CHECK(ReadText(*late.Get()) == L"first");
  CHECK(manager->adds == manager->removes);
}

void FailureAndRollback() {
  {
    auto manager = WRL::Make<Manager>();
    ShareRequestSubscription subscription(manager.Get());
    OK(subscription.Start(Text("pending first"), [] { return S_OK; }).operation);
    // The first panel has not raised DataRequested yet. A failed replacement
    // must leave the manager's active handler able to serve that panel.
    auto result = subscription.Start(Text("failed second"), [] { return E_ABORT; });
    CHECK(result.operation == E_ABORT && result.cleanup == S_OK);
    CHECK(manager->handlers.size() == 1);
    auto restored = WRL::Make<Args>();
    OK(manager->handlers.begin()->second->Invoke(manager.Get(), restored.Get()));
    CHECK(ReadText(*restored.Get()) == L"pending first");
    // A DataRequested callback may also run inside Show. Do not commit either
    // payload until Show has returned; a deferral must preserve that request.
    auto during_failure = WRL::Make<Args>();
    bool premature_data = false;
    bool premature_completion = false;
    result = subscription.Start(Text("failed reentrant"), [&] {
      OK(manager->handlers.begin()->second->Invoke(manager.Get(), during_failure.Get()));
      premature_data = Contains(*during_failure.Get(), L"Text");
      premature_completion = during_failure->request->deferral->completions != 0;
      return E_ABORT;
    });
    CHECK(result.operation == E_ABORT && result.cleanup == S_OK);
    CHECK(!premature_data && !premature_completion);
    CHECK(ReadText(*during_failure.Get()) == L"pending first");
    CHECK(during_failure->request->deferral->completions == 1);
    auto during_success = WRL::Make<Args>();
    OK(subscription.Start(Text("accepted third"), [&] {
      OK(manager->handlers.begin()->second->Invoke(manager.Get(), during_success.Get()));
      CHECK(!Contains(*during_success.Get(), L"Text"));
      CHECK(during_success->request->deferral->completions == 0);
      return S_OK;
    }).operation);
    CHECK(ReadText(*during_success.Get()) == L"accepted third");
    CHECK(during_success->request->deferral->completions == 1);

    // The OS callback may race Show on another thread. In this case Show
    // returns while GetDeferral is still running, before it enters our queue.
    auto concurrent = WRL::Make<Args>();
    std::promise<void> deferral_entered;
    auto entered = deferral_entered.get_future();
    std::promise<void> release_deferral;
    auto released = release_deferral.get_future();
    concurrent->request->before_deferral = [&] {
      deferral_entered.set_value();
      released.wait();
    };
    HRESULT callback_result = E_PENDING;
    std::thread worker;
    result = subscription.Start(Text("failed concurrent"), [&] {
      const auto callback = manager->handlers.begin()->second;
      worker = std::thread([&, callback] {
        const HRESULT initialized = RoInitialize(RO_INIT_MULTITHREADED);
        callback_result = SUCCEEDED(initialized)
                              ? callback->Invoke(manager.Get(), concurrent.Get())
                              : initialized;
        if (FAILED(initialized)) deferral_entered.set_value();
        if (SUCCEEDED(initialized)) RoUninitialize();
      });
      entered.wait();
      return E_ABORT;
    });
    release_deferral.set_value();
    worker.join();
    CHECK(result.operation == E_ABORT && result.cleanup == S_OK);
    OK(callback_result);
    CHECK(ReadText(*concurrent.Get()) == L"accepted third");
    CHECK(concurrent->request->deferral->completions == 1);

    auto rejected_data = WRL::Make<Args>();
    rejected_data->request->data_result = E_ACCESSDENIED;
    rejected_data->request->deferral->result = E_FAIL;
    result = subscription.Start(Text("failed delivery"), [&] {
      OK(manager->handlers.begin()->second->Invoke(manager.Get(), rejected_data.Get()));
      return E_ABORT;
    });
    CHECK(result.operation == E_ABORT);
    CHECK(rejected_data->request->failure.find(L"80070005") != std::wstring::npos);
    CHECK(rejected_data->request->deferral->completions == 1);
    manager->next_add_result = E_ACCESSDENIED;
    bool shown = false;
    result = subscription.Start(Text("failed registration"), [&] {
      shown = true;
      return S_OK;
    });
    CHECK(result.operation == E_ACCESSDENIED && result.cleanup == S_OK && !shown);
    CHECK(manager->handlers.size() == 1);
    auto after_add_failure = WRL::Make<Args>();
    OK(manager->handlers.begin()->second->Invoke(manager.Get(), after_add_failure.Get()));
    CHECK(ReadText(*after_add_failure.Get()) == L"accepted third");
    // Native re-registration can itself fail; retain both diagnostics rather
    // than falsely claiming the old request was restored.
    manager->add_result = E_FAIL;
    result = subscription.Start(Text("restore failure"), [] { return S_OK; });
    CHECK(result.operation == E_FAIL && result.cleanup == E_FAIL);
    CHECK(manager->handlers.empty() && manager->peak_handlers == 1);
  }
  auto manager = WRL::Make<Manager>();
  ShareRequestSubscription subscription(manager.Get());
  manager->add_result = E_ACCESSDENIED;
  bool shown = false;
  auto result = subscription.Start(Text("one"), [&] {
    shown = true;
    return S_OK;
  });
  CHECK(result.operation == E_ACCESSDENIED && !shown);
  CHECK(manager->handlers.empty());
  manager->add_result = S_OK;
  auto rejected = WRL::Make<Args>();
  result = subscription.Start(Text("two"), [&] {
    OK(manager->handlers.begin()->second->Invoke(manager.Get(), rejected.Get()));
    return E_ABORT;
  });
  CHECK(result.operation == E_ABORT && result.cleanup == S_OK);
  CHECK(manager->handlers.empty());
  CHECK(!Contains(*rejected.Get(), L"Text"));
  CHECK(rejected->request->failure.find(L"80004004") != std::wstring::npos);
  CHECK(rejected->request->deferral->completions == 1);
  OK(subscription.Start(Text("three"), [] { return S_OK; }).operation);
  manager->remove_result = E_FAIL;
  const int adds = manager->adds;
  result = subscription.Start(Text("four"), [] { return S_OK; });
  CHECK(result.operation == E_FAIL);
  CHECK(manager->handlers.size() == 1 && manager->adds == adds);
  manager->remove_result = S_OK;
  OK(subscription.Reset());
  result = subscription.Start(Text("five"), [&] {
    manager->remove_result = E_ACCESSDENIED;
    return E_ABORT;
  });
  CHECK(result.operation == E_ABORT && result.cleanup == E_ACCESSDENIED);
  CHECK(manager->handlers.size() == 1);
  manager->remove_result = S_OK;
  OK(subscription.Reset());
}

void NativePackageAndComOwnership() {
  int destroyed = 0;
  auto item = WRL::Make<Item>(&destroyed);
  std::shared_ptr<const PreparedShare> prepared;
  OK(PrepareShare(
      {L"files", L"", {L"owned.png"}}, &prepared,
      [&](const std::wstring&, WindowsStorage::IStorageItem** value) {
        return item.CopyTo(value);
      }));
  WRL::ComPtr<StorageItems> iterable;
  OK(CreateStorageItems(prepared->files, &iterable));
  item.Reset();
  prepared.reset();
  CHECK(destroyed == 0);
  // Exercise the production iterable after its builder and source snapshot
  // have returned. Its iterator independently keeps the heap collection alive.
  {
    WRL::ComPtr<WindowsFoundation::Collections::IIterator<
        WindowsStorage::IStorageItem*>>
        iterator;
    OK(iterable->First(&iterator));
    iterable.Reset();
    WRL::ComPtr<WindowsStorage::IStorageItem> returned;
    OK(iterator->get_Current(&returned));
    HString name;
    OK(returned->get_Name(name.GetAddressOf()));
    CHECK(std::wstring(name.GetRawBuffer(nullptr)) == L"owned.png");
  }
  CHECK(destroyed == 1);

  int partial_destroyed = 0;
  int reads = 0;
  CHECK(PrepareShare(
            {L"files", L"", {L"one", L"two"}}, &prepared,
            [&](const std::wstring&, WindowsStorage::IStorageItem** value) {
              if (++reads == 2) return E_ACCESSDENIED;
              return WRL::Make<Item>(&partial_destroyed).CopyTo(value);
            }) == E_ACCESSDENIED);
  CHECK(!prepared && partial_destroyed == 1);
}

void CallbackFailureIsNotSilentlyIgnored() {
  auto args = WRL::Make<Args>();
  args->request->data_result = E_ACCESSDENIED;
  args->request->report_result = E_FAIL;
  CHECK(PopulateShare(*Text("one"), args.Get()) == E_ACCESSDENIED);
  CHECK(args->request->failure.find(L"80070005") != std::wstring::npos);
  args->result = E_ABORT;
  CHECK(PopulateShare(*Text("one"), args.Get()) == E_ABORT);
}

void RealStorageFile() {
  wchar_t directory[MAX_PATH];
  CHECK(GetTempPathW(MAX_PATH, directory) != 0);
  wchar_t path[MAX_PATH];
  CHECK(GetTempFileNameW(directory, L"vsh", 0, path) != 0);
  struct Cleanup {
    const wchar_t* path;
    ~Cleanup() { DeleteFileW(path); }
  } cleanup{path};
  {
    WRL::ComPtr<WindowsStorage::IStorageItem> file;
    OK(ResolveStorageItem(path, &file));
    HString actual;
    OK(file->get_Path(actual.GetAddressOf()));
    CHECK(std::wstring(actual.GetRawBuffer(nullptr)) == path);
    std::shared_ptr<const PreparedShare> prepared;
    OK(PrepareShare({L"File", L"", {path}}, &prepared));
    auto manager = WRL::Make<Manager>();
    ShareRequestSubscription subscription(manager.Get());
    OK(subscription.Start(prepared, [] { return S_OK; }).operation);
    auto old_file_callback = manager->handlers.begin()->second;
    auto args = WRL::Make<Args>();
    OK(old_file_callback->Invoke(manager.Get(), args.Get()));
    CHECK(Contains(*args.Get(), L"StorageItems"));
    CHECK(!Contains(*args.Get(), L"Text"));
    OK(subscription.Start(Text("only this text"), [] { return S_OK; })
           .operation);
    auto text_args = WRL::Make<Args>();
    OK(manager->handlers.begin()->second->Invoke(manager.Get(),
                                                 text_args.Get()));
    CHECK(ReadText(*text_args.Get()) == L"only this text");
    CHECK(!Contains(*text_args.Get(), L"StorageItems"));
    auto late_args = WRL::Make<Args>();
    OK(old_file_callback->Invoke(manager.Get(), late_args.Get()));
    CHECK(Contains(*late_args.Get(), L"StorageItems"));
    CHECK(!Contains(*late_args.Get(), L"Text"));
    OK(subscription.Start(prepared, [] { return S_OK; }).operation);
    auto new_file_args = WRL::Make<Args>();
    OK(manager->handlers.begin()->second->Invoke(manager.Get(),
                                                 new_file_args.Get()));
    CHECK(Contains(*new_file_args.Get(), L"StorageItems"));
    CHECK(!Contains(*new_file_args.Get(), L"Text"));
    prepared.reset();
    using Items = WindowsFoundation::Collections::IVectorView<
        WindowsStorage::IStorageItem*>;
    WRL::ComPtr<WindowsFoundation::IAsyncOperation<Items*>> operation;
    OK(View(*args.Get())->GetStorageItemsAsync(&operation));
    Wait(operation.Get());
    WRL::ComPtr<Items> items;
    OK(operation->GetResults(&items));
    unsigned count = 0;
    OK(items->get_Size(&count));
    CHECK(count == 1);
    WRL::ComPtr<WindowsStorage::IStorageItem> returned;
    OK(items->GetAt(0, &returned));
    HString returned_path;
    OK(returned->get_Path(returned_path.GetAddressOf()));
    CHECK(std::wstring(returned_path.GetRawBuffer(nullptr)) == path);
  }
  CHECK(DeleteFileW(path));
  WRL::ComPtr<WindowsStorage::IStorageItem> missing;
  CHECK(FAILED(ResolveStorageItem(path, &missing)));
  CHECK(!missing);
}

int main() {
  const HRESULT initialized = RoInitialize(RO_INIT_MULTITHREADED);
  if (FAILED(initialized)) return 2;
  int result = 0;
  try {
    FreshArguments();
    RequestIsolationAndSubscriptionLifetime();
    FailureAndRollback();
    NativePackageAndComOwnership();
    CallbackFailureIsNotSilentlyIgnored();
    RealStorageFile();
    std::cout << "6 production WinRT/share regression groups passed\n";
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    result = 1;
  }
  RoUninitialize();
  return result;
}
