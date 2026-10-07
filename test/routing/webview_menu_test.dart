import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/routing/webview.dart';

void main() {
  App.dataPath = 'webview-menu-test';
  for (final change in ['none', 'null URL', 'replace', 'remove', 'cover']) {
    testWidgets(
      'webview copy menu awaits only the original controller: $change',
      (tester) async {
        final previousPlatform = InAppWebViewPlatform.instance;
        final platform = _Platform();
        final previousProxy = appdata.settings['proxy'];
        InAppWebViewPlatform.instance = platform;
        appdata.settings['proxy'] = 'direct';
        final navigator = GlobalKey<NavigatorState>();
        final visible = ValueNotifier(true);
        final clipboard = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard.add((call.arguments as Map)['text'] as String);
            }
            return null;
          },
        );
        final pending = Completer<WebUri?>();
        final controller = _Controller()..url = pending.future;
        try {
          await tester.pumpWidget(
            MaterialApp(
              navigatorKey: navigator,
              home: ValueListenableBuilder<bool>(
                valueListenable: visible,
                builder: (_, show, _) => show
                    ? const AppWebview(initialUrl: 'https://example.test')
                    : const Scaffold(body: Text('Removed')),
              ),
            ),
          );
          for (
            var attempt = 0;
            attempt < 10 && platform.widgets.isEmpty;
            attempt++
          ) {
            await tester.pump();
          }
          final view = platform.widgets.last;
          void attach(_Controller value) {
            final wrapped = view.controllerFromPlatform<InAppWebViewController>(
              value,
            );
            view.params.onWebViewCreated!(wrapped);
            view.params.onProgressChanged!(wrapped, 100);
          }

          attach(controller);
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(Icons.more_horiz));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Copy link'));
          await tester.pumpAndSettle();
          expect(controller.reads, 1);
          switch (change) {
            case 'replace':
              attach(_Controller());
            case 'remove':
              visible.value = false;
            case 'cover':
              unawaited(
                navigator.currentState!.push<void>(
                  MaterialPageRoute(
                    builder: (_) => const Scaffold(body: Text('Cover')),
                  ),
                ),
              );
          }
          await tester.pumpAndSettle();
          pending.complete(
            change == 'null URL'
                ? null
                : WebUri('https://example.test/original'),
          );
          await tester.pump();
          expect(
            clipboard,
            change == 'none' ? ['https://example.test/original'] : isEmpty,
          );
          expect(tester.takeException(), isNull);
        } finally {
          if (!pending.isCompleted) pending.complete(null);
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
          visible.dispose();
          if (previousPlatform != null) {
            InAppWebViewPlatform.instance = previousPlatform;
          }
          appdata.settings['proxy'] = previousProxy;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          );
        }
      },
    );
  }
}

class _Platform extends InAppWebViewPlatform {
  final widgets = <_View>[];
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    final view = _View(params);
    widgets.add(view);
    return view;
  }

  @override
  PlatformWebViewEnvironment createPlatformWebViewEnvironmentStatic() =>
      _Environment();
}

class _Environment extends PlatformWebViewEnvironment {
  _Environment()
    : super.implementation(const PlatformWebViewEnvironmentCreationParams());
  @override
  Future<PlatformWebViewEnvironment> create({
    WebViewEnvironmentSettings? settings,
  }) async => this;
  @override
  String get id => 'test-environment';
}

class _View extends PlatformInAppWebViewWidget {
  _View(super.params) : super.implementation();
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      params.controllerFromPlatform!(controller) as T;
  @override
  void dispose() {}
}

class _Controller extends PlatformInAppWebViewController {
  _Controller()
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 1),
      );
  Future<WebUri?> url = Future.value(null);
  int reads = 0;
  @override
  Future<WebUri?> getUrl() {
    reads++;
    return url;
  }
}
