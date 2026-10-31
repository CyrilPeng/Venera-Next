import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
// Exercise the actual Windows factory from the existing locked plugin, not a
// fake Android feature implementation that would hide issue #128.
// ignore: depend_on_referenced_packages
import 'package:flutter_inappwebview_windows/flutter_inappwebview_windows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/routing/webview.dart';
import 'package:venera_next/routing/windows_webview_environment.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  App.dataPath = 'windows-webview-proxy-test';
  late _WindowsPlatform platform;

  setUp(() {
    final previous = InAppWebViewPlatform.instance;
    final previousProxy = appdata.settings['proxy'];
    platform = _WindowsPlatform();
    InAppWebViewPlatform.instance = platform;
    addTearDown(() {
      if (previous != null) InAppWebViewPlatform.instance = previous;
      appdata.settings['proxy'] = previousProxy;
    });
  });

  Future<void> pumpInitialization(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump();
    }
  }

  InAppWebViewController attach() {
    final view = platform.views.last;
    final native = _Controller();
    final controller = InAppWebViewController.fromPlatform(platform: native);
    view.params.onWebViewCreated!(controller);
    // The real plugin makes distinct Dart wrappers for the same platform view.
    view.params.onProgressChanged!(
      InAppWebViewController.fromPlatform(platform: native),
      100,
    );
    return controller;
  }

  testWidgets(
    'Windows modes create a view without any Android feature query',
    (tester) async {
      for (final proxy in [
        'system',
        '127.0.0.1:7890',
        'direct',
        'http://127.0.0.1:7890',
      ]) {
        appdata.settings['proxy'] = proxy;
        final count = platform.environments.length;
        await tester.pumpWidget(
          const MaterialApp(home: AppWebview(initialUrl: 'about:blank')),
        );
        await pumpInitialization(tester);
        expect(platform.featureQueries, 0);
        expect(platform.environments, hasLength(count + 1));
        final environment = platform.environments.last;
        expect(
          environment.settings!.userDataFolder,
          '${App.dataPath}\\webview',
        );
        expect(
          environment.settings!.additionalBrowserArguments,
          windowsWebviewProxyArguments(proxy),
        );
        final controller = attach();
        await tester.pumpAndSettle();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        appdata.settings['proxy'] = 'another-proxy.example:9999';
        final wrapped = InAppWebViewController.fromPlatform(
          platform: controller.platform,
        );
        expect(
          (await wrapped.getCookies('https://example.test/'))!.single.value,
          'synthetic',
        );
        expect(platform.cookieEnvironments.last, same(environment));
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        await expectLater(
          wrapped.getCookies('https://example.test/'),
          throwsA(isA<WebviewEnvironmentException>()),
        );
        expect(tester.takeException(), isNull);
      }
    },
    skip: !io.Platform.isWindows,
  );

  testWidgets(
    'a different proxy cannot create a conflicting live browser',
    (tester) async {
      appdata.settings['proxy'] = 'system';
      final firstVisible = ValueNotifier(true);
      final secondVisible = ValueNotifier(false);
      addTearDown(firstVisible.dispose);
      addTearDown(secondVisible.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: firstVisible,
            builder: (_, first, _) => ValueListenableBuilder<bool>(
              valueListenable: secondVisible,
              builder: (_, second, _) => Column(
                children: [
                  if (first)
                    const Expanded(
                      key: ValueKey('first'),
                      child: AppWebview(initialUrl: 'about:blank'),
                    ),
                  if (second)
                    const Expanded(
                      key: ValueKey('second'),
                      child: AppWebview(initialUrl: 'about:blank'),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await pumpInitialization(tester);
      attach();
      await tester.pumpAndSettle();
      appdata.settings['proxy'] = '127.0.0.1:7890';
      secondVisible.value = true;
      await pumpInitialization(tester);
      expect(
        find.textContaining('Close other in-app web pages'),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(platform.environments, hasLength(1));
      firstVisible.value = false;
      await tester.pump();
      await tester.tap(find.text('Retry'));
      await pumpInitialization(tester);
      expect(platform.environments, hasLength(2));
      expect(platform.environments.first.disposals, 1);
      attach();
      await tester.pumpAndSettle();
      expect(find.textContaining('Close other in-app web pages'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
    skip: !io.Platform.isWindows,
  );

  testWidgets(
    'unmount during creation does not publish a controller or hold a lease',
    (tester) async {
      appdata.settings['proxy'] = 'system';
      final pending = Completer<void>();
      platform.beforeCreate = () => pending.future;
      var started = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: AppWebview(
            initialUrl: 'about:blank',
            onStarted: (_) => started++,
          ),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      pending.complete();
      await pumpInitialization(tester);
      expect(platform.views, isEmpty);
      expect(started, 0);
      platform.beforeCreate = null;
      appdata.settings['proxy'] = 'direct';
      await tester.pumpWidget(
        const MaterialApp(home: AppWebview(initialUrl: 'about:blank')),
      );
      await pumpInitialization(tester);
      expect(platform.environments, hasLength(2));
      expect(platform.environments.first.disposals, 1);
      attach();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
    skip: !io.Platform.isWindows,
  );

  testWidgets(
    'initialization errors stop loading, remain readable, and allow retry',
    (tester) async {
      tester.view.physicalSize = const Size(375, 300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      appdata.settings['proxy'] = 'user:synthetic-secret@localhost:7890';
      final app = MaterialApp(
        theme: ThemeData.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: const AppWebview(initialUrl: 'about:blank'),
      );
      await tester.pumpWidget(app);
      await pumpInitialization(tester);
      expect(
        find.textContaining('Authenticated manual proxies'),
        findsOneWidget,
      );
      expect(find.textContaining('synthetic-secret'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(platform.environments, isEmpty);
      expect(tester.takeException(), isNull);
      appdata.settings['proxy'] = 'direct';
      platform.beforeCreate = () async =>
          throw PlatformException(code: 'test', message: 'native failure');
      await tester.ensureVisible(find.text('Retry'));
      await tester.tap(find.text('Retry'));
      await pumpInitialization(tester);
      expect(
        find.textContaining('Check that WebView2 Runtime is installed'),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      final pending = Completer<void>();
      platform.beforeCreate = () => pending.future;
      await tester.ensureVisible(find.text('Retry'));
      final retry = tester
          .widget<FilledButton>(find.byType(FilledButton))
          .onPressed!;
      retry();
      retry();
      await pumpInitialization(tester);
      expect(platform.createAttempts, 2);
      pending.complete();
      await pumpInitialization(tester);
      attach();
      await tester.pumpAndSettle();
      retry();
      await tester.pump();
      expect(platform.createAttempts, 2);
      expect(find.text('Retry'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
    skip: !io.Platform.isWindows,
  );

  testWidgets(
    'late native callbacks cannot publish after the webview closes',
    (tester) async {
      appdata.settings['proxy'] = 'direct';
      final events = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: AppWebview(
            initialUrl: 'about:blank',
            onStarted: (_) => events.add('started'),
            onTitleChange: (_, _) => events.add('title'),
            onLoadStop: (_) => events.add('loaded'),
            onNavigation: (_, _) {
              events.add('navigate');
              return false;
            },
          ),
        ),
      );
      await pumpInitialization(tester);
      final controller = attach();
      await tester.pumpAndSettle();
      final view = platform.views.last;
      final wrapper = InAppWebViewController.fromPlatform(
        platform: controller.platform,
      );
      view.params.onTitleChanged!(wrapper, 'Active');
      view.params.onLoadStop!(wrapper, WebUri('about:blank'));
      await tester.pump();
      expect(events, ['started', 'title', 'loaded']);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      view.params.onTitleChanged!(wrapper, 'Late');
      view.params.onLoadStop!(wrapper, WebUri('about:blank'));
      view.params.onWebViewCreated!(wrapper);
      view.params.onProgressChanged!(wrapper, 10);
      expect(events, ['started', 'title', 'loaded']);
      expect(tester.takeException(), isNull);
    },
    skip: !io.Platform.isWindows,
  );
}

class _WindowsPlatform extends WindowsInAppWebViewPlatform {
  int featureQueries = 0;
  int createAttempts = 0;
  final environments = <_Environment>[];
  final views = <_View>[];
  final cookieEnvironments = <PlatformWebViewEnvironment?>[];
  Future<void> Function()? beforeCreate;

  @override
  PlatformWebViewFeature createPlatformWebViewFeatureStatic() {
    featureQueries++;
    return super.createPlatformWebViewFeatureStatic();
  }

  @override
  WindowsWebViewEnvironment createPlatformWebViewEnvironmentStatic() =>
      _EnvironmentFactory(this);

  @override
  WindowsInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    final view = _View(params);
    views.add(view);
    return view;
  }

  @override
  WindowsCookieManager createPlatformCookieManager(
    PlatformCookieManagerCreationParams params,
  ) => _Cookies(params, this);
}

class _EnvironmentFactory extends WindowsWebViewEnvironment {
  _EnvironmentFactory(this.owner)
    : super(const PlatformWebViewEnvironmentCreationParams());
  final _WindowsPlatform owner;

  @override
  Future<WindowsWebViewEnvironment> create({
    WebViewEnvironmentSettings? settings,
  }) async {
    owner.createAttempts++;
    await owner.beforeCreate?.call();
    final environment = _Environment(settings!);
    owner.environments.add(environment);
    return environment;
  }
}

class _Environment extends WindowsWebViewEnvironment {
  _Environment(WebViewEnvironmentSettings settings)
    : super(PlatformWebViewEnvironmentCreationParams(settings: settings));
  int disposals = 0;

  @override
  Future<void> dispose() async {
    disposals++;
  }
}

class _View extends WindowsInAppWebViewWidget {
  _View(super.params);

  @override
  Widget build(BuildContext context) => const SizedBox.expand();

  @override
  void dispose() {
    params.webViewEnvironment?.onBrowserProcessExited?.call(_BrowserExit());
  }
}

class _Controller extends PlatformInAppWebViewController {
  _Controller()
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 1),
      );
}

class _Cookies extends WindowsCookieManager {
  _Cookies(super.params, this.owner);
  final _WindowsPlatform owner;

  @override
  Future<List<Cookie>> getCookies({
    required WebUri url,
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) async {
    owner.cookieEnvironments.add(params.webViewEnvironment);
    return [
      Cookie(name: 'session', value: 'synthetic', domain: 'example.test'),
    ];
  }
}

class _BrowserExit extends Fake implements BrowserProcessExitedDetail {}
