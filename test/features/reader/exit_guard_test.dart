import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/exit_guard.dart';
import 'package:venera_next/foundation/navigation_admission.dart';

// Rendering is opt-in and requires a real font to avoid Ahem-only QA images.
final _qaDirectory = Platform.environment['READER_EXIT_QA_DIR'];
final _qaFont = Platform.environment['READER_EXIT_QA_FONT'];

class _Harness {
  _Harness(this.prepare, {this.onError, this.holdForLeave});

  final Future<void Function()> Function() prepare;
  final void Function(Object, StackTrace)? onError;
  final void Function() Function()? holdForLeave;
  final navigator = GlobalKey<NavigatorState>();
  final guard = GlobalKey<ReaderExitGuardState>();
  final preview = GlobalKey();
  final focus = FocusNode(debugLabel: 'Reader action');
  final homeFocus = FocusNode(debugLabel: 'Home action');
  final errors = <Object>[];
  late BuildContext readerContext;
  bool parentAllowsNavigation = true;
  int clicks = 0;
  int preparations = 0;
  int leaveHolds = 0;

  Future<void> mount(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
    double textScale = 1,
    bool reduceMotion = false,
  }) async {
    addTearDown(focus.dispose);
    addTearDown(homeFocus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: ThemeData(
          brightness: brightness,
          fontFamily: _qaFont == null ? null : 'ReaderExitQA',
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: reduceMotion,
          ),
          child: NavigationAdmission(
            allowsNavigation: () => parentAllowsNavigation,
            child: RepaintBoundary(key: preview, child: child!),
          ),
        ),
        home: Scaffold(
          body: TextButton(
            focusNode: homeFocus,
            autofocus: true,
            onPressed: () {},
            child: const Text('Home'),
          ),
        ),
      ),
    );
    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => ReaderExitGuard(
            key: guard,
            prepare: () {
              preparations++;
              return prepare();
            },
            holdForLeave: () {
              leaveHolds++;
              return holdForLeave?.call() ?? () {};
            },
            onError: (error, stack) {
              errors.add(error);
              onError?.call(error, stack);
            },
            child: Builder(
              builder: (context) {
                readerContext = context;
                return Scaffold(
                  body: Center(
                    child: TextButton(
                      key: const Key('reader action'),
                      focusNode: focus,
                      autofocus: true,
                      onPressed: () => clicks++,
                      child: const Text('Reader action'),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    focus.requestFocus();
    await tester.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (_qaDirectory != null && _qaFont == null) {
      throw StateError('READER_EXIT_QA_FONT is required when rendering PNGs');
    }
    final fontPath = _qaFont;
    if (fontPath != null) {
      final font = FontLoader('ReaderExitQA')
        ..addFont(File(fontPath).readAsBytes().then(ByteData.sublistView));
      await font.load();
    }
  });
  testWidgets(
    'saving freezes input, semantics and navigation until route removal',
    (tester) async {
      final ready = Completer<void Function()>();
      var releases = 0;
      final harness = _Harness(() => ready.future);
      await harness.mount(tester);
      final semantics = tester.ensureSemantics();
      try {
        expect(harness.focus.hasPrimaryFocus, isTrue);
        final pointer = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('reader action'))),
        );
        final state = harness.guard.currentState!;
        final closing = state.requestExit();
        expect(identical(state.requestExit(), closing), isTrue);
        expect(NavigationAdmission.allows(harness.readerContext), isFalse);
        expect(harness.focus.canRequestFocus, isFalse);
        await tester.pump();
        expect(find.text('Saving...'), findsOneWidget);
        expect(
          tester
              .binding
              .renderViews
              .single
              .owner!
              .semanticsOwner!
              .rootSemanticsNode!
              .toStringDeep(),
          isNot(contains('Reader action')),
        );
        expect(
          tester
              .getSemantics(find.text('Saving...'))
              .flagsCollection
              .isLiveRegion,
          isTrue,
        );
        await pointer.up();
        await tester.tap(
          find.byKey(const Key('reader action')),
          warnIfMissed: false,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await harness.navigator.currentState!.maybePop();
        await tester.pump();
        expect(harness.clicks, 0);
        expect(harness.preparations, 1);
        expect(find.byType(ReaderExitGuard), findsOneWidget);
        ready.complete(() => releases++);
        await closing;
        expect(releases, 0);
        await tester.pumpAndSettle();
        expect(find.byType(ReaderExitGuard), findsNothing);
        expect(find.text('Home'), findsOneWidget);
        expect(releases, 1);
        expect(harness.homeFocus.hasPrimaryFocus, isTrue);
        expect(harness.errors, isEmpty);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('failed save restores the same focus and allows a fresh retry', (
    tester,
  ) async {
    final first = Completer<void Function()>();
    final second = Completer<void Function()>();
    var attempt = 0;
    var releases = 0;
    final error = StateError('save failed');
    final harness = _Harness(
      () => attempt++ == 0 ? first.future : second.future,
    );
    await harness.mount(tester);
    final closing = harness.guard.currentState!.requestExit();
    await tester.pump();
    first.completeError(error);
    await closing;
    await tester.pump();
    expect(harness.errors, [same(error)]);
    expect(find.text('Saving...'), findsNothing);
    expect(find.byType(ReaderExitGuard), findsOneWidget);
    expect(harness.focus.hasPrimaryFocus, isTrue);
    expect(NavigationAdmission.allows(harness.readerContext), isTrue);
    await tester.tap(find.byKey(const Key('reader action')));
    expect(harness.clicks, 1);
    final retried = harness.guard.currentState!.requestExit();
    expect(identical(closing, retried), isFalse);
    expect(harness.preparations, 2);
    second.complete(() => releases++);
    await retried;
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(releases, 1);
  });

  testWidgets('leaving without saving requires an explicit completed failure', (
    tester,
  ) async {
    final ready = Completer<void Function()>();
    final harness = _Harness(() => ready.future);
    await harness.mount(tester);
    final state = harness.guard.currentState!;
    state.leaveWithoutSaving();
    await tester.pump();
    expect(find.byType(ReaderExitGuard), findsOneWidget);
    expect(harness.preparations, 0);
    expect(harness.leaveHolds, 0);
    final closing = state.requestExit();
    state.leaveWithoutSaving();
    await tester.pump();
    expect(find.text('Saving...'), findsOneWidget);
    expect(harness.leaveHolds, 0);
    ready.completeError(StateError('unrecoverable write'));
    await closing;
    await tester.pump();
    harness.parentAllowsNavigation = false;
    state.leaveWithoutSaving();
    expect(find.byType(ReaderExitGuard), findsOneWidget);
    expect(harness.leaveHolds, 0);
    harness.parentAllowsNavigation = true;
    state.leaveWithoutSaving();
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(harness.preparations, 1);
    expect(harness.leaveHolds, 1);
    expect(harness.errors, hasLength(1));
  });

  testWidgets('the explicit failure escape cannot pop a covering route', (
    tester,
  ) async {
    final harness = _Harness(() => Future.error(StateError('save failed')));
    await harness.mount(tester);
    final state = harness.guard.currentState!;
    await state.requestExit();
    await tester.pump();
    unawaited(
      harness.navigator.currentState!.push<void>(
        MaterialPageRoute(builder: (_) => const Scaffold(body: Text('Cover'))),
      ),
    );
    await tester.pumpAndSettle();
    state.leaveWithoutSaving();
    await tester.pump();
    expect(find.text('Cover'), findsOneWidget);
    expect(harness.leaveHolds, 0);
    harness.navigator.currentState!.pop();
    await tester.pumpAndSettle();
    state.leaveWithoutSaving();
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(harness.preparations, 1);
    expect(harness.leaveHolds, 1);
  });

  testWidgets('explicit leave holds the session through the pop animation', (
    tester,
  ) async {
    var held = false;
    var releases = 0;
    late _Harness harness;
    harness = _Harness(
      () => Future.error(StateError('unrecoverable save')),
      holdForLeave: () {
        expect(ModalRoute.of(harness.readerContext)!.isCurrent, isTrue);
        expect(NavigationAdmission.allows(harness.readerContext), isFalse);
        held = true;
        return () {
          held = false;
          releases++;
        };
      },
    );
    await harness.mount(tester);
    final state = harness.guard.currentState!;
    await state.requestExit();
    await tester.pump();
    state.leaveWithoutSaving();
    expect(held, isTrue);
    expect(releases, 0);
    expect(harness.leaveHolds, 1);
    await tester.pump(const Duration(milliseconds: 100));
    expect(harness.guard.currentState, isNotNull);
    expect(held, isTrue);
    state.leaveWithoutSaving();
    await state.requestExit();
    expect(harness.leaveHolds, 1);
    expect(harness.preparations, 1);
    expect(releases, 0);
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(held, isFalse);
    expect(releases, 1);
  });

  testWidgets('failed leave hold is reported and leaves the reader retryable', (
    tester,
  ) async {
    final holdError = StateError('hold failed');
    var failHold = true;
    var releases = 0;
    final harness = _Harness(
      () => Future.error(StateError('save failed')),
      holdForLeave: () {
        if (failHold) throw holdError;
        return () => releases++;
      },
    );
    await harness.mount(tester);
    final state = harness.guard.currentState!;
    await state.requestExit();
    await tester.pump();
    state.leaveWithoutSaving();
    await tester.pump();
    expect(harness.errors.last, same(holdError));
    expect(harness.errors, hasLength(2));
    expect(find.byType(ReaderExitGuard), findsOneWidget);
    expect(NavigationAdmission.allows(harness.readerContext), isTrue);
    expect(harness.focus.hasPrimaryFocus, isTrue);
    expect(find.text('Saving...'), findsNothing);
    failHold = false;
    state.leaveWithoutSaving();
    await tester.pumpAndSettle();
    expect(harness.preparations, 1);
    expect(harness.leaveHolds, 2);
    expect(releases, 1);
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('a pop consumed by local history releases the leave hold', (
    tester,
  ) async {
    var releases = 0;
    final harness = _Harness(
      () => Future.error(StateError('save failed')),
      holdForLeave: () =>
          () => releases++,
    );
    await harness.mount(tester);
    final state = harness.guard.currentState!;
    await state.requestExit();
    await tester.pump();
    ModalRoute.of(
      harness.readerContext,
    )!.addLocalHistoryEntry(LocalHistoryEntry());
    state.leaveWithoutSaving();
    await tester.pump();
    expect(releases, 1);
    expect(find.byType(ReaderExitGuard), findsOneWidget);
    expect(NavigationAdmission.allows(harness.readerContext), isTrue);
    expect(harness.focus.hasPrimaryFocus, isTrue);
    state.leaveWithoutSaving();
    expect(releases, 1);
    await tester.pumpAndSettle();
    expect(releases, 2);
    expect(harness.preparations, 1);
    expect(find.text('Home'), findsOneWidget);
  });

  for (final keyboard in [false, true]) {
    testWidgets('${keyboard ? 'Escape' : 'system back'} waits for saving', (
      tester,
    ) async {
      final ready = Completer<void Function()>();
      final harness = _Harness(() => ready.future);
      await harness.mount(tester);
      if (keyboard) {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      } else {
        await tester.binding.handlePopRoute();
      }
      await tester.pump();
      expect(harness.preparations, 1);
      expect(find.text('Saving...'), findsOneWidget);
      expect(find.byType(ReaderExitGuard), findsOneWidget);
      ready.complete(() {});
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
    });
  }

  testWidgets(
    'a covering route is never popped or given the old reader focus',
    (tester) async {
      final ready = Completer<void Function()>();
      var releases = 0;
      final harness = _Harness(() => ready.future);
      final coverFocus = FocusNode();
      addTearDown(coverFocus.dispose);
      await harness.mount(tester);
      final closing = harness.guard.currentState!.requestExit();
      await tester.pump();
      unawaited(
        harness.navigator.currentState!.push<void>(
          MaterialPageRoute(
            builder: (_) => Scaffold(
              body: TextButton(
                focusNode: coverFocus,
                autofocus: true,
                onPressed: () {},
                child: const Text('Cover'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(coverFocus.hasPrimaryFocus, isTrue);
      ready.complete(() => releases++);
      await closing;
      await tester.pump();
      expect(find.text('Cover'), findsOneWidget);
      expect(coverFocus.hasPrimaryFocus, isTrue);
      expect(harness.focus.hasFocus, isFalse);
      expect(releases, 1);
      harness.navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.byType(ReaderExitGuard), findsOneWidget);
      expect(find.text('Saving...'), findsNothing);
      expect(NavigationAdmission.allows(harness.readerContext), isTrue);
    },
  );

  testWidgets(
    'replacement releases a late hold without touching the new route',
    (tester) async {
      final ready = Completer<void Function()>();
      var releases = 0;
      final harness = _Harness(() => ready.future);
      final replacementFocus = FocusNode();
      addTearDown(replacementFocus.dispose);
      await harness.mount(tester);
      final closing = harness.guard.currentState!.requestExit();
      await tester.pump();
      unawaited(
        harness.navigator.currentState!.pushReplacement<void, void>(
          MaterialPageRoute(
            builder: (_) => Scaffold(
              body: TextButton(
                focusNode: replacementFocus,
                autofocus: true,
                onPressed: () {},
                child: const Text('Replacement'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(harness.guard.currentState, isNull);
      ready.complete(() => releases++);
      await closing;
      await tester.pump();
      expect(releases, 1);
      expect(find.text('Replacement'), findsOneWidget);
      expect(replacementFocus.hasPrimaryFocus, isTrue);
      expect(harness.errors, isEmpty);
    },
  );

  testWidgets(
    'ancestor admission remains authoritative before and during save',
    (tester) async {
      final ready = Completer<void Function()>();
      var releases = 0;
      final harness = _Harness(() => ready.future);
      await harness.mount(tester);
      harness.parentAllowsNavigation = false;
      expect(NavigationAdmission.allows(harness.readerContext), isFalse);
      await harness.guard.currentState!.requestExit();
      expect(harness.preparations, 0);
      harness.parentAllowsNavigation = true;
      final closing = harness.guard.currentState!.requestExit();
      await tester.pump();
      harness.parentAllowsNavigation = false;
      ready.complete(() => releases++);
      await closing;
      await tester.pump();
      expect(find.byType(ReaderExitGuard), findsOneWidget);
      expect(find.text('Saving...'), findsNothing);
      expect(NavigationAdmission.allows(harness.readerContext), isFalse);
      expect(releases, 1);
      harness.parentAllowsNavigation = true;
      expect(NavigationAdmission.allows(harness.readerContext), isTrue);
    },
  );

  testWidgets('a throwing error reporter cannot leave the reader frozen', (
    tester,
  ) async {
    final ready = Completer<void Function()>();
    final reportingError = StateError('toast failed');
    final saveError = StateError('save failed');
    final harness = _Harness(
      () => ready.future,
      onError: (_, _) => throw reportingError,
    );
    await harness.mount(tester);
    final reported = <Object>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      reported.add(details.exception);
      throw StateError('diagnostics also failed');
    };
    try {
      final closing = harness.guard.currentState!.requestExit();
      await tester.pump();
      ready.completeError(saveError);
      await closing;
      await tester.pump();
      expect(reported, [same(reportingError), same(saveError)]);
      expect(harness.focus.hasPrimaryFocus, isTrue);
      expect(NavigationAdmission.allows(harness.readerContext), isTrue);
      expect(find.text('Saving...'), findsNothing);
    } finally {
      FlutterError.onError = previous;
    }
  });

  testWidgets(
    'late failure after removal does not call the disposed UI reporter',
    (tester) async {
      final ready = Completer<void Function()>();
      final harness = _Harness(() => ready.future);
      await harness.mount(tester);
      final closing = harness.guard.currentState!.requestExit();
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: Text('Replacement')));
      final reported = <Object>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (details) => reported.add(details.exception);
      try {
        final error = StateError('late save failure');
        ready.completeError(error);
        await closing;
        await tester.pump();
        expect(reported, [same(error)]);
        expect(harness.errors, isEmpty);
        expect(find.text('Replacement'), findsOneWidget);
      } finally {
        FlutterError.onError = previous;
      }
    },
  );

  for (final size in [
    const Size(375, 700),
    const Size(500, 800),
    const Size(700, 375),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'saving fits ${size.width}x${size.height} px in $brightness with large text',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          final ready = Completer<void Function()>();
          final harness = _Harness(() => ready.future);
          await harness.mount(
            tester,
            brightness: brightness,
            textScale: 3.2,
            reduceMotion: true,
          );
          final closing = harness.guard.currentState!.requestExit();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          expect(tester.takeException(), isNull);
          expect(find.text('Saving...'), findsOneWidget);
          final progress = tester.element(find.byType(LinearProgressIndicator));
          expect(TickerMode.valuesOf(progress).enabled, isFalse);
          expect(tester.binding.transientCallbackCount, 0);
          final directory = _qaDirectory;
          if (directory != null) {
            await tester.runAsync(() async {
              final output = Directory(directory);
              await output.create(recursive: true);
              final boundary =
                  harness.preview.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await boundary.toImage(pixelRatio: 1);
              try {
                final data = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                await File(
                  '${output.path}/saving-${size.width.toInt()}x${size.height.toInt()}'
                  '-${brightness.name}-text-3.2.png',
                ).writeAsBytes(data!.buffer.asUint8List());
              } finally {
                image.dispose();
              }
            });
          }
          ready.completeError(StateError('test recovery'));
          await closing;
          await tester.pumpAndSettle();
        },
      );
    }
  }
}
