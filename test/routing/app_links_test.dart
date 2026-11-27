import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_shell/app_shell.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/reader/exit_guard.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/routing/app_links.dart';
import 'package:venera_next/routing/app_navigation.dart';

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

void main() {
  late ComicSource source;
  GlobalKey<NavigatorState>? previousMainKey;

  setUp(() {
    previousMainKey = appNavigation.mainNavigatorKey;
    source = _createLinkSource();
    configureComicSourceRegistry(
      all: () => [source],
      find: (key) => key == source.key ? source : null,
      fromIntKey: (key) => key == source.key.hashCode ? source : null,
      isEmpty: () => false,
    );
  });

  tearDown(() {
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
    'never pops AuthPage or triggers ReaderExitGuard when AuthPage locks over Reader',
    (tester) async {
      final mainKey = GlobalKey<NavigatorState>();
      appNavigation.mainNavigatorKey = mainKey;

      var systemPopCalls = 0;
      const localAuthChannel = MethodChannel('plugins.flutter.io/local_auth');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemNavigator.pop') {
            systemPopCalls++;
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

      await tester.pumpWidget(_buildShellApp(mainKey: mainKey));

      var readerPrepareCalls = 0;
      appNavigation.rootContext.to(
        () => ReaderExitGuard(
          prepare: () async {
            readerPrepareCalls++;
            return () {};
          },
          holdForLeave: () => () {},
          onError: (error, stack) => fail('Unexpected reader error: $error'),
          child: const Scaffold(body: Center(child: Text('Reader Under Lock'))),
        ),
      );
      await tester.pumpAndSettle();

      appNavigation.rootContext.to(
        () => AuthPage(onSuccessfulAuth: () => appNavigation.rootContext.pop()),
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
      expect(appNavigation.isAuthActive, isTrue);
      expect(find.byType(AuthPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'never pops AuthPage or triggers SystemNavigator.pop when app lock is active',
    (tester) async {
      final mainKey = GlobalKey<NavigatorState>();
      appNavigation.mainNavigatorKey = mainKey;

      var systemPopCalls = 0;
      const localAuthChannel = MethodChannel('plugins.flutter.io/local_auth');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemNavigator.pop') {
            systemPopCalls++;
          }
          return null;
        },
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        localAuthChannel,
        (call) async {
          if (call.method == 'isDeviceSupported' ||
              call.method == 'getAvailableBiometrics') {
            return call.method == 'isDeviceSupported' ? true : <String>[];
          }
          if (call.method == 'authenticate') {
            return false;
          }
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

      await tester.pumpWidget(_buildShellApp(mainKey: mainKey));

      VoidCallback? unlock;
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

      // Once the user unlocks AuthPage, the deep-linked comic is waiting behind it.
      unlock = tester.widget<AuthPage>(find.byType(AuthPage)).onSuccessfulAuth;
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
    'cold-start AuthPage home handles deep link safely without crashing or exiting',
    (tester) async {
      appNavigation.mainNavigatorKey = null;

      var systemPopCalls = 0;
      const localAuthChannel = MethodChannel('plugins.flutter.io/local_auth');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemNavigator.pop') {
            systemPopCalls++;
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

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: appNavigation.rootNavigatorKey,
          home: const AuthPage(),
        ),
      );
      await tester.pumpAndSettle();
      expect(appNavigation.isAuthActive, isTrue);

      final future = handleAppLink(
        Uri.parse('https://example.test/comic/101'),
        comicPageBuilder: _fakeComicPage,
      );
      await tester.pump(const Duration(milliseconds: 250));
      final handled = await future;
      await tester.pumpAndSettle();

      expect(handled, isTrue);
      expect(systemPopCalls, 0);
      expect(find.byType(AuthPage), findsOneWidget);
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
    'aborts safely without pushing when isActive becomes false during cold-start wait',
    (tester) async {
      final mainKey = GlobalKey<NavigatorState>();
      appNavigation.mainNavigatorKey = null;
      await tester.pumpWidget(_buildShellApp(mainKey: mainKey));

      var active = true;
      final future = handleAppLink(
        Uri.parse('https://example.test/comic/13'),
        isActive: () => active,
        comicPageBuilder: _fakeComicPage,
      );

      // Even if mainNavigatorKey becomes ready, deactivation mid-wait aborts.
      appNavigation.mainNavigatorKey = mainKey;
      active = false;
      await tester.pump(const Duration(milliseconds: 250));
      final handled = await future;
      await tester.pumpAndSettle();

      expect(handled, isFalse);
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
