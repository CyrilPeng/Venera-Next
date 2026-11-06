# desktop_webview_window

[![Pub](https://img.shields.io/pub/v/desktop_webview_window.svg)](https://pub.dev/packages/desktop_webview_window)

Show a webview window on your flutter desktop application.

|          |       |     |
| -------- | ------- | ---- |
| Windows  | ✅     | [Webview2](https://www.nuget.org/packages/Microsoft.Web.WebView2) 1.0.992.28 |
| Linux    | ✅    |  [WebKitGTK-4.1](https://webkitgtk.org/reference/webkit2gtk/stable/index.html) or [WebKitGTK-4.0](https://webkitgtk.org/reference/webkit2gtk/2.5.1/) |
| macOS    | ✅     |  WKWebview |

## Getting Started

1. modify your `main` method.
   ```dart
   import 'package:desktop_webview_window/desktop_webview_window.dart';
   
   void main() async {
     WidgetsFlutterBinding.ensureInitialized();
     
     // Add this your main method.
     // used to show a webview title bar.
     if (runWebViewTitleBarWidget(args)) {
       return;
     }
   
     runApp(MyApp());
   }
   
   ```

2. launch WebViewWindow

   ```dart
     final webview = await WebviewWindow.create();
     webview.launch("https://example.com");
   ```

## linux requirement

In Ubuntu/Debian:
```shell
sudo apt-get install libwebkit2gtk-4.1-0 libwebkit2gtk-4.1-dev libsoup-3.0-0 libsoup-3.0-dev
```

In Fedora/RPM:
```shell
sudo dnf install webkit2gtk4.1 webkit2gtk4.1-devel libsoup3 libsoup3-devel
```

## Windows

### Requirement

The backend of desktop_webview_window on Windows is WebView2, which requires **WebView2 Runtime** installed.

[WebView2 Runtime](https://developer.microsoft.com/en-us/microsoft-edge/webview2) is ship in box with Windows11, but
it may not installed on Windows10 devices. So you need consider how to distribute the runtime to your users.

See more: https://docs.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution

For convenience, you can use `WebviewWindow.isWebviewAvailable()` check whether the WebView2 is available.

### Attention

The default user data folder of WebView2 is `your_exe_file\WebView2`, which is not a good place to store user data.

eg. if the application is installed in a read-only directory, the application will crash when WebView2 try to write data.

you can use `WebviewWindow.create()` to create a webview with a custom user data folder.

```dart
final webview = await WebviewWindow.create(
  confiruation: CreateConfiguration(
    userDataFolderWindows: 'your_custom_user_data_folder',
  ),
);
```

## License

see [LICENSE](./LICENSE)
