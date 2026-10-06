import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source_manager.dart';
import 'package:venera_next/features/comic_source/comic_source_page.dart';
import 'package:venera_next/features/comic_source/source.dart';
import 'package:venera_next/features/comic_source/source_data_storage.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/cookie_jar.dart';
import 'package:venera_next/routing/webview.dart';
import '../../support/comic_source_fixture.dart';

class _Platform extends InAppWebViewPlatform {
  bool progressSent = false;
  Future<List<Cookie>> Function() cookies = () async => [
    Cookie(name: 'session', value: 'value'),
  ];
  @override
  PlatformCookieManager createPlatformCookieManager(
    PlatformCookieManagerCreationParams params,
  ) => _Cookies(params, this);
  @override
  PlatformWebViewEnvironment createPlatformWebViewEnvironmentStatic() =>
      _Environment();
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) => _WebWidget(params, this);
}

class _Environment extends PlatformWebViewEnvironment {
  _Environment()
    : super.implementation(const PlatformWebViewEnvironmentCreationParams());
  static int sequence = 0;
  @override
  final String id = '${sequence++}';
  @override
  Future<PlatformWebViewEnvironment> create({
    WebViewEnvironmentSettings? settings,
  }) async => this;
}

class _WebWidget extends PlatformInAppWebViewWidget {
  _WebWidget(super.params, this.owner) : super.implementation();
  final _Platform owner;
  @override
  Widget build(BuildContext context) {
    if (!owner.progressSent) {
      owner.progressSent = true;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) =>
            params.onProgressChanged?.call(_Controller(_LocalStorage()), 100),
      );
    }
    return const SizedBox.expand();
  }

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      throw UnimplementedError();
  @override
  void dispose() {}
}

class _Cookies extends PlatformCookieManager {
  _Cookies(super.params, this.owner) : super.implementation();
  final _Platform owner;
  @override
  Future<List<Cookie>> getCookies({
    required WebUri url,
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) => owner.cookies();
}

class _ControllerPlatform extends Fake
    implements PlatformInAppWebViewController {}

class _LocalStorage extends Fake implements LocalStorage {
  int reads = 0;
  Future<List<WebStorageItem>> Function()? read;
  @override
  Future<List<WebStorageItem>> getItems() {
    reads++;
    return read?.call() ??
        Future.value([WebStorageItem(key: 'token', value: 'stored')]);
  }
}

class _WebStorage extends Fake implements WebStorage {
  _WebStorage(this.localStorage);
  @override
  final LocalStorage localStorage;
}

class _Controller extends Fake implements InAppWebViewController {
  _Controller(_LocalStorage storage) : webStorage = _WebStorage(storage);
  @override
  final PlatformInAppWebViewController platform = _ControllerPlatform();
  @override
  final WebStorage webStorage;
}

class _Storage extends SourceDataStorage {
  Future<void> Function()? before;
  int writes = 0;
  @override
  Future<void> write(String path, String key, String contents) async {
    writes++;
    await before?.call();
  }
}

void main() {
  final messages = <String>[];
  late ComicSourceManager manager;
  late ComicSource source;
  late _Storage storage;
  late _LocalStorage local;
  late _Controller controller;
  late GlobalKey<NavigatorState> navigator;
  int callbacks = 0;
  Future<void> Function()? onSuccess;

  Future<AppWebview> show(WidgetTester tester) async {
    final root = io.Directory.systemTemp.createTempSync('source-web-login-');
    App.dataPath = root.path;
    final previous = InAppWebViewPlatform.instance;
    final previousJar = SingleInstanceCookieJar.instance;
    final language = appdata.settings['language'];
    final proxy = appdata.settings['proxy'];
    final muted = Log.isMuted;
    Log.isMuted = true;
    appdata.settings['language'] = 'en-US';
    appdata.settings['proxy'] = 'direct';
    InAppWebViewPlatform.instance = _Platform();
    SingleInstanceCookieJar.instance = null;
    SingleInstanceCookieJar('${root.path}/cookie.db');
    storage = _Storage();
    local = _LocalStorage();
    controller = _Controller(local);
    callbacks = 0;
    onSuccess = null;
    source = ComicSourceFixture(
      key: 'web_login',
      dataStorage: storage,
      account: AccountConfig(
        null,
        'https://example.test/',
        null,
        () {},
        (_, _) => true,
        () async {
          callbacks++;
          await onSuccess?.call();
        },
        null,
        null,
      ),
    );
    manager = ComicSourceManager()..add(source);
    navigator = GlobalKey<NavigatorState>();
    messages.clear();
    registerShowMessageHandler((_, message) => messages.add(message));
    addTearDown(() async {
      storage.before = null;
      await tester.pumpWidget(const SizedBox());
      await manager.closeAndWait();
      SingleInstanceCookieJar.instance?.dispose();
      SingleInstanceCookieJar.instance = previousJar;
      if (previous != null) InAppWebViewPlatform.instance = previous;
      AppWebview.webViewEnvironment = null;
      appdata.settings['language'] = language;
      appdata.settings['proxy'] = proxy;
      Log.isMuted = muted;
      registerShowMessageHandler((_, _) {});
      root.deleteSync(recursive: true);
    });
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const ComicSourcePage()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Show source settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Login with webview'));
    await tester.pumpAndSettle();
    return tester.widget<AppWebview>(find.byType(AppWebview));
  }

  testWidgets(
    'web login coalesces callbacks and retries only the captured save',
    (tester) async {
      final web = await show(tester);
      final read = Completer<List<WebStorageItem>>();
      local.read = () => read.future;
      storage.before = () async => throw StateError('disk failed');
      web.onNavigation!('https://example.test/success', controller);
      web.onTitleChange!('Done', controller);
      await tester.pump();
      expect(local.reads, 1);
      read.complete([WebStorageItem(key: 'token', value: 'captured')]);
      await tester.pumpAndSettle();
      expect(callbacks, 0);
      expect(find.text('Retry'), findsOneWidget);
      storage.before = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(local.reads, 1);
      expect(callbacks, 1);
      expect(source.data, {
        'account': 'ok',
        '_localStorage': {'token': 'captured'},
      });
      expect(find.byType(AppWebview), findsNothing);
      expect(
        SingleInstanceCookieJar.instance!
            .loadForRequest(Uri.parse('https://example.test/'))
            .single
            .value,
        'value',
      );
    },
    skip: io.Platform.isLinux,
  );

  testWidgets(
    'retired web login cannot save cookies or data after a late read',
    (tester) async {
      final web = await show(tester);
      final read = Completer<List<WebStorageItem>>();
      local.read = () => read.future;
      web.onNavigation!('https://example.test/success', controller);
      await tester.pump();
      manager.remove(source.key);
      final replacement = ComicSourceFixture(
        key: source.key,
        dataStorage: storage,
      );
      manager.add(replacement);
      read.complete([WebStorageItem(key: 'token', value: 'late')]);
      await tester.pumpAndSettle();
      expect(source.data, isEmpty);
      expect(replacement.data, isEmpty);
      expect(callbacks, 0);
      expect(storage.writes, 0);
      expect(
        SingleInstanceCookieJar.instance!.loadForRequest(
          Uri.parse('https://example.test/'),
        ),
        isEmpty,
      );
    },
    skip: io.Platform.isLinux,
  );

  testWidgets(
    'late web login success never pops an unrelated top route',
    (tester) async {
      final web = await show(tester);
      final callback = Completer<void>();
      onSuccess = () => callback.future;
      web.onNavigation!('https://example.test/success', controller);
      await tester.pump();
      expect(callbacks, 1);
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Unrelated page')),
          ),
        ),
      );
      await tester.pump();
      callback.complete();
      await tester.pumpAndSettle();
      expect(find.text('Unrelated page'), findsOneWidget);
      expect(source.isLogged, isTrue);
      expect(callbacks, 1);
    },
    skip: io.Platform.isLinux,
  );
}
