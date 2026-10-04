import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/gesture.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/routing/page_replacement.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final fontPath = Platform.environment['WINDOW_SHUTDOWN_QA_FONT'];
    if (fontPath != null) {
      final font = FontLoader('WindowShutdownQA')
        ..addFont(File(fontPath).readAsBytes().then(ByteData.sublistView));
      await font.load();
    }
  });
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => false,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  void close(WidgetTester tester) =>
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();

  testWidgets(
    'shutdown blocks input and late navigation, then restores focus',
    (tester) async {
      final wait = Completer<void>();
      final focus = FocusNode();
      addTearDown(focus.dispose);
      var clicks = 0;
      var backs = 0;
      var exits = 0;
      late WindowFrameController frame;
      late BuildContext retained;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          builder: (_, child) => WindowFrame(
            Shortcuts(
              shortcuts: {
                const SingleActivator(LogicalKeyboardKey.escape):
                    VoidCallbackIntent(() => backs++),
              },
              child: MouseBackDetector(onTapDown: () => backs++, child: child!),
            ),
            onExit: () => exits++,
          ),
          home: const Scaffold(body: Text('Home')),
        ),
      );
      App.rootNavigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (context) {
            retained = context;
            frame = WindowFrame.of(context);
            return Scaffold(
              body: Padding(
                padding: const EdgeInsets.only(top: 60),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: TextButton(
                    key: const Key('content action'),
                    focusNode: focus,
                    onPressed: () => clicks++,
                    onLongPress: () => clicks++,
                    child: const Text('Edit library'),
                  ),
                ),
              ),
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      focus.requestFocus();
      await tester.pump();
      expect(focus.hasPrimaryFocus, isTrue);
      frame.addExitTask(() => wait.future);
      final heldPointer = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('content action'))),
      );
      close(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await heldPointer.up();
      expect(clicks, 0);
      expect(focus.hasFocus, isFalse);
      expect(find.text('Closing...'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('content action')),
        warnIfMissed: false,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendEventToBinding(
        const PointerDownEvent(
          pointer: 7,
          kind: PointerDeviceKind.mouse,
          position: Offset(20, 80),
          buttons: kBackMouseButton,
        ),
      );
      await tester.sendEventToBinding(
        const PointerUpEvent(
          pointer: 7,
          kind: PointerDeviceKind.mouse,
          position: Offset(20, 80),
        ),
      );
      expect(clicks, 0);
      expect(backs, 0);
      var built = false;
      Widget latePage() {
        built = true;
        return const Scaffold();
      }

      expect(await retained.to<Object>(latePage), isNull);
      await retained.toReplacement<void>(latePage);
      expect(replaceWithRootPage(retained, (_) => latePage()), isFalse);
      retained.pop();
      App.pop();
      App.rootPop();
      await tester.pump();
      expect(built, isFalse);
      expect(App.rootNavigatorKey.currentState!.canPop(), isTrue);
      expect(exits, 0);
      wait.completeError(StateError('save failed'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isA<StateError>());
      expect(find.text('Closing...'), findsNothing);
      expect(find.text('Unable to close. Please try again.'), findsOneWidget);
      expect(focus.hasPrimaryFocus, isTrue);
      await tester.tap(find.byKey(const Key('content action')));
      expect(clicks, 1);
      retained.pop();
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('keyboard can reach force quit without escaping to content', (
    tester,
  ) async {
    final wait = Completer<void>();
    var exits = 0;
    late WindowFrameController frame;
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => WindowFrame(child!, onExit: () => exits++),
        home: Builder(
          builder: (context) {
            frame = WindowFrame.of(context);
            return const Scaffold();
          },
        ),
      ),
    );
    frame.addExitTask(() => wait.future);
    close(tester);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(exits, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(exits, 1);
    frame.forceExit();
    expect(exits, 1);
    wait.complete();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'writes registered by each exit callback drain before proceeding',
    (tester) async {
      final first = Completer<void>();
      final last = Completer<void>();
      final events = <String>[];
      late WindowFrameController frame;
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) =>
              WindowFrame(child!, onExit: () => events.add('exit')),
          home: Builder(
            builder: (context) {
              frame = WindowFrame.of(context);
              return const Scaffold();
            },
          ),
        ),
      );
      frame.addExitTask(() async {
        events.add('last');
        frame.trackExitTask(last.future);
      });
      frame.addExitTask(() async {
        events.add('first');
        frame.trackExitTask(first.future);
      });
      close(tester);
      await tester.pump();
      expect(events, ['first']);
      first.complete();
      await tester.pump();
      expect(events, ['first', 'last']);
      last.complete();
      await tester.pumpAndSettle();
      expect(events, ['first', 'last', 'exit']);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'failure during another callback is retained and releases holds',
    (tester) async {
      final write = Completer<void>();
      final callback = Completer<void>();
      var exits = 0;
      var nextCalls = 0;
      final releases = <int>[];
      late WindowFrameController frame;
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => WindowFrame(child!, onExit: () => exits++),
          home: Builder(
            builder: (context) {
              frame = WindowFrame.of(context);
              return const Scaffold();
            },
          ),
        ),
      );
      frame.addCloseFailureListener(() => releases.add(1));
      frame.addCloseFailureListener(() => releases.add(2));
      frame.addExitTask(() async {
        nextCalls++;
      });
      Future<void> first() {
        frame.trackExitTask(write.future);
        return callback.future;
      }

      frame.addExitTask(first);
      close(tester);
      await tester.pump();
      write.completeError(StateError('late write failure'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      callback.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isA<StateError>());
      expect(exits, 0);
      expect(nextCalls, 0);
      expect(releases, [2, 1]);
      frame.removeExitTask(first);
      close(tester);
      await tester.pumpAndSettle();
      expect(nextCalls, 1);
      expect(exits, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'callback failure drains registered work before releasing services',
    (tester) async {
      final write = Completer<void>();
      var releases = 0;
      var exits = 0;
      late WindowFrameController frame;
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => WindowFrame(child!, onExit: () => exits++),
          home: Builder(
            builder: (context) {
              frame = WindowFrame.of(context);
              return const Scaffold();
            },
          ),
        ),
      );
      frame.addCloseFailureListener(() => releases++);
      frame.addExitTask(() async {
        frame.trackExitTask(write.future);
        throw StateError('callback failed');
      });
      close(tester);
      await tester.pump();
      expect(releases, 0);
      expect(exits, 0);
      expect(find.text('Closing...'), findsOneWidget);
      expect(tester.takeException(), isNull);
      write.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isA<StateError>());
      expect(releases, 1);
      expect(exits, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('close starts synchronously before existing slow saves drain', (
    tester,
  ) async {
    final pending = Completer<void>();
    final events = <String>[];
    late WindowFrameController frame;
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) =>
            WindowFrame(child!, onExit: () => events.add('exit')),
        home: Builder(
          builder: (context) {
            frame = WindowFrame.of(context);
            return const Scaffold();
          },
        ),
      ),
    );
    var allowClose = false;
    frame.addCloseListener(() => allowClose);
    frame.addCloseStartListener(() => events.add('freeze'));
    frame.addExitTask(() async => events.add('prepare'));
    frame.trackExitTask(pending.future);
    close(tester);
    expect(events, isEmpty);
    allowClose = true;
    close(tester);
    // No pump: owners stop their clocks in the close button's own turn.
    expect(events, ['freeze']);
    close(tester);
    await tester.pump(const Duration(seconds: 3));
    expect(events, ['freeze']);
    expect(find.text('Closing...'), findsOneWidget);
    pending.complete();
    await tester.pumpAndSettle();
    expect(events, ['freeze', 'prepare', 'exit']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'all close starts run after errors, then held work drains before recovery',
    (tester) async {
      final pending = Completer<void>();
      final events = <String>[];
      final firstError = StateError('first freeze failure');
      final secondError = StateError('second freeze failure');
      final reported = <FlutterErrorDetails>[];
      final originalErrorHandler = FlutterError.onError;
      FlutterError.onError = reported.add;
      addTearDown(() => FlutterError.onError = originalErrorHandler);
      late WindowFrameController frame;
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) =>
              WindowFrame(child!, onExit: () => events.add('exit')),
          home: Builder(
            builder: (context) {
              frame = WindowFrame.of(context);
              return const Scaffold();
            },
          ),
        ),
      );
      frame.addCloseStartListener(() {
        events.add('first');
        throw firstError;
      });
      frame.addCloseStartListener(() {
        events.add('second');
        throw secondError;
      });
      frame.addCloseStartListener(() => events.add('third'));
      frame.addCloseFailureListener(() => events.add('release'));
      frame.addExitTask(() async => events.add('prepare'));
      frame.trackExitTask(pending.future);
      close(tester);
      expect(events, ['first', 'second', 'third']);
      await tester.pump(const Duration(seconds: 3));
      expect(events, ['first', 'second', 'third']);
      expect(find.text('Closing...'), findsOneWidget);
      pending.complete();
      await tester.pumpAndSettle();
      expect(events, ['first', 'second', 'third', 'release']);
      expect(
        reported.map((details) => details.exception),
        containsAll([firstError, secondError]),
      );
      expect(reported, hasLength(2));
      expect(find.text('Closing...'), findsNothing);
      expect(find.text('Unable to close. Please try again.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('removed and unmounted close start owners are not notified', (
    tester,
  ) async {
    final attached = ValueNotifier(true);
    addTearDown(attached.dispose);
    final events = <String>[];
    late WindowFrameController frame;
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) =>
            WindowFrame(child!, onExit: () => events.add('exit')),
        home: Builder(
          builder: (context) {
            frame = WindowFrame.of(context);
            return ValueListenableBuilder(
              valueListenable: attached,
              builder: (_, value, _) => value
                  ? _CloseStartOwner(onStart: () => events.add('unmounted'))
                  : const Scaffold(),
            );
          },
        ),
      ),
    );
    void removed() => events.add('removed');
    frame.addCloseStartListener(removed);
    attached.value = false;
    await tester.pump();
    frame.removeCloseStartListener(removed);
    frame.addCloseStartListener(() => events.add('current'));
    close(tester);
    expect(events, ['current']);
    await tester.pumpAndSettle();
    expect(events, ['current', 'exit']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'close start snapshots skip detached owners and defer new owners',
    (tester) async {
      final events = <String>[];
      var changed = false;
      late WindowFrameController frame;
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) =>
              WindowFrame(child!, onExit: () => events.add('exit')),
          home: Builder(
            builder: (context) {
              frame = WindowFrame.of(context);
              return const Scaffold();
            },
          ),
        ),
      );
      void detached() => events.add('detached');
      void added() => events.add('added');
      void failed() => throw StateError('remain open for next close');
      frame.addCloseStartListener(() {
        events.add('first');
        if (changed) return;
        changed = true;
        frame.removeCloseStartListener(detached);
        frame.addCloseStartListener(added);
      });
      frame.addCloseStartListener(detached);
      frame.addCloseStartListener(failed);
      close(tester);
      expect(events, ['first']);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isA<StateError>());
      expect(events, ['first']);
      frame.removeCloseStartListener(failed);
      close(tester);
      expect(events, ['first', 'first', 'added']);
      await tester.pumpAndSettle();
      expect(events, ['first', 'first', 'added', 'exit']);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('guards detached by another guard are skipped', (tester) async {
    final events = <String>[];
    late WindowFrameController frame;
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) =>
            WindowFrame(child!, onExit: () => events.add('exit')),
        home: Builder(
          builder: (context) {
            frame = WindowFrame.of(context);
            return const Scaffold();
          },
        ),
      ),
    );
    bool detached() {
      events.add('detached');
      return false;
    }

    frame.addCloseListener(() {
      frame.removeCloseListener(detached);
      return true;
    });
    frame.addCloseListener(detached);
    frame.addCloseStartListener(() => events.add('start'));
    close(tester);
    expect(events, ['start']);
    await tester.pumpAndSettle();
    expect(events, ['start', 'exit']);
    await tester.pumpWidget(const SizedBox());
  });

  for (final dark in [false, true]) {
    testWidgets(
      'shutdown feedback fits a small window at large text; dark=$dark',
      (tester) async {
        tester.view.physicalSize = const Size(500, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final wait = Completer<void>();
        final preview = GlobalKey();
        late WindowFrameController frame;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: dark ? Brightness.dark : Brightness.light,
              fontFamily:
                  Platform.environment['WINDOW_SHUTDOWN_QA_FONT'] == null
                  ? null
                  : 'WindowShutdownQA',
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(2),
                disableAnimations: dark,
              ),
              child: RepaintBoundary(
                key: preview,
                child: WindowFrame(child!, onExit: () {}),
              ),
            ),
            home: Builder(
              builder: (context) {
                frame = WindowFrame.of(context);
                return const Scaffold(body: SafeArea(child: Text('Library')));
              },
            ),
          ),
        );
        frame.addExitTask(() => wait.future);
        close(tester);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        if (dark) {
          await tester.pump(const Duration(seconds: 1));
          expect(tester.binding.hasScheduledFrame, isFalse);
        }
        expect(find.text('Force Quit'), findsOneWidget);
        expect(tester.takeException(), isNull);
        final directory = Platform.environment['WINDOW_SHUTDOWN_QA_DIRECTORY'];
        if (directory != null) {
          await tester.runAsync(() async {
            final boundary =
                preview.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 1);
            try {
              final data = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                '$directory/shutdown-${dark ? 'dark' : 'light'}.png',
              ).writeAsBytes(data!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }
        wait.complete();
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}

class _CloseStartOwner extends StatefulWidget {
  const _CloseStartOwner({required this.onStart});

  final VoidCallback onStart;

  @override
  State<_CloseStartOwner> createState() => _CloseStartOwnerState();
}

class _CloseStartOwnerState extends State<_CloseStartOwner> {
  WindowFrameController? _frame;

  void _onStart() => widget.onStart();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final frame = WindowFrame.of(context);
    if (identical(frame, _frame)) return;
    _frame?.removeCloseStartListener(_onStart);
    _frame = frame;
    frame.addCloseStartListener(_onStart);
  }

  @override
  void dispose() {
    _frame?.removeCloseStartListener(_onStart);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}
