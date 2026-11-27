import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_shell/app_shell.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/reader/exit_guard.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/event_subscription.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/routing/app_links.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:venera_next/routing/handle_text_share.dart';

ComicSource _createLinkSource() {
  return ComicSource(
    'Example Source',
    'example_source',
    null,
    null,
    null,
    null,
    const [],
    null,
    const {},
    null,
    null,
    null,
    null,
    null,
    '',
    'https://example.test',
    '1.0.0',
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    LinkHandler(const ['example.test'], (link) {
      final uri = Uri.parse(link);
      if (uri.pathSegments.length == 2 && uri.pathSegments.first == 'comic') {
        return uri.pathSegments[1];
      }
      return null;
    }),
    false,
    false,
    null,
    null,
  );
}

class _FakeMainShell extends StatefulWidget {
  const _FakeMainShell({required this.mainKey});

  final GlobalKey<NavigatorState> mainKey;

  @override
  State<_FakeMainShell> createState() => _FakeMainShellState();
}

class _FakeMainShellState extends State<_FakeMainShell> {
  @override
  void initState() {
    appNavigation.mainNavigatorKey = widget.mainKey;
    super.initState();
  }

  @override
  void dispose() {
    if (identical(appNavigation.mainNavigatorKey, widget.mainKey)) {
      appNavigation.mainNavigatorKey = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Navigator(
      key: widget.mainKey,
      onGenerateRoute: (_) => MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Center(child: Text('Main Home'))),
      ),
    );
  }
}

Widget _buildShellApp({
  required GlobalKey<NavigatorState> mainKey,
  bool Function()? allowsNavigation,
}) {
  Widget app = MaterialApp(
    navigatorKey: appNavigation.rootNavigatorKey,
    home: Navigator(
      key: mainKey,
      onGenerateRoute: (_) => MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Center(child: Text('Main Home'))),
      ),
    ),
  );
  if (allowsNavigation != null) {
    app = NavigationAdmission(allowsNavigation: allowsNavigation, child: app);
  }
  return app;
}

Widget _fakeComicPage(String id, String sourceKey) =>
    Scaffold(body: Center(child: Text('Comic:$sourceKey:$id')));

Widget _fakeSearchPage(String keyword) =>
    Scaffold(body: Center(child: Text('Search:$keyword')));

void _mockAuthChannels(WidgetTester tester, VoidCallback onSystemPop) {
  const localAuthChannel = MethodChannel('plugins.flutter.io/local_auth');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'SystemNavigator.pop') {
        onSystemPop();
      }
      return null;
    },
  );
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    localAuthChannel,
    (call) async {
      if (call.method == 'isDeviceSupported') return true;
      if (call.method == 'getAvailableBiometrics') return <String>[];
      if (call.method == 'authenticate') return false;
      return null;
    },
  );
  addTearDown(() {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      localAuthChannel,
      null,
    );
  });
}

void main() {
  late ComicSource source;
  GlobalKey<NavigatorState>? previousMainKey;

  setUp(() {
    previousMainKey = appNavigation.mainNavigatorKey;
    appNavigation.clearPendingNavigation();
    source = _createLinkSource();
    configureComicSourceRegistry(
      all: () => [source],
      find: (key) => key == source.key ? source : null,
      fromIntKey: (key) => key == source.key.hashCode ? source : null,
      isEmpty: () => false,
    );
  });

  tearDown(() {
    appNavigation.clearPendingNavigation();
    appNavigation.mainNavigatorKey = previousMainKey;
    configureComicSourceRegistry(
      all: () => [],
      find: (_) => null,
      fromIntKey: (_) => null,
      isEmpty: () => true,
    );
  });

  testWidgets(
    'dismisses ReaderExitGuard (and top overlay) via maybePop and reveals linked ComicPage',
    (tester) async {
      final mainKey = GlobalKey<NavigatorState>();
      appNavigation.mainNavigatorKey = mainKey;
      await tester.pumpWidget(_buildShellApp(mainKey: mainKey));

      final saveCompleter = Completer<void Function()>();
      var prepareCalls = 0;
      var poppedCalls = 0;

      appNavigation.rootContext.to(
        () => ReaderExitGuard(
          prepare: () {
            prepareCalls++;
            return saveCompleter.future;
          },
          holdForLeave: () => () {},
          onError: (error, stack) =>
              fail('Unexpected reader exit error: $error'),
          onPopped: () => poppedCalls++,
          waitingDelay: const Duration(milliseconds: 200),
          child: const Scaffold(body: Center(child: Text('Reader Content'))),
        ),
      );
      await tester.pumpAndSettle();

      // Also push a dialog/sidebar overlay above Reader on rootNavigatorKey.
      appNavigation.rootContext.to(
        () => const Scaffold(body: Center(child: Text('Reader Overlay'))),
      );
      await tester.pumpAndSettle();
      expect(find.text('Reader Overlay'), findsOneWidget);

      final handled = await handleAppLink(
        Uri.parse('https://example.test/comic/42'),
        comicPageBuilder: _fakeComicPage,
      );
      expect(handled, isTrue);
      expect(prepareCalls, 1);

      // Advance past the top overlay's exit transition while Reader is saving.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Reader Overlay'), findsNothing);
      expect(find.text('Reader Content'), findsOneWidget);

      // Finish async Reader save; ReaderExitGuard should now pop itself.
      saveCompleter.complete(() {});
      await tester.pumpAndSettle();

      expect(poppedCalls, 1);
      expect(appNavigation.rootNavigatorKey.currentState!.canPop(), isFalse);
      expect(find.text('Reader Content'), findsNothing);
      expect(find.text('Comic:example_source:42'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'warm AuthPage over ReaderExitGuard defers dismissal and reveals ComicPage after unlock',
    (tester) async {
      final mainKey = GlobalKey<NavigatorState>();
      appNavigation.mainNavigatorKey = mainKey;

      var systemPopCalls = 0;
      _mockAuthChannels(tester, () => systemPopCalls++);

      await tester.pumpWidget(_buildShellApp(mainKey: mainKey));

      final saveCompleter = Completer<void Function()>();
      var readerPrepareCalls = 0;
      var readerPoppedCalls = 0;
      appNavigation.rootContext.to(
        () => ReaderExitGuard(
          prepare: () {
            readerPrepareCalls++;
            return saveCompleter.future;
          },
          holdForLeave: () => () {},
          onError: (error, stack) => fail('Unexpected reader error: $error'),
          onPopped: () => readerPoppedCalls++,
          waitingDelay: const Duration(milliseconds: 200),
          child: const Scaffold(body: Center(child: Text('Reader Under Lock'))),
        ),
      );
      await tester.pumpAndSettle();

      final releaseOuterLock = appNavigation.acquireAuthLock();
      unawaited(
        appNavigation.rootContext
            .to(
              () => AuthPage(
                onSuccessfulAuth: () => appNavigation.rootContext.pop(),
              ),
            )
            .whenComplete(releaseOuterLock),
      );
      await tester.pumpAndSettle();

      final handled = await handleAppLink(
        Uri.parse('https://example.test/comic/77'),
        comicPageBuilder: _fakeComicPage,
      );
      await tester.pumpAndSettle();

      expect(handled, isTrue);
      expect(systemPopCalls, 0);
      expect(readerPrepareCalls, 0);
      expect(readerPoppedCalls, 0);
      expect(appNavigation.isAuthActive, isTrue);
      expect(find.byType(AuthPage), findsOneWidget);
      expect(mainKey.currentState!.canPop(), isFalse);

      // Unlock AuthPage: once AuthPage is dismissed, ReaderExitGuard runs its
      // async save-and-leave flow and reveals the linked ComicPage on top.
      final unlock = tester
          .widget<AuthPage>(find.byType(AuthPage))
          .onSuccessfulAuth;
      unlock!.call();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(appNavigation.isAuthActive, isFalse);
      expect(find.byType(AuthPage), findsNothing);
      expect(readerPrepareCalls, 1);
      expect(find.text('Reader Under Lock'), findsOneWidget);

      saveCompleter.complete(() {});
      await tester.pumpAndSettle();

      expect(readerPoppedCalls, 1);
      expect(appNavigation.rootNavigatorKey.currentState!.canPop(), isFalse);
      expect(find.text('Reader Under Lock'), findsNothing);
      expect(find.text('Comic:example_source:77'), findsOneWidget);
      expect(systemPopCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'never pops AuthPage or triggers SystemNavigator.pop when app lock is active',
    (tester) async {
      final mainKey = GlobalKey<NavigatorState>();
      appNavigation.mainNavigatorKey = mainKey;

      var systemPopCalls = 0;
      _mockAuthChannels(tester, () => systemPopCalls++);

      await tester.pumpWidget(_buildShellApp(mainKey: mainKey));

      appNavigation.rootContext.to(
        () => AuthPage(
          onSuccessfulAuth: () {
            appNavigation.rootContext.pop();
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(appNavigation.isAuthActive, isTrue);
      expect(find.byType(AuthPage), findsOneWidget);

      final handled = await handleAppLink(
        Uri.parse('https://example.test/comic/99'),
        comicPageBuilder: _fakeComicPage,
      );
      await tester.pumpAndSettle();

      expect(handled, isTrue);
      expect(systemPopCalls, 0);
      expect(appNavigation.isAuthActive, isTrue);
      expect(appNavigation.rootNavigatorKey.currentState!.canPop(), isTrue);
      expect(find.byType(AuthPage), findsOneWidget);
      expect(mainKey.currentState!.canPop(), isFalse);

      // Once the user unlocks AuthPage, the deferred deep link opens.
      final unlock = tester
          .widget<AuthPage>(find.byType(AuthPage))
          .onSuccessfulAuth;
      unlock!.call();
      await tester.pumpAndSettle();

      expect(appNavigation.isAuthActive, isFalse);
      expect(find.byType(AuthPage), findsNothing);
      expect(find.text('Comic:example_source:99'), findsOneWidget);
      expect(systemPopCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cold-start AuthPage home retains deep link past 200ms and opens ComicPage after unlock',
    (tester) async {
      final mainKey = GlobalKey<NavigatorState>();
      appNavigation.mainNavigatorKey = null;

      var systemPopCalls = 0;
      _mockAuthChannels(tester, () => systemPopCalls++);

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: appNavigation.rootNavigatorKey,
          home: AuthPage(
            onSuccessfulAuth: () {
              appNavigation.rootContext.toReplacement(
                () => _FakeMainShell(mainKey: mainKey),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(appNavigation.isAuthActive, isTrue);
      expect(appNavigation.mainNavigatorKey, isNull);

      final handled = await handleAppLink(
        Uri.parse('https://example.test/comic/101'),
        comicPageBuilder: _fakeComicPage,
      );
      await tester.pump(const Duration(milliseconds: 500));

      expect(handled, isTrue);
      expect(systemPopCalls, 0);
      expect(find.byType(AuthPage), findsOneWidget);
      expect(find.text('Comic:example_source:101'), findsNothing);

      final unlock = tester
          .widget<AuthPage>(find.byType(AuthPage))
          .onSuccessfulAuth;
      unlock!.call();
      await tester.pumpAndSettle();

      expect(appNavigation.isAuthActive, isFalse);
      expect(appNavigation.mainNavigatorKey, same(mainKey));
      expect(find.byType(AuthPage), findsNothing);
      expect(find.text('Comic:example_source:101'), findsOneWidget);
      expect(systemPopCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'multiple links and shares while locked keep only the latest intent',
    (tester) async {
      final mainKey = GlobalKey<NavigatorState>();
      appNavigation.mainNavigatorKey = mainKey;

      var systemPopCalls = 0;
      _mockAuthChannels(tester, () => systemPopCalls++);

      await tester.pumpWidget(_buildShellApp(mainKey: mainKey));

      appNavigation.rootContext.to(
        () => AuthPage(onSuccessfulAuth: () => appNavigation.rootContext.pop()),
      );
      await tester.pumpAndSettle();

      await handleAppLink(
        Uri.parse('https://example.test/comic/1'),
        comicPageBuilder: _fakeComicPage,
      );
      handleTextShare('stale query', searchPageBuilder: _fakeSearchPage);
      await handleAppLink(
        Uri.parse('https://example.test/comic/2'),
        comicPageBuilder: _fakeComicPage,
      );
      await tester.pumpAndSettle();

      final unlock = tester
          .widget<AuthPage>(find.byType(AuthPage))
          .onSuccessfulAuth;
      unlock!.call();
      await tester.pumpAndSettle();

      expect(find.text('Comic:example_source:1'), findsNothing);
      expect(find.text('Search:stale query'), findsNothing);
      expect(find.text('Comic:example_source:2'), findsOneWidget);

      // Re-lock and verify a newer text share supersedes an older deep link.
      appNavigation.rootContext.to(
        () => AuthPage(onSuccessfulAuth: () => appNavigation.rootContext.pop()),
      );
      await tester.pumpAndSettle();

      await handleAppLink(
        Uri.parse('https://example.test/comic/3'),
        comicPageBuilder: _fakeComicPage,
      );
      handleTextShare('latest query', searchPageBuilder: _fakeSearchPage);
      await tester.pumpAndSettle();

      final unlockSecond = tester
          .widget<AuthPage>(find.byType(AuthPage))
          .onSuccessfulAuth;
      unlockSecond!.call();
      await tester.pumpAndSettle();

      expect(find.text('Comic:example_source:3'), findsNothing);
      expect(find.text('Search:latest query'), findsOneWidget);
      expect(systemPopCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cancelled link subscription before unlock skips deferred navigation and does not hang exit or dispose',
    (tester) async {
      final mainKey = GlobalKey<NavigatorState>();
      appNavigation.mainNavigatorKey = mainKey;

      var systemPopCalls = 0;
      _mockAuthChannels(tester, () => systemPopCalls++);

      await tester.pumpWidget(_buildShellApp(mainKey: mainKey));

      appNavigation.rootContext.to(
        () => AuthPage(onSuccessfulAuth: () => appNavigation.rootContext.pop()),
      );
      await tester.pumpAndSettle();

      final controller = StreamController<Uri>.broadcast();
      addTearDown(controller.close);
      final subscription = EventSubscription<Uri>(
        events: controller.stream,
        handle: (uri, isActive) async {
          await handleAppLink(
            uri,
            isActive: isActive,
            comicPageBuilder: _fakeComicPage,
          );
        },
        onError: (error, stack) => fail('Unexpected app link error: $error'),
      )..start();

      controller.add(Uri.parse('https://example.test/comic/201'));
      await tester.pump();

      final releaseExit = await tester.runAsync(
        () => subscription.prepareForExit().timeout(const Duration(seconds: 1)),
      );
      releaseExit!();

      controller.add(Uri.parse('https://example.test/comic/202'));
      await tester.pump();
      await tester.runAsync(
        () => subscription.dispose().timeout(const Duration(seconds: 1)),
      );

      final unlock = tester
          .widget<AuthPage>(find.byType(AuthPage))
          .onSuccessfulAuth;
      unlock!.call();
      await tester.pumpAndSettle();

      expect(appNavigation.isAuthActive, isFalse);
      expect(find.byType(AuthPage), findsNothing);
      expect(find.text('Comic:example_source:201'), findsNothing);
      expect(find.text('Comic:example_source:202'), findsNothing);
      expect(mainKey.currentState!.canPop(), isFalse);
      expect(find.text('Main Home'), findsOneWidget);
      expect(systemPopCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'terminates cleanly without looping when a root route refuses pop',
    (tester) async {
      final mainKey = GlobalKey<NavigatorState>();
      appNavigation.mainNavigatorKey = mainKey;
      await tester.pumpWidget(_buildShellApp(mainKey: mainKey));

      var popInvocations = 0;
      appNavigation.rootContext.to(
        () => PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) popInvocations++;
          },
          child: const Scaffold(body: Center(child: Text('Refusing Route'))),
        ),
      );
      await tester.pumpAndSettle();

      final handled = await handleAppLink(
        Uri.parse('https://example.test/comic/7'),
        comicPageBuilder: _fakeComicPage,
      );
      await tester.pumpAndSettle();

      expect(handled, isTrue);
      expect(popInvocations, 1);
      expect(find.text('Refusing Route'), findsOneWidget);
      expect(appNavigation.rootNavigatorKey.currentState!.canPop(), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'aborts safely without pushing when isActive becomes false before cold-start readiness',
    (tester) async {
      final mainKey = GlobalKey<NavigatorState>();
      appNavigation.mainNavigatorKey = null;
      await tester.pumpWidget(_buildShellApp(mainKey: mainKey));

      var active = true;
      final handled = await handleAppLink(
        Uri.parse('https://example.test/comic/13'),
        isActive: () => active,
        comicPageBuilder: _fakeComicPage,
      );

      // Deactivating before readiness prevents the deferred navigation from running.
      active = false;
      appNavigation.mainNavigatorKey = mainKey;
      await tester.pumpAndSettle();

      expect(handled, isTrue);
      expect(find.text('Comic:example_source:13'), findsNothing);
      expect(find.text('Main Home'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'aborts safely without pushing when isActive becomes false during root dismissal',
    (tester) async {
      final mainKey = GlobalKey<NavigatorState>();
      appNavigation.mainNavigatorKey = mainKey;
      await tester.pumpWidget(_buildShellApp(mainKey: mainKey));

      var active = true;
      appNavigation.rootContext.to(
        () => PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              active = false;
            }
          },
          child: const Scaffold(body: Center(child: Text('Guarded Route'))),
        ),
      );
      await tester.pumpAndSettle();

      final handled = await handleAppLink(
        Uri.parse('https://example.test/comic/55'),
        isActive: () => active,
        comicPageBuilder: _fakeComicPage,
      );
      await tester.pumpAndSettle();

      expect(handled, isFalse);
      expect(mainKey.currentState!.canPop(), isFalse);
      expect(find.text('Comic:example_source:55'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('respects NavigationAdmission when navigation is blocked', (
    tester,
  ) async {
    final mainKey = GlobalKey<NavigatorState>();
    appNavigation.mainNavigatorKey = mainKey;
    var allows = true;
    await tester.pumpWidget(
      _buildShellApp(mainKey: mainKey, allowsNavigation: () => allows),
    );

    appNavigation.rootContext.to(
      () => const Scaffold(body: Center(child: Text('Open Overlay'))),
    );
    await tester.pumpAndSettle();

    allows = false;
    final handled = await handleAppLink(
      Uri.parse('https://example.test/comic/88'),
      comicPageBuilder: _fakeComicPage,
    );
    await tester.pumpAndSettle();

    expect(handled, isTrue);
    expect(find.text('Open Overlay'), findsOneWidget);
    expect(mainKey.currentState!.canPop(), isFalse);
    expect(tester.takeException(), isNull);
  });
}
