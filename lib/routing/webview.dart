import 'dart:async';
import 'dart:convert';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/menu.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/network/proxy.dart';
import 'package:venera_next/foundation/extensions.dart';
import 'package:venera_next/foundation/translations.dart';
import 'dart:io' as io;

export 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show WebUri, URLRequest;

extension WebviewExtension on InAppWebViewController {
  Future<List<io.Cookie>?> getCookies(String url) async {
    if (url.contains("https://")) {
      url.replaceAll("https://", "");
    }
    if (url[url.length - 1] == '/') {
      url = url.substring(0, url.length - 1);
    }
    CookieManager cookieManager = CookieManager.instance(
      webViewEnvironment: AppWebview.webViewEnvironment,
    );
    final cookies = await cookieManager.getCookies(
      url: WebUri(url),
      webViewController: this,
    );
    var res = <io.Cookie>[];
    for (var cookie in cookies) {
      var c = io.Cookie(cookie.name, cookie.value);
      c.domain = cookie.domain;
      res.add(c);
    }
    return res;
  }

  Future<String?> getUA() async {
    var res = await evaluateJavascript(source: "navigator.userAgent");
    if (res is String) {
      if (res[0] == "'" || res[0] == "\"") {
        res = res.substring(1, res.length - 1);
      }
    }
    return res is String ? res : null;
  }
}

class AppWebview extends StatefulWidget {
  const AppWebview({
    required this.initialUrl,
    this.onTitleChange,
    this.onNavigation,
    this.singlePage = false,
    this.onStarted,
    this.onLoadStop,
    super.key,
  });

  final String initialUrl;

  final void Function(String title, InAppWebViewController controller)?
  onTitleChange;

  final bool Function(String url, InAppWebViewController controller)?
  onNavigation;

  final void Function(InAppWebViewController controller)? onStarted;

  final void Function(InAppWebViewController controller)? onLoadStop;

  final bool singlePage;

  static WebViewEnvironment? webViewEnvironment;

  @override
  State<AppWebview> createState() => _AppWebviewState();
}

class _AppWebviewState extends State<AppWebview> with ContextMenuOwner {
  @override
  Object? get contextMenuIdentity => controller;
  InAppWebViewController? controller;
  int _menuActionGeneration = 0;

  @override
  void deactivate() {
    _menuActionGeneration++;
    super.deactivate();
  }

  String title = "Webview";

  double _progress = 0;

  late var future = _createWebviewEnvironment();

  Future<bool> _createWebviewEnvironment() async {
    var proxy = appdata.settings['proxy'].toString();
    if (proxy != "system" && proxy != "direct") {
      var proxyAvailable = await WebViewFeature.isFeatureSupported(
        WebViewFeature.PROXY_OVERRIDE,
      );
      if (proxyAvailable) {
        ProxyController proxyController = ProxyController.instance();
        await proxyController.clearProxyOverride();
        if (!proxy.contains("://")) {
          proxy = "http://$proxy";
        }
        await proxyController.setProxyOverride(
          settings: ProxySettings(proxyRules: [ProxyRule(url: proxy)]),
        );
      }
    }
    if (!App.isWindows) {
      return true;
    }
    AppWebview.webViewEnvironment = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: "${App.dataPath}\\webview",
      ),
    );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final actions = [
      Tooltip(
        message: "more".tl,
        child: IconButton(
          icon: const Icon(Icons.more_horiz),
          onPressed: () {
            final target = controller;
            if (target == null) return;
            final generation = _menuActionGeneration;
            bool current() =>
                mounted &&
                generation == _menuActionGeneration &&
                identical(controller, target) &&
                NavigationAdmission.allows(context) &&
                (ModalRoute.of(context)?.isCurrent ?? false);
            Future<void> useUrl(Future<void> Function(String) action) async {
              if (!current()) return;
              final url = await target.getUrl();
              if (current() && url != null && url.toString().isNotEmpty) {
                await action(url.toString());
              }
            }

            contextMenus
                .show(context, Offset(context.width, context.padding.top), [
                  MenuEntry(
                    icon: Icons.open_in_browser,
                    text: "Open in Browser".tl,
                    onClick: () => useUrl((url) async {
                      await launchUrlString(url);
                    }),
                  ),
                  MenuEntry(
                    icon: Icons.copy,
                    text: "Copy link".tl,
                    onClick: () => useUrl(
                      (url) => Clipboard.setData(ClipboardData(text: url)),
                    ),
                  ),
                  MenuEntry(
                    icon: Icons.refresh,
                    text: "Reload".tl,
                    onClick: () => target.reload(),
                  ),
                ]);
          },
        ),
      ),
    ];

    Widget body = FutureBuilder(
      future: future,
      builder: (context, e) {
        if (e.error != null) {
          return Center(child: Text('${"Error".tl}: ${e.error}'));
        }
        if (!e.hasData) {
          return const SizedBox();
        }
        return createWebviewWithEnvironment(AppWebview.webViewEnvironment);
      },
    );

    body = Stack(
      children: [
        Positioned.fill(child: body),
        if (_progress < 1.0)
          const Positioned.fill(
            child: Center(child: CircularProgressIndicator()),
          ),
      ],
    );

    return Scaffold(
      appBar: Appbar(
        title: Text(
          title == "Webview" ? title.tl : title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: actions,
      ),
      body: body,
    );
  }

  Widget createWebviewWithEnvironment(WebViewEnvironment? e) {
    return InAppWebView(
      webViewEnvironment: e,
      initialSettings: InAppWebViewSettings(isInspectable: true),
      initialUrlRequest: URLRequest(url: WebUri(widget.initialUrl)),
      onTitleChanged: (c, t) {
        if (mounted) {
          setState(() {
            title = t ?? "Webview";
          });
        }
        widget.onTitleChange?.call(title, controller!);
      },
      shouldOverrideUrlLoading: (c, r) async {
        var res =
            widget.onNavigation?.call(r.request.url?.toString() ?? "", c) ??
            false;
        if (res) {
          return NavigationActionPolicy.CANCEL;
        } else {
          return NavigationActionPolicy.ALLOW;
        }
      },
      onWebViewCreated: (c) {
        if (!mounted) return;
        controller = c;
        contextMenus.revalidate();
        widget.onStarted?.call(c);
      },
      onLoadStop: (c, r) {
        widget.onLoadStop?.call(c);
      },
      onProgressChanged: (c, p) {
        if (mounted) {
          setState(() {
            _progress = p / 100;
          });
        }
      },
    );
  }
}

class DesktopWebview {
  static Future<bool> isAvailable() => WebviewWindow.isWebviewAvailable();

  final String initialUrl;

  final void Function(String title, DesktopWebview controller)? onTitleChange;

  final void Function(String url, DesktopWebview webview)? onNavigation;

  final void Function(DesktopWebview controller)? onStarted;

  final void Function()? onClose;

  DesktopWebview({
    required this.initialUrl,
    this.onTitleChange,
    this.onNavigation,
    this.onStarted,
    this.onClose,
  });

  Webview? _webview;
  Future<void>? _opening;
  Future<void>? _closing;
  bool _closed = false;
  Timer? _started;
  final _polls = <Future<void>>{};

  String? _ua;

  String? title;

  void onMessage(String message) {
    var json = jsonDecode(message);
    if (json is Map) {
      if (json["id"] == "document_created") {
        title = json["data"]["title"];
        _ua = json["data"]["ua"];
        onTitleChange?.call(title!, this);
      }
    }
  }

  String? get userAgent => _ua;

  Timer? timer;

  void _runTimer() {
    timer ??= Timer.periodic(const Duration(seconds: 2), (t) {
      late final Future<void> task;
      task = _poll().whenComplete(() => _polls.remove(task));
      _polls.add(task);
    });
  }

  Future<void> _poll() async {
    const js = '''
        function collect() {
          if(document.readyState === 'loading') {
            return '';
          }
          let data = {
            id: "document_created",
            data: {
              title: document.title,
              url: location.href,
              ua: navigator.userAgent
            }
          };
          return data;
        }
        collect();
      ''';
    final current = _webview;
    if (current != null && !_closed) {
      try {
        final result = await current.evaluateJavaScript(js);
        if (!_closed && identical(current, _webview)) onMessage(result ?? '');
      } catch (error, stack) {
        Log.error('Desktop webview', error, stack);
      }
    }
  }

  Future<void> open() => _opening ??= _observeLifecycle(_open());

  // Existing fire-and-forget callers still report failures; owners may await
  // the same original Future to include creation/close in their own lifetime.
  Future<void> _observeLifecycle(Future<void> operation) {
    unawaited(
      operation.catchError((Object error, StackTrace stack) {
        Log.error('Desktop webview', error, stack);
      }),
    );
    return operation;
  }

  Future<void> _open() async {
    if (_closed) throw StateError('Desktop webview is closed');
    _webview = await WebviewWindow.create(
      configuration: CreateConfiguration(
        useWindowPositionAndSize: true,
        userDataFolderWindows: "${App.dataPath}\\webview",
        title: "Webview".tl,
        proxy: await getProxy(),
      ),
    );
    if (_closed) {
      final created = _webview!;
      created.close();
      await created.onClose;
      _webview = null;
      return;
    }
    _webview!.addOnWebMessageReceivedCallback(onMessage);
    _webview!.setOnNavigation((s) {
      s = s.substring(1, s.length - 1);
      return onNavigation?.call(s, this);
    });
    _webview!.launch(initialUrl, triggerOnUrlRequestEvent: false);
    _runTimer();
    _webview!.onClose.then((value) {
      _closed = true;
      _webview = null;
      timer?.cancel();
      timer = null;
      _started?.cancel();
      onClose?.call();
    });
    _started = Timer(const Duration(milliseconds: 200), () {
      if (!_closed) onStarted?.call(this);
    });
  }

  Future<String?> evaluateJavascript(String source) {
    return _webview!.evaluateJavaScript(source);
  }

  Future<Map<String, String>> getCookies(String url) async {
    var allCookies = await _webview!.getAllCookies();
    var res = <String, String>{};
    for (var c in allCookies) {
      if (_cookieMatch(url, c.domain)) {
        res[_removeCode0(c.name)] = _removeCode0(c.value);
      }
    }
    return res;
  }

  String _removeCode0(String s) {
    var codeUints = List<int>.from(s.codeUnits);
    codeUints.removeWhere((e) => e == 0);
    return String.fromCharCodes(codeUints);
  }

  bool _cookieMatch(String url, String domain) {
    domain = _removeCode0(domain);
    var host = Uri.parse(url).host;
    var acceptedHost = _getAcceptedDomains(host);
    return acceptedHost.contains(domain.removeAllBlank);
  }

  List<String> _getAcceptedDomains(String host) {
    var acceptedDomains = <String>[host];
    var hostParts = host.split(".");
    for (var i = 0; i < hostParts.length - 1; i++) {
      acceptedDomains.add(".${hostParts.sublist(i).join(".")}");
    }
    return acceptedDomains;
  }

  Future<void> close() {
    _closed = true;
    timer?.cancel();
    _started?.cancel();
    return _closing ??= _observeLifecycle(_close());
  }

  Future<void> _close() async {
    await _opening;
    final current = _webview;
    if (current != null) {
      current.close();
      await current.onClose;
    }
    await Future.wait(_polls.toList());
  }
}
