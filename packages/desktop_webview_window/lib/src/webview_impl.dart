// VeneraNext: formatting and SDK compatibility; see LOCAL_PATCHES.md.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_webview_window/src/cookie.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'webview.dart';

class WebviewImpl extends Webview {
  final int viewId;

  final MethodChannel channel;

  final Map<String, JavaScriptMessageHandler> _javaScriptMessageHandlers = {};

  bool _closed = false;

  PromptHandler? _promptHandler;

  final _closeCompleter = Completer<void>();

  OnHistoryChangedCallback? _onHistoryChanged;

  final ValueNotifier<bool> _isNavigating = ValueNotifier<bool>(false);

  OnUrlRequestCallback? _onUrlRequestCallback;

  void Function(String)? _onNavigation;

  final Set<OnWebMessageReceivedCallback> _onWebMessageReceivedCallbacks = {};

  WebviewImpl(this.viewId, this.channel);

  @override
  Future<void> get onClose => _closeCompleter.future;

  void onClosed() {
    _closed = true;
    _closeCompleter.complete();
  }

  void onJavaScriptMessage(String name, dynamic body) {
    assert(!_closed);
    final handler = _javaScriptMessageHandlers[name];
    assert(handler != null, "handler $name is not registed.");
    handler?.call(name, body);
  }

  String onRunJavaScriptTextInputPanelWithPrompt(
    String prompt,
    String defaultText,
  ) {
    assert(!_closed);
    return _promptHandler?.call(prompt, defaultText) ?? defaultText;
  }

  void onHistoryChanged(bool canGoBack, bool canGoForward) {
    assert(!_closed);
    _onHistoryChanged?.call(canGoBack, canGoForward);
  }

  void onNavigationStarted() {
    Future.delayed(const Duration(milliseconds: 200), () async {
      _onNavigation?.call(await evaluateJavaScript("location.href") ?? '');
    });
    _isNavigating.value = true;
  }

  bool notifyUrlChanged(String url) {
    if (_onUrlRequestCallback != null) {
      return _onUrlRequestCallback!(url);
    } else {
      return true;
    }
  }

  void notifyWebMessageReceived(String message) {
    for (final callback in _onWebMessageReceivedCallbacks) {
      callback(message);
    }
  }

  void onNavigationCompleted() {
    _isNavigating.value = false;
  }

  @override
  ValueListenable<bool> get isNavigating => _isNavigating;

  @override
  void registerJavaScriptMessageHandler(
    String name,
    JavaScriptMessageHandler handler,
  ) {
    if (!Platform.isMacOS) {
      return;
    }
    assert(!_closed);
    if (_closed) {
      return;
    }
    assert(name.isNotEmpty);
    assert(!_javaScriptMessageHandlers.containsKey(name));
    _javaScriptMessageHandlers[name] = handler;
    channel.invokeMethod("registerJavaScripInterface", {
      "viewId": viewId,
      "name": name,
    });
  }

  @override
  void unregisterJavaScriptMessageHandler(String name) {
    if (!Platform.isMacOS) {
      return;
    }
    if (_closed) {
      return;
    }
    channel.invokeMethod("unregisterJavaScripInterface", {
      "viewId": viewId,
      "name": name,
    });
  }

  @override
  void setPromptHandler(PromptHandler? handler) {
    if (!Platform.isMacOS) {
      return;
    }
    _promptHandler = handler;
  }

  @override
  void launch(String url, {bool triggerOnUrlRequestEvent = true}) async {
    await channel.invokeMethod("launch", {
      "url": url,
      "viewId": viewId,
      "triggerOnUrlRequestEvent": triggerOnUrlRequestEvent,
    });
  }

  @override
  void setBrightness(Brightness? brightness) {
    /// -1 : system default
    /// 0 : dark
    /// 1 : light
    if (!Platform.isMacOS) {
      return;
    }
    channel.invokeMethod("setBrightness", {
      "viewId": viewId,
      "brightness": brightness?.index ?? -1,
    });
  }

  @override
  void addScriptToExecuteOnDocumentCreated(String javaScript) {
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return;
    }
    assert(javaScript.trim().isNotEmpty);
    channel.invokeMethod("addScriptToExecuteOnDocumentCreated", {
      "viewId": viewId,
      "javaScript": javaScript,
    });
  }

  @override
  Future<void> setApplicationNameForUserAgent(String applicationName) async {
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return;
    }
    await channel.invokeMethod("setApplicationNameForUserAgent", {
      "viewId": viewId,
      "applicationName": applicationName,
    });
  }

  @override
  Future<void> forward() {
    return channel.invokeMethod("forward", {"viewId": viewId});
  }

  @override
  Future<void> setWebviewWindowVisibility(bool visible) {
    return channel.invokeMethod("setWebviewWindowVisibility", {
      "viewId": viewId,
      "visible": visible,
    });
  }

  @override
  Future<void> moveWebviewWindow(int left, int top, int width, int height) {
    return channel.invokeMethod("moveWebviewWindow", {
      "viewId": viewId,
      "left": left,
      "top": top,
      "width": width,
      "height": height,
    });
  }

  @override
  Future<void> bringToForeground({bool maximized = false}) {
    return channel.invokeMethod("bringToForeground", {
      "viewId": viewId,
      "maximized": maximized,
    });
  }

  @override
  Future<Map<dynamic, dynamic>?> getPositionalParameters() async {
    return await channel.invokeMethod("getPositionalParameters", {
      "viewId": viewId,
    });
  }

  @override
  Future<void> back() {
    return channel.invokeMethod("back", {"viewId": viewId});
  }

  @override
  Future<void> reload() {
    return channel.invokeMethod("reload", {"viewId": viewId});
  }

  @override
  Future<void> stop() {
    return channel.invokeMethod("stop", {"viewId": viewId});
  }

  @override
  Future<void> openDevToolsWindow() {
    return channel.invokeMethod('openDevToolsWindow', {"viewId": viewId});
  }

  @override
  void setOnHistoryChangedCallback(OnHistoryChangedCallback? callback) {
    _onHistoryChanged = callback;
  }

  @override
  void setOnUrlRequestCallback(OnUrlRequestCallback? callback) {
    _onUrlRequestCallback = callback;
  }

  @override
  void addOnWebMessageReceivedCallback(OnWebMessageReceivedCallback callback) {
    _onWebMessageReceivedCallbacks.add(callback);
  }

  @override
  void removeOnWebMessageReceivedCallback(
    OnWebMessageReceivedCallback callback,
  ) {
    _onWebMessageReceivedCallbacks.remove(callback);
  }

  @override
  void close() {
    if (_closed) {
      return;
    }
    channel.invokeMethod("close", {"viewId": viewId});
  }

  @override
  Future<String?> evaluateJavaScript(String javaScript) async {
    final dynamic result = await channel.invokeMethod("evaluateJavaScript", {
      "viewId": viewId,
      "javaScriptString": javaScript,
    });
    if (result is String || result == null) {
      return result;
    }
    return json.encode(result);
  }

  @override
  Future<void> postWebMessageAsString(String webMessage) async {
    return channel.invokeMethod("postWebMessageAsString", {
      "viewId": viewId,
      "webMessage": webMessage,
    });
  }

  @override
  Future<void> postWebMessageAsJson(String webMessage) async {
    return channel.invokeMethod("postWebMessageAsJson", {
      "viewId": viewId,
      "webMessage": webMessage,
    });
  }

  @override
  Future<List<WebviewCookie>> getAllCookies() async {
    final result = await channel.invokeListMethod<Map>("getAllCookies", {
      "viewId": viewId,
    });

    return result
            ?.map((e) => WebviewCookie.fromJson(e.cast<String, dynamic>()))
            .toList() ??
        [];
  }

  @override
  void setOnNavigation(void Function(String p1)? onNavigation) {
    _onNavigation = onNavigation;
  }
}
