import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_shell/app_shell.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/event_subscription.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:venera_next/routing/handle_text_share.dart';

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
  GlobalKey<NavigatorState>? previousMainKey;

  setUp(() {
    previousMainKey = appNavigation.mainNavigatorKey;
    appNavigation.clearPendingNavigation();
  });

  tearDown(() {
    appNavigation.clearPendingNavigation();
    appNavigation.mainNavigatorKey = previousMainKey;
  });

  testWidgets('text share while unlocked pushes search page immediately', (
    tester,
  ) async {
    final mainKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: appNavigation.rootNavigatorKey,
        home: _FakeMainShell(mainKey: mainKey),
      ),
    );
    await tester.pumpAndSettle();

    expect(handleTextShare(null, searchPageBuilder: _fakeSearchPage), isFalse);
    expect(handleTextShare(123, searchPageBuilder: _fakeSearchPage), isFalse);

    final handled = handleTextShare(
      'venera search',
      searchPageBuilder: _fakeSearchPage,
    );
    await tester.pumpAndSettle();

    expect(handled, isTrue);
    expect(find.text('Search:venera search'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'text share while warm AuthPage is active does not bypass lock and opens after unlock',
    (tester) async {
      final mainKey = GlobalKey<NavigatorState>();
      var systemPopCalls = 0;
      _mockAuthChannels(tester, () => systemPopCalls++);

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: appNavigation.rootNavigatorKey,
          home: _FakeMainShell(mainKey: mainKey),
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

      final handled = handleTextShare(
        'locked keyword',
        searchPageBuilder: _fakeSearchPage,
      );
      await tester.pumpAndSettle();

      expect(handled, isTrue);
      expect(systemPopCalls, 0);
      expect(appNavigation.isAuthActive, isTrue);
      expect(find.byType(AuthPage), findsOneWidget);
      expect(find.text('Search:locked keyword'), findsNothing);

      final unlock = tester
          .widget<AuthPage>(find.byType(AuthPage))
          .onSuccessfulAuth;
      unlock!.call();
      await tester.pumpAndSettle();

      expect(appNavigation.isAuthActive, isFalse);
      expect(find.byType(AuthPage), findsNothing);
      expect(find.text('Search:locked keyword'), findsOneWidget);
      expect(systemPopCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'text share on cold-start AuthPage (>200ms) stays blocked until unlock then opens search',
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

      final handled = handleTextShare(
        'cold start query',
        searchPageBuilder: _fakeSearchPage,
      );
      await tester.pump(const Duration(milliseconds: 500));

      expect(handled, isTrue);
      expect(systemPopCalls, 0);
      expect(find.byType(AuthPage), findsOneWidget);
      expect(find.text('Search:cold start query'), findsNothing);

      final unlock = tester
          .widget<AuthPage>(find.byType(AuthPage))
          .onSuccessfulAuth;
      unlock!.call();
      await tester.pumpAndSettle();

      expect(appNavigation.isAuthActive, isFalse);
      expect(appNavigation.mainNavigatorKey, same(mainKey));
      expect(find.byType(AuthPage), findsNothing);
      expect(find.text('Search:cold start query'), findsOneWidget);
      expect(systemPopCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cancelled subscription before unlock does not navigate and does not hang prepareForExit or dispose',
    (tester) async {
      final mainKey = GlobalKey<NavigatorState>();
      var systemPopCalls = 0;
      _mockAuthChannels(tester, () => systemPopCalls++);

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: appNavigation.rootNavigatorKey,
          home: _FakeMainShell(mainKey: mainKey),
        ),
      );
      await tester.pumpAndSettle();

      appNavigation.rootContext.to(
        () => AuthPage(onSuccessfulAuth: () => appNavigation.rootContext.pop()),
      );
      await tester.pumpAndSettle();

      final controller = StreamController<Object?>.broadcast();
      addTearDown(controller.close);
      final subscription = EventSubscription<Object?>(
        events: controller.stream,
        handle: (event, isActive) async {
          handleTextShare(
            event,
            isActive: isActive,
            searchPageBuilder: _fakeSearchPage,
          );
        },
        onError: (error, stack) => fail('Unexpected share error: $error'),
      )..start();

      controller.add('cancelled before unlock');
      await tester.pump();

      // prepareForExit() must complete immediately while locked (no hang).
      final releaseExit = await tester.runAsync(
        () => subscription.prepareForExit().timeout(const Duration(seconds: 1)),
      );
      releaseExit!();

      // A second share followed by dispose() must also complete immediately.
      controller.add('disposed before unlock');
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
      expect(find.text('Search:cancelled before unlock'), findsNothing);
      expect(find.text('Search:disposed before unlock'), findsNothing);
      expect(find.text('Main Home'), findsOneWidget);
      expect(systemPopCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
