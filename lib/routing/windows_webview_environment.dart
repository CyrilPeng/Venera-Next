import 'dart:async';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class WebviewEnvironmentException implements Exception {
  const WebviewEnvironmentException(this.message);

  final String message;

  @override
  String toString() => message;
}

const _invalidProxy = WebviewEnvironmentException(
  'Invalid Windows webview proxy. Use host:port or a supported proxy URL without paths or options.',
);
const _busyEnvironment = WebviewEnvironmentException(
  'Close other in-app web pages before changing the proxy, then retry. If the browser is still busy, restart the app. Login data will be kept.',
);

String? windowsWebviewProxyArguments(String proxy) {
  if (proxy == 'system') return null;
  if (proxy == 'direct') return '--no-proxy-server';
  if (proxy.contains('@')) {
    throw const WebviewEnvironmentException(
      'Authenticated manual proxies are not supported by the Windows webview. Use an unauthenticated local proxy or the system proxy.',
    );
  }

  // Accept one endpoint, never Chromium arguments, bypass rules or credentials.
  final match = RegExp(
    r'^(?:(http|https|socks4|socks5)://)?(\[[0-9a-fA-F:.]+\]|[a-zA-Z0-9.-]+):([0-9]{1,5})$',
    caseSensitive: false,
  ).firstMatch(proxy);
  if (match == null || match.end != proxy.length) throw _invalidProxy;
  final scheme = (match[1] ?? 'http').toLowerCase();
  final host = match[2]!.toLowerCase();
  final port = int.parse(match[3]!);
  if (port < 1 || port > 65535) throw _invalidProxy;
  if (host.startsWith('[')) {
    final address = InternetAddress.tryParse(
      host.substring(1, host.length - 1),
    );
    if (address?.type != InternetAddressType.IPv6) throw _invalidProxy;
  } else if (host.length > 253 ||
      !RegExp(
        r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\.?$',
      ).hasMatch(host)) {
    throw _invalidProxy;
  }
  return '--proxy-server=$scheme://$host:$port';
}

/// One browser profile may only use one set of WebView2 options at a time.
class WindowsWebviewEnvironmentPool {
  WindowsWebviewEnvironmentPool({
    Future<WebViewEnvironment> Function(WebViewEnvironmentSettings)? create,
    this.browserExitTimeout = const Duration(seconds: 10),
  }) : _create =
           create ??
           ((settings) => WebViewEnvironment.create(settings: settings));

  final Future<WebViewEnvironment> Function(WebViewEnvironmentSettings) _create;
  final Duration browserExitTimeout;
  Future<void>? _pending;
  _EnvironmentEntry? _entry;

  Future<WindowsWebviewEnvironmentLease> acquire({
    required String userDataFolder,
    required String proxy,
  }) {
    final arguments = windowsWebviewProxyArguments(proxy);
    final result = _pending == null
        ? _acquire(userDataFolder, arguments)
        : _pending!.then((_) => _acquire(userDataFolder, arguments));
    late final Future<void> pending;
    void finish() {
      if (identical(_pending, pending)) _pending = null;
    }

    pending = result.then<void>(
      (_) => finish(),
      onError: (Object _, StackTrace _) => finish(),
    );
    _pending = pending;
    return result;
  }

  Future<WindowsWebviewEnvironmentLease> _acquire(
    String userDataFolder,
    String? arguments,
  ) async {
    final previous = _entry;
    if (previous != null) {
      if (previous.users > 0) {
        if (previous.userDataFolder != userDataFolder ||
            previous.arguments != arguments ||
            previous.browserExited.isCompleted) {
          throw _busyEnvironment;
        }
        return WindowsWebviewEnvironmentLease._(previous);
      }
      if (previous.viewRequested && !previous.browserExited.isCompleted) {
        // Environment creation can succeed with conflicting options; the later
        // native controller creation fails. Wait before exposing a new view.
        try {
          await previous.browserExited.future.timeout(browserExitTimeout);
        } on TimeoutException {
          throw _busyEnvironment;
        }
      }
      await previous.environment.dispose();
      _entry = null;
    }

    final environment = await _create(
      WebViewEnvironmentSettings(
        userDataFolder: userDataFolder,
        additionalBrowserArguments: arguments,
      ),
    );
    final entry = _EnvironmentEntry(environment, userDataFolder, arguments);
    environment.onBrowserProcessExited = (_) {
      if (!entry.browserExited.isCompleted) entry.browserExited.complete();
    };
    _entry = entry;
    return WindowsWebviewEnvironmentLease._(entry);
  }
}

class _EnvironmentEntry {
  _EnvironmentEntry(this.environment, this.userDataFolder, this.arguments);

  final WebViewEnvironment environment;
  final String userDataFolder;
  final String? arguments;
  final browserExited = Completer<void>();
  int users = 0;
  bool viewRequested = false;
}

class WindowsWebviewEnvironmentLease {
  WindowsWebviewEnvironmentLease._(this._entry) {
    _entry.users++;
  }

  final _EnvironmentEntry _entry;
  bool _released = false;

  WebViewEnvironment get environment => _entry.environment;

  void viewRequested() {
    if (!_released) _entry.viewRequested = true;
  }

  Future<T> use<T>(Future<T> Function(WebViewEnvironment) action) async {
    if (_released) {
      throw const WebviewEnvironmentException('This webview is closed.');
    }
    _entry.users++;
    try {
      return await action(environment);
    } finally {
      _entry.users--;
    }
  }

  void release() {
    if (_released) return;
    _released = true;
    _entry.users--;
  }
}
