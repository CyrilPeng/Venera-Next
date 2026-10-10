import 'dart:io' as io;

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

void passCloudflare(CloudflareException e, void Function() onFinished) async {
  final rootContext = appNavigation.rootContext;
  var url = e.url;
  var uri = Uri.parse(url);

  final CookieJarSql cookieJar;
  try {
    cookieJar = await SingleInstanceCookieJar.captureInstance();
  } catch (error, stack) {
    Log.error('Cloudflare', error, stack);
    if (rootContext.mounted) rootContext.showMessage(message: error.toString());
    onFinished();
    return;
  }
  if (!rootContext.mounted) {
    onFinished();
    return;
  }

  Future<bool> persistCookies(List<io.Cookie> cookies) async {
    try {
      await cookieJar.saveFromResponseAsync(uri, cookies);
      return true;
    } catch (error, stack) {
      Log.error('Cloudflare', error, stack);
      if (rootContext.mounted) {
        rootContext.showMessage(message: error.toString());
      }
      return false;
    }
  }

  Future<bool> saveCookies(Map<String, String> cookies) {
    var domain = uri.host;
    var splits = domain.split('.');
    if (splits.length > 1) {
      domain = ".${splits[splits.length - 2]}.${splits[splits.length - 1]}";
    }
    return persistCookies(
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
    var webview = DesktopWebview(
      initialUrl: url,
      onTitleChange: (title, controller) async {
        var head =
            await controller.evaluateJavascript("document.head.innerHTML") ??
            "";
        var body =
            await controller.evaluateJavascript("document.body.innerHTML") ??
            "";
        Log.info("Cloudflare", "Checking head: $head");
        var isChallenging =
            head.contains('#challenge-success-text') ||
            head.contains("#challenge-error-text") ||
            head.contains("#challenge-form") ||
            body.contains("challenge-platform") ||
            body.contains("window._cf_chl_opt");
        if (!isChallenging) {
          Log.info(
            "Cloudflare",
            "Cloudflare is passed due to there is no challenge css",
          );
          var ua = controller.userAgent;
          if (ua != null) {
            appdata.implicitData['ua'] = ua;
            appdata.writeImplicitData();
          }
          var cookiesMap = await controller.getCookies(url);
          if (cookiesMap['cf_clearance'] == null) {
            return;
          }
          if (!await saveCookies(cookiesMap)) return;
          controller.close();
          onFinished();
        }
      },
      onClose: onFinished,
    );
    webview.open();
  } else {
    bool success = false;
    void check(InAppWebViewController controller) async {
      var head =
          await controller.evaluateJavascript(source: "document.head.innerHTML")
              as String;
      var body =
          await controller.evaluateJavascript(source: "document.body.innerHTML")
              as String;
      Log.info("Cloudflare", "Checking head: $head");
      var isChallenging =
          head.contains('#challenge-success-text') ||
          head.contains("#challenge-error-text") ||
          head.contains("#challenge-form") ||
          body.contains("challenge-platform") ||
          body.contains("window._cf_chl_opt");
      if (!isChallenging) {
        Log.info(
          "Cloudflare",
          "Cloudflare is passed due to there is no challenge css",
        );
        var ua = await controller.getUA();
        if (ua != null) {
          appdata.implicitData['ua'] = ua;
          appdata.writeImplicitData();
        }
        var cookies = await controller.getCookies(url) ?? [];
        if (cookies.firstWhereOrNull(
              (element) => element.name == 'cf_clearance',
            ) ==
            null) {
          return;
        }
        if (!await persistCookies(cookies)) return;
        if (!success) {
          appNavigation.rootPop();
          success = true;
        }
      }
    }

    await rootContext.to(
      () => AppWebview(
        initialUrl: url,
        singlePage: true,
        onTitleChange: (title, controller) async {
          check(controller);
        },
        onLoadStop: (controller) async {
          check(controller);
        },
        onStarted: (controller) async {
          var ua = await controller.getUA();
          if (ua != null) {
            appdata.implicitData['ua'] = ua;
            appdata.writeImplicitData();
          }
          var cookies = await controller.getCookies(url) ?? [];
          await persistCookies(cookies);
        },
      ),
    );
    onFinished();
  }
}
