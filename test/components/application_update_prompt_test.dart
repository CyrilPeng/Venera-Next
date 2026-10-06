import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/application_update_prompt.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/features/settings/about.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/application_update_service.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/app_dio.dart';
import 'package:window_manager/window_manager.dart';

import '../support/application_update_adapter.dart';

void main() {
  setUpAll(() async {
    final fontPath = Platform.environment['APP_UPDATE_QA_FONT'];
    if (fontPath != null) {
      final loader = FontLoader('AppUpdateQA')
        ..addFont(File(fontPath).readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
  });
  late ApplicationUpdateAdapter adapter;
  late ApplicationUpdateService service;
  late List<String> messages;
  setUp(() {
    App.version = '1.0.0';
    Log.isMuted = true;
    messages = [];
    registerShowMessageHandler((_, message) => messages.add(message));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (_) async => false,
        );
  });
  tearDown(() {
    registerShowMessageHandler((_, _) {});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  void testUpdateWidgets(
    String name,
    Future<void> Function(WidgetTester) body,
  ) {
    testWidgets(name, (tester) async {
      adapter = ApplicationUpdateAdapter();
      service = ApplicationUpdateService(
        createClient: () => Dio()..httpClientAdapter = adapter,
        currentVersion: () => '1.0.0',
      );
      try {
        await body(tester);
      } finally {
        if (!adapter.released.isCompleted) adapter.released.complete();
        final closing = service.closeAndWait();
        await tester.pumpAndSettle();
        await closing;
        await tester.pumpWidget(const SizedBox());
      }
    });
  }

  Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 100 && !ready(); i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(ready(), isTrue);
  }

  Widget app(
    Widget child, {
    GlobalKey<NavigatorState>? navigatorKey,
    VoidCallback? onExit,
    Brightness brightness = Brightness.light,
    double textScale = 1,
  }) => MaterialApp(
    navigatorKey: navigatorKey,
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: brightness,
      fontFamily: Platform.environment['APP_UPDATE_QA_FONT'] == null
          ? null
          : 'AppUpdateQA',
    ),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: ApplicationUpdateScope(
        service: service,
        child: WindowFrame(child!, onExit: onExit ?? () {}),
      ),
    ),
    home: Scaffold(body: child),
  );

  void closeWindow(WidgetTester tester) =>
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();

  testUpdateWidgets(
    'about page disposal cancels its request and never sets state or shows late UI',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(app(const Text('Home'), navigatorKey: navigator));
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: AboutSettings()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Check'));
      await tester.pump();
      await waitFor(tester, () => adapter.entered.isCompleted);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(adapter.draining.isCompleted, isTrue);
      adapter.released.complete();
      await tester.pumpAndSettle();
      expect(messages, isEmpty);
      expect(find.text('New version available'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testUpdateWidgets(
    'a covered about page cannot display a late dialog over its successor',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        app(const AboutSettings(), navigatorKey: navigator),
      );
      await tester.tap(find.text('Check'));
      await tester.pump();
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Successor')),
          ),
        ),
      );
      await waitFor(tester, () => adapter.entered.isCompleted);
      adapter.complete({'tag_name': 'v2.0.0'});
      adapter.released.complete();
      await tester.pumpAndSettle();
      expect(find.text('Successor'), findsOneWidget);
      expect(find.text('New version available'), findsNothing);
      expect(messages, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testUpdateWidgets('window cancellation waits native cleanup before exiting', (
    tester,
  ) async {
    var exited = false;
    await tester.pumpWidget(
      app(const AboutSettings(), onExit: () => exited = true),
    );
    await tester.tap(find.text('Check'));
    await tester.pump();
    await waitFor(tester, () => adapter.entered.isCompleted);
    closeWindow(tester);
    await tester.pump();
    expect(adapter.draining.isCompleted, isTrue);
    expect(exited, isFalse);
    adapter.released.complete();
    await tester.pumpAndSettle();
    expect(exited, isTrue);
    expect(messages, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testUpdateWidgets(
    'shutdown cancels the startup display delay without waiting for its timer',
    (tester) async {
      late BuildContext context;
      var exited = false;
      await tester.pumpWidget(
        app(
          Builder(
            builder: (value) {
              context = value;
              return const Text('Home');
            },
          ),
          onExit: () => exited = true,
        ),
      );
      final prompt = ApplicationUpdatePrompt(
        context: context,
        service: service,
      );
      final checking = prompt.check(
        silent: true,
        delay: const Duration(hours: 1),
      );
      expect(identical(checking, prompt.check()), isTrue);
      await tester.pump();
      await waitFor(tester, () => adapter.entered.isCompleted);
      adapter.complete({'tag_name': 'v2.0.0'});
      adapter.released.complete();
      await waitFor(tester, () => adapter.draining.isCompleted);
      await tester.pump();
      closeWindow(tester);
      await tester.pumpAndSettle();
      await checking;
      expect(exited, isTrue);
      expect(find.text('New version available'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testUpdateWidgets(
    'retiring a prompt removes only its dialog below a newer route',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      late BuildContext context;
      await tester.pumpWidget(
        app(
          Builder(
            builder: (value) {
              context = value;
              return const Text('Home');
            },
          ),
          navigatorKey: navigator,
        ),
      );
      final prompt = ApplicationUpdatePrompt(
        context: context,
        service: service,
      );
      final checking = prompt.check();
      await tester.pump();
      await waitFor(tester, () => adapter.entered.isCompleted);
      adapter.complete({'tag_name': 'v2.0.0'});
      adapter.released.complete();
      await tester.pumpAndSettle();
      expect(find.text('New version available'), findsOneWidget);
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Successor')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final closing = prompt.closeAndWait();
      await tester.pumpAndSettle();
      await Future.wait([checking, closing]);
      expect(find.text('Successor'), findsOneWidget);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('New version available'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testUpdateWidgets(
    'removing the about route while its dialog is open retires both safely',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(app(const Text('Home'), navigatorKey: navigator));
      final route = MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: AboutSettings()),
      );
      unawaited(navigator.currentState!.push(route));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Check'));
      await tester.pump();
      await waitFor(tester, () => adapter.entered.isCompleted);
      adapter.complete({'tag_name': 'v2.0.0'});
      adapter.released.complete();
      await tester.pumpAndSettle();
      expect(find.text('New version available'), findsOneWidget);
      navigator.currentState!.removeRoute(route);
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('New version available'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testUpdateWidgets(
    'manual HTTP failure shows failure instead of no update and enables retry',
    (tester) async {
      await tester.pumpWidget(app(const AboutSettings()));
      await tester.tap(find.text('Check'));
      await tester.pump();
      await waitFor(tester, () => adapter.entered.isCompleted);
      adapter.response.completeError(StateError('offline'));
      adapter.released.complete();
      await tester.pumpAndSettle();
      expect(messages, ['Failed to check for updates']);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    testUpdateWidgets(
      'large-text ${brightness.name} update dialog supports keyboard dismissal',
      (tester) async {
        tester.view.physicalSize = const Size(500, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: app(
              const AboutSettings(),
              brightness: brightness,
              textScale: 2,
            ),
          ),
        );
        await tester.tap(find.text('Check'));
        await waitFor(tester, () => adapter.entered.isCompleted);
        adapter.complete({'tag_name': 'v2.0.0'});
        adapter.released.complete();
        await tester.pumpAndSettle();
        expect(find.text('New version available'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(tester.takeException(), isNull);
        final output = Platform.environment['APP_UPDATE_QA_DIRECTORY'];
        if (output != null) {
          await tester.runAsync(() async {
            final boundary =
                key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final picture = await boundary.toImage(pixelRatio: 1);
            try {
              final bytes = await picture.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await Directory(output).create(recursive: true);
              await File(
                '$output/update-${brightness.name}.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
            } finally {
              picture.dispose();
            }
          });
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('New version available'), findsNothing);
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNotNull,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
