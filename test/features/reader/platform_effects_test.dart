import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/platform_effects.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/selection_operation.dart';

const _portrait = [
  'DeviceOrientation.portraitUp',
  'DeviceOrientation.portraitDown',
];
const _landscape = [
  'DeviceOrientation.landscapeLeft',
  'DeviceOrientation.landscapeRight',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final android = TargetPlatformVariant.only(TargetPlatform.android);
  late List<List<String>> orientationRequests;

  setUp(() {
    orientationRequests = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'SystemChrome.setPreferredOrientations') {
            orientationRequests.add(List<String>.from(call.arguments as List));
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets(
    'application default policy is owned before any reader exists',
    (tester) async {
      final registry = SelectionTaskRegistry();
      final acknowledgement = Completer<void>();
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            calls.add(call.method);
            await acknowledgement.future;
            return null;
          });
      try {
        await tester.pumpWidget(
          SelectionTasksScope(
            registry: registry,
            child: const ReaderPlatformEffectsScope(child: SizedBox()),
          ),
        );
        expect(
          calls,
          containsAll([
            'SystemChrome.setPreferredOrientations',
            'SystemChrome.setEnabledSystemUIMode',
          ]),
        );
        await tester.pumpWidget(const SizedBox());
        var closed = false;
        final closing = registry.closeAndWait().then((_) => closed = true);
        await tester.pump();
        expect(closed, isFalse);
        acknowledgement.complete();
        await tester.pump();
        expect(closed, isTrue);
        await closing;
        expect(calls, hasLength(2));
      } finally {
        if (!acknowledgement.isCompleted) acknowledgement.complete();
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }
    },
    variant: android,
  );

  testWidgets(
    'scope replacement waits for old native restore without overwriting new reader',
    (tester) async {
      final restoration = Completer<void>();
      var holdRestore = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'SystemChrome.setPreferredOrientations') {
              final value = List<String>.from(call.arguments as List);
              orientationRequests.add(value);
              if (holdRestore && value.isEmpty) await restoration.future;
            }
            return null;
          });
      try {
        await _openReader(tester);
        await tester.tap(find.text('Rotate'));
        await tester.pump();
        holdRestore = true;
        await tester.pumpWidget(const SizedBox());
        final nextKey = GlobalKey<_TestReaderState>();
        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) => ReaderPlatformEffectsScope(child: child!),
            home: _TestReader(key: nextKey),
          ),
        );
        nextKey.currentState!.cycleReaderOrientation();
        nextKey.currentState!.cycleReaderOrientation();
        await tester.pump();
        expect(orientationRequests.last, isEmpty);
        restoration.complete();
        await tester.pump();
        expect(orientationRequests.last, _landscape);
        expect(find.text('landscape'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        if (!restoration.isCompleted) restoration.complete();
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }
    },
    variant: android,
  );

  testWidgets(
    'automatic reader orientation defers to the operating system',
    (tester) async {
      await _openReader(tester);
      expect(find.text('system'), findsOneWidget);
      expect(orientationRequests, [<String>[]]);

      await tester.tap(find.text('Rotate'));
      await tester.pump();
      expect(find.text('portrait'), findsOneWidget);

      await tester.tap(find.text('Rotate'));
      await tester.pump();
      expect(find.text('landscape'), findsOneWidget);

      await tester.tap(find.text('Rotate'));
      await tester.pump();
      expect(find.text('system'), findsOneWidget);
      expect(orientationRequests, [
        <String>[],
        _portrait,
        _landscape,
        <String>[],
      ]);

      await tester.pumpWidget(const SizedBox());
      expect(orientationRequests.last, isEmpty);
    },
    variant: android,
  );

  for (final turns in [1, 2]) {
    for (final systemBack in [false, true]) {
      testWidgets('releases ${turns == 1 ? 'portrait' : 'landscape'} lock on '
          '${systemBack ? 'system' : 'toolbar'} back and resets on reentry', (
        tester,
      ) async {
        await _openReader(tester);
        for (var i = 0; i < turns; i++) {
          await tester.tap(find.text('Rotate'));
          await tester.pump();
        }
        expect(orientationRequests.last, turns == 1 ? _portrait : _landscape);

        if (systemBack) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.byType(BackButton));
        }
        await tester.pumpAndSettle();
        expect(find.text('Open reader'), findsOneWidget);
        expect(orientationRequests.last, isEmpty);
        expect(orientationRequests.length, turns + 2);

        await tester.tap(find.text('Open reader'));
        await tester.pumpAndSettle();
        expect(find.text('system'), findsOneWidget);
        expect(orientationRequests.last, isEmpty);
        await tester.tap(find.text('Rotate'));
        await tester.pump();
        expect(find.text('portrait'), findsOneWidget);
        expect(orientationRequests.last, _portrait);

        await tester.pumpWidget(const SizedBox());
        expect(orientationRequests.last, isEmpty);
      }, variant: android);
    }
  }

  testWidgets('rebuilds and display rotation retain the reader lock', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    await _openReader(tester);
    await tester.tap(find.text('Rotate'));
    await tester.pump();

    tester.view.physicalSize = const Size(600, 1000);
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1000, 600);
    await tester.pumpAndSettle();
    expect(find.text('portrait'), findsOneWidget);
    expect(orientationRequests, [<String>[], _portrait]);

    await tester.pumpWidget(const SizedBox());
    expect(orientationRequests.last, isEmpty);
  }, variant: android);

  testWidgets('replacing a reader does not clear the new reader lock', (
    tester,
  ) async {
    await _openReader(tester);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    final nextReaderKey = GlobalKey<_TestReaderState>();
    unawaited(
      navigator.pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => _TestReader(key: nextReaderKey),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final nextReader = nextReaderKey.currentState!;
    nextReader.cycleReaderOrientation();
    await tester.pump();
    expect(orientationRequests.last, _portrait);

    await tester.pumpAndSettle();
    expect(find.text('portrait'), findsOneWidget);
    expect(orientationRequests.last, _portrait);

    await tester.pumpWidget(const SizedBox());
    expect(orientationRequests.last, isEmpty);
  }, variant: android);

  testWidgets(
    'exit drains pending rotation before restoring system policy',
    (tester) async {
      final pending = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'SystemChrome.setPreferredOrientations') {
              orientationRequests.add(
                List<String>.from(call.arguments as List),
              );
              if (orientationRequests.last.toString() == _portrait.toString()) {
                await pending.future;
              }
            }
            return null;
          });

      try {
        await _openReader(tester);
        await tester.tap(find.text('Rotate'));
        await tester.pump();
        await tester.tap(find.text('Rotate'));
        await tester.pump();
        await tester.pumpWidget(const SizedBox());
        expect(orientationRequests, [<String>[], _portrait]);
        pending.complete();
        await tester.pump();
        expect(orientationRequests, [<String>[], _portrait, <String>[]]);
        expect(orientationRequests.last, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        if (!pending.isCompleted) pending.complete();
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }
    },
    variant: android,
  );

  testWidgets(
    'returning to an existing reader restores its temporary lock',
    (tester) async {
      await _openReader(tester);
      await tester.tap(find.text('Rotate'));
      await tester.pump();
      expect(orientationRequests.last, _portrait);

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(builder: (_) => const _TestReader()),
        ),
      );
      await tester.pumpAndSettle();
      expect(orientationRequests.last, isEmpty);
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.text('Rotate'));
        await tester.pump();
      }
      expect(orientationRequests.last, _landscape);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('portrait'), findsOneWidget);
      expect(orientationRequests.last, _portrait);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Open reader'), findsOneWidget);
      expect(orientationRequests.last, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
    variant: android,
  );

  for (final platform in [TargetPlatform.iOS, TargetPlatform.windows]) {
    testWidgets(
      'does not request reader orientation on ${platform.name}',
      (tester) async {
        await _openReader(tester);
        await tester.tap(find.text('Rotate'));
        await tester.pump();
        expect(find.text('system'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        expect(orientationRequests, isEmpty);
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }
}

Future<void> _openReader(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => ReaderPlatformEffectsScope(child: child!),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const _TestReader()),
            ),
            child: const Text('Open reader'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open reader'));
  await tester.pumpAndSettle();
}

class _TestReader extends StatefulWidget {
  const _TestReader({super.key});

  @override
  State<_TestReader> createState() => _TestReaderState();
}

class _TestReaderState extends State<_TestReader> {
  ReaderPlatformEffectsBinding? effects;
  ReaderOrientation get readerOrientation => effects!.handle.orientation;
  void cycleReaderOrientation() {
    if (effects!.cycleOrientation()) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    effects ??= ReaderPlatformEffectsBinding(context);
  }

  @override
  void dispose() {
    effects?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: Column(
        children: [
          Text(readerOrientation.name),
          TextButton(
            onPressed: cycleReaderOrientation,
            child: const Text('Rotate'),
          ),
        ],
      ),
    );
  }
}
