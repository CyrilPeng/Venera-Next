import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/cloudflare.dart';
import 'package:venera_next/network/cookie_jar.dart';
import 'package:venera_next/routing/webview.dart';
import 'package:venera_next/foundation/extensions.dart';

import 'cloudflare_verification.dart';

void passCloudflare(CloudflareException e, void Function() onFinished) async {
  final rootContext = appNavigation.rootContext;
  final url = e.url;
  final uri = Uri.parse(url);
  CloudflareVerification? verification;
  var finished = false;
  void finish() {
    if (finished) return;
    finished = true;
    verification?.dispose();
    onFinished();
  }

  final CookieJarSql cookieJar;
  try {
    cookieJar = await SingleInstanceCookieJar.captureInstance();
  } catch (error, stack) {
    Log.error('Cloudflare', error, stack);
    if (rootContext.mounted) rootContext.showMessage(message: error.toString());
    finish();
    return;
  }
  if (!rootContext.mounted) {
    finish();
    return;
  }

  void reportError(Object error, StackTrace stack, {bool present = true}) {
    Log.error('Cloudflare', error, stack);
    if (present && !finished && rootContext.mounted) {
      rootContext.showMessage(message: error.toString());
    }
  }

  Future<void> saveCookies(Map<String, String> cookies) {
    var domain = uri.host;
    var splits = domain.split('.');
    if (splits.length > 1) {
      domain = ".${splits[splits.length - 2]}.${splits[splits.length - 1]}";
    }
    return cookieJar.saveFromResponseAsync(
      uri,
      List<io.Cookie>.generate(cookies.length, (index) {
        var cookie = io.Cookie(
          cookies.keys.elementAt(index),
          cookies.values.elementAt(index),
        );
        cookie.domain = domain;
        return cookie;
      }),
    );
  }

  // Linux uses the separate desktop WebView host and its cookie adapter.
  if (App.isLinux) {
    DesktopWebview? activeController;
    bool current() => !finished && rootContext.mounted;
    verification = CloudflareVerification(
      isCurrent: current,
      readPage: () async {
        final controller = activeController!;
        Future<Object?> read(String source) async {
          final value = await controller.evaluateJavascript(source);
          if (value == null) return null;
          // The desktop host returns JSON; older adapters returned plain text.
          try {
            return jsonDecode(value);
          } on FormatException {
            return value;
          }
        }

        final readyState = await read('document.readyState');
        final head = await read(
          'document.head ? document.head.innerHTML : null',
        );
        final body = await read(
          'document.body ? document.body.innerHTML : null',
        );
        return cloudflarePageState(
          readyState: readyState,
          head: head,
          body: body,
        );
      },
      accept: () async {
        final controller = activeController!;
        final cookies = await controller.getCookies(url);
        if (!current() || cookies['cf_clearance']?.isNotEmpty != true) {
          return false;
        }
        await saveCookies(cookies);
        if (!current()) return false;
        final ua = controller.userAgent;
        if (ua != null && ua.isNotEmpty) {
          appdata.implicitData['ua'] = ua;
          await appdata.writeImplicitData();
        }
        return current();
      },
      onPassed: () {
        activeController!.close();
        finish();
      },
      onError: (error, stack) => reportError(error, stack, present: current()),
    );
    final webview = DesktopWebview(
      initialUrl: url,
      onTitleChange: (title, controller) {
        activeController = controller;
        unawaited(verification!.check());
      },
      onClose: finish,
    );
    try {
      await webview.open();
    } catch (error, stack) {
      reportError(error, stack);
      finish();
    }
  } else {
    BuildContext? pageContext;
    ModalRoute<dynamic>? pageRoute;
    NavigatorState? navigator;
    InAppWebViewController? activeController;
    bool current() =>
        !finished &&
        pageContext?.mounted == true &&
        pageRoute?.isCurrent == true &&
        navigator?.mounted == true;
    void check(InAppWebViewController controller) {
      if (!current()) return;
      if (!identical(activeController, controller)) {
        verification?.dispose();
        activeController = controller;
        bool ownsController() =>
            current() && identical(activeController, controller);
        verification = CloudflareVerification(
          isCurrent: ownsController,
          readPage: () async {
            final readyState = await controller.evaluateJavascript(
              source: 'document.readyState',
            );
            final head = await controller.evaluateJavascript(
              source: 'document.head ? document.head.innerHTML : null',
            );
            final body = await controller.evaluateJavascript(
              source: 'document.body ? document.body.innerHTML : null',
            );
            return cloudflarePageState(
              readyState: readyState,
              head: head,
              body: body,
            );
          },
          accept: () async {
            final cookies = await controller.getCookies(url) ?? [];
            if (!ownsController() ||
                cookies.firstWhereOrNull(
                      (cookie) =>
                          cookie.name == 'cf_clearance' &&
                          cookie.value.isNotEmpty,
                    ) ==
                    null) {
              return false;
            }
            final ua = await controller.getUA();
            if (!ownsController()) return false;
            await cookieJar.saveFromResponseAsync(uri, cookies);
            if (!ownsController()) return false;
            if (ua != null && ua.isNotEmpty) {
              appdata.implicitData['ua'] = ua;
              await appdata.writeImplicitData();
            }
            return ownsController();
          },
          onPassed: () => navigator!.pop(),
          onError: (error, stack) =>
              reportError(error, stack, present: ownsController()),
        );
      }
      unawaited(verification!.check());
    }

    try {
      await rootContext.to(
        () => Builder(
          builder: (context) {
            pageContext = context;
            pageRoute = ModalRoute.of(context);
            navigator = Navigator.of(context);
            return AppWebview(
              initialUrl: url,
              singlePage: true,
              onTitleChange: (title, controller) => check(controller),
              onLoadStop: check,
              onStarted: check,
            );
          },
        ),
      );
    } catch (error, stack) {
      reportError(error, stack);
    } finally {
      finish();
    }
  }
}
