//
// Created by yangbin on 2021/11/12.
//

#include "web_view.h"

#include <tchar.h>
#include <windows.h>

#include <cassert>
#include <map>
#include <memory>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "flutter/method_result_functions.h"
#include "strconv.h"
#include "utils.h"
#include "WebView2EnvironmentOptions.h"

namespace webview_window {

    static LRESULT CALLBACK WndProc(HWND const window, UINT const message,
        WPARAM const wparam,
        LPARAM const lparam) noexcept {
        return DefWindowProc(window, message, wparam, lparam);
    }

    const auto kWebViewClassName = _T("web_view_window_web_view");

    using namespace Microsoft::WRL;

    WebView::WebView(
        std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>>
        method_channel,
        int64_t web_view_id, std::wstring userDataFolder,
        std::function<void(HRESULT)> on_web_view_created, std::wstring proxy)
        : method_channel_(std::move(method_channel)),
        web_view_id_(web_view_id),
        user_data_folder_(std::move(userDataFolder)),
        on_web_view_created_callback_(std::move(on_web_view_created)) {
        RegisterWindowClass(kWebViewClassName, WndProc);
        view_window_ = wil::unique_hwnd(::CreateWindowEx(
            0, kWebViewClassName, L"", WS_CHILD | WS_VISIBLE, 0, 0, 0, 0,
            HWND_MESSAGE, nullptr, ::GetModuleHandle(nullptr), nullptr));
        assert(view_window_ != nullptr);
        if (!view_window_) {
            on_web_view_created_callback_(S_FALSE);
            return;
        }

        auto options = Microsoft::WRL::Make<CoreWebView2EnvironmentOptions>();
        if(proxy.size()) {
            proxy = (std::wstring(L"--proxy-server=") + proxy);
            auto _proxy = new wchar_t[proxy.size() + 1];
            memcpy(_proxy, proxy.c_str(), proxy.length() * sizeof(wchar_t));
            _proxy[proxy.size()] = L'\0';
            options->put_AdditionalBrowserArguments(_proxy);
        }

        CreateCoreWebView2EnvironmentWithOptions(
            nullptr, user_data_folder_.c_str(), options.Get(),
            Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
                [this](HRESULT result, ICoreWebView2Environment* env) -> HRESULT {
                    if (!SUCCEEDED(result)) {
                        on_web_view_created_callback_(result);
                        return S_OK;
                    }
                    env->CreateCoreWebView2Controller(
                        view_window_.get(),
                        Callback<
                        ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                            [this](HRESULT result,
                                ICoreWebView2Controller* controller) -> HRESULT {
                                    on_web_view_created_callback_(result);
                                    if (SUCCEEDED(result)) {
                                        webview_controller_ = controller;
                                        OnWebviewControllerCreated();
                                    }
                                    return S_OK;
                            })
                        .Get());
                    return S_OK;
                })
            .Get());
    }

    void WebView::OnWebviewControllerCreated() {
        if (!webview_controller_) {
            return;
        }
        webview_controller_->get_CoreWebView2(&webview_);

        if (!webview_) {
            std::cerr << "failed to get core webview" << std::endl;
            return;
        }

        ICoreWebView2Settings* settings;
        webview_->get_Settings(&settings);
        settings->put_IsScriptEnabled(true);
        settings->put_AreDefaultScriptDialogsEnabled(true);
        settings->put_IsWebMessageEnabled(true);

        ICoreWebView2Settings2* settings2;
        auto hr = settings->QueryInterface(IID_PPV_ARGS(&settings2));
        if (SUCCEEDED(hr)) {
            LPWSTR user_agent[256];
            settings2->get_UserAgent(user_agent);
            default_user_agent_ = std::wstring(*user_agent);
        }

        UpdateBounds();

        webview_->add_NewWindowRequested(
            Callback<ICoreWebView2NewWindowRequestedEventHandler>(
                [](ICoreWebView2* sender,
                    ICoreWebView2NewWindowRequestedEventArgs* args) {
                        wil::unique_cotaskmem_string uri;
                        args->get_Uri(&uri);
                        args->put_Handled(false);
                        return S_OK;
                })
            .Get(),
                    nullptr);

        webview_->add_HistoryChanged(
            Callback<ICoreWebView2HistoryChangedEventHandler>(
                [this](ICoreWebView2* sender, IUnknown* args) {
                    auto method_args = flutter::EncodableMap{
                        {flutter::EncodableValue("id"),
                         flutter::EncodableValue(web_view_id_)},
                        {flutter::EncodableValue("canGoBack"),
                         flutter::EncodableValue(CanGoBack())},
                        {flutter::EncodableValue("canGoForward"),
                         flutter::EncodableValue(CanGoForward())},
                    };
                    method_channel_->InvokeMethod(
                        "onHistoryChanged",
                        std::make_unique<flutter::EncodableValue>(method_args));
                    return S_OK;
                })
            .Get(),
                    nullptr);

        webview_->add_NavigationStarting(
            Callback<ICoreWebView2NavigationStartingEventHandler>(
                [this](ICoreWebView2* sender,
                    ICoreWebView2NavigationStartingEventArgs* args) {
                        method_channel_->InvokeMethod(
                            "onNavigationStarted",
                            std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
                                {flutter::EncodableValue("id"),
                                 flutter::EncodableValue(web_view_id_)},
                                }));
                        wil::unique_cotaskmem_string uri;
                        args->get_Uri(&uri);
                        if (triggerOnUrlRequestedEvent && shouldBlockUri(uri.get()))
                        {
                            args->put_Cancel(true);
                        }
                        return S_OK;
                })
            .Get(),
                    nullptr);

        webview_->add_NavigationCompleted(
            Callback<ICoreWebView2NavigationCompletedEventHandler>(
                [this](ICoreWebView2* sender,
                    ICoreWebView2NavigationCompletedEventArgs* args) {
                        auto method_args = flutter::EncodableMap{
                            {flutter::EncodableValue("id"),
                             flutter::EncodableValue(web_view_id_)},
                        };
                        method_channel_->InvokeMethod(
                            "onNavigationCompleted",
                            std::make_unique<flutter::EncodableValue>(method_args));
                        return S_OK;
                })
            .Get(),
                    nullptr);
        webview_->add_WebMessageReceived(
            Callback<ICoreWebView2WebMessageReceivedEventHandler>(
                [this](ICoreWebView2* sender,
                    ICoreWebView2WebMessageReceivedEventArgs* args) {
                        wil::unique_cotaskmem_string messageRaw;
                        HRESULT hrString = args->TryGetWebMessageAsString(&messageRaw);
                        if (FAILED(hrString)) {
                            if (hrString == E_INVALIDARG) {
                                // web message was not a string --> should only happen if it was
                                // a JSON object
                                HRESULT hrJson = args->get_WebMessageAsJson(&messageRaw);
                                if (FAILED(hrJson)) {
                                    return hrJson;
                                }
                            }
                            else {
                                return hrString;
                            }
                        }
                        method_channel_->InvokeMethod(
                            "onWebMessageReceived",
                            std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
                                {flutter::EncodableValue("id"),
                                 flutter::EncodableValue(web_view_id_)},
                                {flutter::EncodableValue("message"),
                                 flutter::EncodableValue(
                                     wide_to_utf8(std::wstring(messageRaw.get())))},
                                }));
                        return S_OK;
                })
            .Get(),
                    nullptr);
    }

    void WebView::UpdateBounds() {
        // Resize WebView to fit the bounds of the parent window
        RECT bounds;
        GetClientRect(view_window_.get(), &bounds);
        webview_controller_->put_Bounds(bounds);
    }

    void WebView::Navigate(const std::wstring& url) {
        if (webview_) {
            webview_->Navigate(url.c_str());
        }
        else {
            std::cerr << "webview not created" << std::endl;
        }
    }

    void WebView::AddScriptToExecuteOnDocumentCreated(
        const std::wstring& javaScript) {
        if (webview_) {
            webview_->AddScriptToExecuteOnDocumentCreated(javaScript.c_str(), nullptr);
        }
    }

    void WebView::SetApplicationNameForUserAgent(const std::wstring& name) {
        if (webview_) {
            ICoreWebView2Settings* settings;
            webview_->get_Settings(&settings);
            ICoreWebView2Settings2* settings2;
            auto hr = settings->QueryInterface(IID_PPV_ARGS(&settings2));
            if (SUCCEEDED(hr)) {
                settings2->put_UserAgent((default_user_agent_ + name).c_str());
            }
        }
    }

    void WebView::GoBack() {
        if (webview_) {
            webview_->GoBack();
        }
    }

    void WebView::GoForward() {
        if (webview_) {
            webview_->GoForward();
        }
    }

    void WebView::Reload() {
        if (webview_) {
            webview_->Reload();
        }
    }

    void WebView::Stop() {
        if (webview_) {
            webview_->Stop();
        }
    }

    void WebView::GetAllCookies(
        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (webview_) {
            wil::com_ptr<ICoreWebView2_2> webView2;
            HRESULT hr = webview_->QueryInterface(IID_PPV_ARGS(&webView2));

            if (FAILED(hr) || !webView2) {
                result->Error("0", "Failed to get ICoreWebView2_2");
                return;
            }

            wil::com_ptr<ICoreWebView2CookieManager> cookieManager;
            HRESULT hrc = webView2->get_CookieManager(&cookieManager);

            if (FAILED(hrc) || !cookieManager) {
                result->Error("0", "Failed to get ICoreWebView2CookieManager");
                return;
            }

            cookieManager->GetCookies(
                nullptr,
                Callback<ICoreWebView2GetCookiesCompletedHandler>(
                    [result = std::move(result)](
                        HRESULT hr, ICoreWebView2CookieList* cookieList) -> HRESULT {
                            UINT cookieCount;
                            cookieList->get_Count(&cookieCount);

                            std::vector<flutter::EncodableValue> cookies;
                            for (UINT i = 0; i < cookieCount; ++i) {
                                wil::com_ptr<ICoreWebView2Cookie> cookie;
                                cookieList->GetValueAtIndex(i, &cookie);

                                LPWSTR name;
                                LPWSTR value;
                                LPWSTR domain;
                                LPWSTR path;
                                double expires;
                                BOOL isSecure;
                                BOOL isHttpOnly;
                                BOOL isSessionOnly;

                                cookie->get_Name(&name);
                                cookie->get_Value(&value);
                                cookie->get_Domain(&domain);
                                cookie->get_Path(&path);
                                cookie->get_Expires(&expires);
                                cookie->get_IsSecure(&isSecure);
                                cookie->get_IsHttpOnly(&isHttpOnly);
                                cookie->get_IsSession(&isSessionOnly);

                                std::map<flutter::EncodableValue, flutter::EncodableValue>
                                    cookieMap;
                                cookieMap[flutter::EncodableValue("name")] =
                                    flutter::EncodableValue(
                                        webview_window::ConvertLPCWSTRToString(name));
                                cookieMap[flutter::EncodableValue("value")] =
                                    flutter::EncodableValue(
                                        webview_window::ConvertLPCWSTRToString(value));
                                cookieMap[flutter::EncodableValue("domain")] =
                                    flutter::EncodableValue(
                                        webview_window::ConvertLPCWSTRToString(domain));
                                cookieMap[flutter::EncodableValue("path")] =
                                    flutter::EncodableValue(
                                        webview_window::ConvertLPCWSTRToString(path));

                                if (expires >= 0) {
                                    cookieMap[flutter::EncodableValue(std::string("expires"))] =
                                        flutter::EncodableValue(static_cast<double>(expires));
                                }
                                else {
                                    cookieMap[flutter::EncodableValue(std::string("expires"))] =
                                        flutter::EncodableValue();
                                }

                                cookieMap[flutter::EncodableValue("secure")] =
                                    flutter::EncodableValue(static_cast<bool>(isSecure));
                                cookieMap[flutter::EncodableValue("httpOnly")] =
                                    flutter::EncodableValue(static_cast<bool>(isHttpOnly));
                                cookieMap[flutter::EncodableValue("sessionOnly")] =
                                    flutter::EncodableValue(static_cast<bool>(isSessionOnly));

                                cookies.push_back(flutter::EncodableValue(cookieMap));
                            }

                            result->Success(flutter::EncodableValue(cookies));
                            return S_OK;
                    })
                .Get());

        }
        else {
            result->Error("0", "webview not created");
        }
    }

    void WebView::openDevToolsWindow() {
        if (webview_) {
            webview_->OpenDevToolsWindow();
        }
    }

    bool WebView::CanGoBack() const {
        if (webview_) {
            BOOL can_go_back;
            webview_->get_CanGoBack(&can_go_back);
            return can_go_back;
        }
        return false;
    }

    bool WebView::CanGoForward() const {
        if (webview_) {
            BOOL can_go_forward;
            webview_->get_CanGoForward(&can_go_forward);
            return can_go_forward;
        }
        return false;
    }

    void WebView::ExecuteJavaScript(
        const std::wstring& javaScript,
        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> completer) {
        if (webview_) {
            webview_->ExecuteScript(
                javaScript.c_str(),
                Callback<ICoreWebView2ExecuteScriptCompletedHandler>(
                    [completer(std::move(completer))](HRESULT error,
                        PCWSTR result) -> HRESULT {
                            if (error != S_OK) {
                                completer->Error("0", "Error executing JavaScript");
                            }
                            else {
                                completer->Success(flutter::EncodableValue(
                                    wide_to_utf8(std::wstring(result))));
                            }
                            return S_OK;
                    })
                .Get());
        }
        else {
            completer->Error("0", "webview not created");
        }
    }

    void WebView::PostWebMessageAsString(
        const std::wstring& webmessage,
        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> completer) {
        if (webview_) {
            if (webview_->PostWebMessageAsString(webmessage.c_str()) == NOERROR) {
                completer->Success();
            }
            else {
                completer->Error("0", "Error posting webmessage as String");
            }
        }
        else {
            completer->Error("0", "webview not created");
        }
    }

    void WebView::PostWebMessageAsJson(
        const std::wstring& webmessage,
        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> completer) {
        if (webview_) {
            if (webview_->PostWebMessageAsJson(webmessage.c_str()) == NOERROR) {
                completer->Success();
            }
            else {
                completer->Error("0", "Error posting webmessage as JSON");
            }
        }
        else {
            completer->Error("0", "webview not created");
        }
    }

    void WebView::setTriggerOnUrlRequestedEvent(const bool value) {
        this->triggerOnUrlRequestedEvent = value;
    }

    bool waitingForChecking = false;

    WebView::~WebView() {
        if (webview_) {
            webview_->Stop();
        }
        if (webview_controller_) {
            webview_controller_->Close();
        }
    }

    char* convertWcharToUTF8(const wchar_t* str)
    {
        int wideStrLen = static_cast<int>(wcslen(str) + 1);
        int mbStrLen = WideCharToMultiByte(CP_UTF8, 0, str, wideStrLen, NULL, 0, NULL, NULL);

        char* mbStr = new char[mbStrLen];
        WideCharToMultiByte(CP_UTF8, 0, str, wideStrLen, mbStr, mbStrLen, NULL, NULL);
        return mbStr;
    }

    std::string wstringToString(std::wstring str)
    {
        auto newCStr = convertWcharToUTF8(str.c_str());
        auto newStr = std::string{ newCStr };
        delete[] newCStr;
        return newStr;
    }

    bool WebView::shouldBlockUri(std::wstring uri) {
        if (waitingForChecking) {
            waitingForChecking = false;
            return false;
        }
        auto value = std::make_unique<flutter::EncodableValue>(flutter::EncodableValue{ wstringToString(uri) });

        waitingForChecking = true;
        method_channel_->InvokeMethod("onUrlRequested",
            std::make_unique<flutter::EncodableValue>(
                flutter::EncodableMap{
                    {flutter::EncodableValue("id"),
                     flutter::EncodableValue(web_view_id_)},
                    {flutter::EncodableValue("url"),
                     flutter::EncodableValue(
                         wide_to_utf8(std::wstring(uri)))},
                }), std::make_unique<flutter::MethodResultFunctions<>>([uri, this](const flutter::EncodableValue* success_value) {
                    const bool letPass = std::get<bool>(*success_value);
                    if (letPass) {
                        webview_->Navigate(uri.c_str());
                    }
                    else {
                        waitingForChecking = false;
                    }
                    }, nullptr, nullptr));

        return true;
    }

}  // namespace webview_window