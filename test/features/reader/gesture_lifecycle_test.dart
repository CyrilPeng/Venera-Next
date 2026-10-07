import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/gesture.dart';
import 'package:venera_next/features/reader/gesture_port.dart';
import 'package:venera_next/features/reader/gesture_request.dart';
import 'package:venera_next/features/reader/image_favorite_swipe.dart';
import 'package:venera_next/features/reader/reader_tap_scope.dart';
import 'package:venera_next/features/reader/reader_viewport.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/reader_settings.dart';

class _Viewport implements ReaderImageViewController {
  final calls = <String>[];
  Future<Uint8List?> Function()? read;
  @override
  bool handleOnTap(Offset point) {
    calls.add('tap');
    return false;
  }

  @override
  void handleDoubleTap(Offset point) {
    calls.add('double');
  }

  @override
  void handleLongPressDown(Offset point) {
    calls.add('zoom start');
  }

  @override
  void handleLongPressUp(Offset point) {
    calls.add('zoom end');
  }

  @override
  Future<Uint8List?> getImageByOffset(Offset point) async {
    calls.add('read');
    return read == null ? Uint8List(0) : await read!();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Fixture {
  final work = ImageWork();
  final changes = ValueNotifier(0);
  final key = GlobalKey<ReaderGestureDetectorState>();
  final calls = <String>[];
  final pauses = <Object>{};
  var identity = Object();
  var viewport = _Viewport();
  var menu = false,
      doubleTap = true,
      vertical = false,
      reverse = false,
      reverseTap = false;
  var longPress = 'zoom';
  ReaderGesturePort? port;
  ReaderGestureRequest request() {
    final original = identity;
    return ReaderGestureRequest(
      identity: original,
      isCurrent: () => identical(identity, original),
      viewport: viewport,
      preferences: ReaderSettings.resolve(
        global: {
          'enableDoubleTapToZoom': doubleTap,
          'enableTapToTurnPages': true,
          'reverseTapToTurnPages': reverseTap,
          'longPressAction': longPress,
        },
      ),
      vertical: vertical,
      reversed: reverse,
      onCommentsPage: false,
      canUseImage: true,
      turnPage: (forward) => calls.add(forward ? 'next' : 'previous'),
      turnWheel: (forward) =>
          calls.add(forward ? 'wheel next' : 'wheel previous'),
      toggleAutomaticReading: () => calls.add('auto'),
      stopAutomaticReading: () => calls.add('stop'),
      acquirePause: () {
        final reason = Object();
        pauses.add(reason);
        return () {
          pauses.remove(reason);
        };
      },
      fullscreen: () => calls.add('fullscreen'),
      exit: () async => calls.add('exit'),
    );
  }

  void attach(ReaderGesturePort value, bool attached) {
    if (attached) {
      port = value;
    } else if (identical(port, value)) {
      port = null;
    }
  }

  void replace({bool notify = true}) {
    identity = Object();
    viewport = _Viewport();
    if (notify) changes.value++;
  }

  Future<void> mount(WidgetTester tester, {Widget? child}) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.only(left: 100, top: 100),
          child: SizedBox(
            width: 400,
            height: 400,
            child: ReaderGestureDetector(
              key: key,
              imageWork: work,
              changes: changes,
              createRequest: request,
              onPortChanged: attach,
              isMenuOpen: () => menu,
              toggleMenu: () {
                menu = !menu;
                calls.add('menu');
              },
              openSettings: () => calls.add('settings'),
              openChapters: () => calls.add('chapters'),
              child: child ?? const ColoredBox(color: Colors.blue),
            ),
          ),
        ),
      ),
    ),
  );
  Offset center(WidgetTester tester) =>
      tester.getCenter(find.byType(ReaderGestureDetector));
  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await work.dispose();
    changes.dispose();
  }
}

void main() {
  testWidgets('accepted menu image read drains after its owner is removed', (
    tester,
  ) async {
    final f = _Fixture();
    final reading = Completer<Uint8List?>();
    f.viewport.read = () => reading.future;
    final original = f.viewport;
    await f.mount(tester);
    await tester.tapAt(f.center(tester), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save Image'));
    await tester.pumpAndSettle();
    expect(original.calls, ['read']);
    await tester.pumpWidget(const SizedBox());
    var closed = false;
    final closing = f.work.dispose().then((_) => closed = true);
    await tester.pump();
    expect(closed, isFalse);
    reading.complete(Uint8List.fromList([1, 2, 3]));
    await tester.pump();
    await closing;
    expect(closed, isTrue);
    expect(tester.takeException(), isNull);
    await f.dispose(tester);
  });
  testWidgets(
    'single and double taps preserve the wait and original viewport',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      await tester.tapAt(f.center(tester));
      await tester.pump(const Duration(milliseconds: 199));
      expect(f.calls, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(f.calls, ['menu']);
      f.calls.clear();
      f.viewport.calls.clear();
      await tester.tapAt(f.center(tester));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(f.center(tester));
      await tester.pump(const Duration(milliseconds: 300));
      expect(f.viewport.calls, ['double']);
      expect(f.calls, isEmpty);
      await f.dispose(tester);
    },
  );

  testWidgets('separated taps are two single actions', (tester) async {
    final f = _Fixture();
    await f.mount(tester);
    await tester.tapAt(f.center(tester) - const Offset(30, 0));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(f.center(tester) + const Offset(30, 0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(f.viewport.calls, ['tap', 'tap']);
    expect(f.calls, ['menu', 'menu']);
    await f.dispose(tester);
  });

  testWidgets('tap regions use local coordinates in an offset reader', (
    tester,
  ) async {
    final f = _Fixture()..doubleTap = false;
    await f.mount(tester);
    await tester.tapAt(f.center(tester));
    expect(f.calls, ['menu']);
    f.menu = false;
    f.calls.clear();
    await tester.tapAt(f.center(tester) + const Offset(170, 0));
    expect(f.calls, ['next']);
    await f.dispose(tester);
  });

  for (final vertical in [false, true]) {
    for (final reversed in [false, true]) {
      testWidgets(
        'tap policy preserves direction; vertical=$vertical reverse=$reversed',
        (tester) async {
          final f = _Fixture()
            ..doubleTap = false
            ..vertical = vertical
            ..reverse = !vertical && reversed
            ..reverseTap = vertical && reversed;
          await f.mount(tester);
          await tester.tapAt(
            f.center(tester) +
                (vertical ? const Offset(0, 170) : const Offset(170, 0)),
          );
          expect(f.calls, [reversed ? 'previous' : 'next']);
          await f.dispose(tester);
        },
      );
    }
  }

  testWidgets(
    'expired target rejects long press and releases pause without a rebuild',
    (tester) async {
      final f = _Fixture()..longPress = 'autoReading';
      await f.mount(tester);
      final pointer = await tester.startGesture(f.center(tester));
      expect(f.pauses, hasLength(1));
      f.replace(notify: false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(f.calls, isEmpty);
      expect(f.pauses, isEmpty);
      await pointer.up();
      await f.dispose(tester);
    },
  );

  for (final remove in [false, true]) {
    testWidgets(
      'zoom release belongs to its original viewport; remove=$remove',
      (tester) async {
        final f = _Fixture();
        await f.mount(tester);
        final original = f.viewport;
        final pointer = await tester.startGesture(f.center(tester));
        await tester.pump(const Duration(milliseconds: 300));
        expect(original.calls, ['zoom start']);
        if (remove) {
          await tester.pumpWidget(const SizedBox());
        } else {
          f.replace();
        }
        expect(original.calls, ['zoom start', 'zoom end']);
        expect(f.pauses, isEmpty);
        await pointer.up();
        await tester.pump(const Duration(milliseconds: 300));
        expect(original.calls, ['zoom start', 'zoom end']);
        if (!remove) expect(f.viewport.calls, isEmpty);
        await f.dispose(tester);
      },
    );
  }

  testWidgets('two pointers retain one independent pause until both finish', (
    tester,
  ) async {
    final f = _Fixture();
    await f.mount(tester);
    final external = Object();
    f.pauses.add(external);
    final first = await tester.startGesture(f.center(tester), pointer: 10);
    final second = await tester.startGesture(
      f.center(tester) + const Offset(30, 0),
      pointer: 11,
    );
    expect(f.pauses, hasLength(2));
    await first.up();
    expect(f.pauses, hasLength(2));
    await second.cancel();
    expect(f.pauses, [external]);
    await tester.pump(const Duration(milliseconds: 300));
    expect(f.viewport.calls, isEmpty);
    await f.dispose(tester);
  });

  testWidgets(
    'cancelled collection drag never collects and the next drag starts empty',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      var collected = 0;
      final swipe = ImageFavoriteSwipeBinding(
        isVertical: () => false,
        collect: () => collected++,
      );
      swipe.attach(f.port);
      swipe.setEnabled(true);
      final first = await tester.startGesture(
        f.center(tester) - const Offset(0, 100),
      );
      await first.moveBy(const Offset(0, 170));
      await tester.pump(const Duration(milliseconds: 300));
      await first.cancel();
      expect(collected, 0);
      final second = await tester.startGesture(
        f.center(tester) - const Offset(0, 100),
      );
      await second.moveBy(const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 300));
      await second.up();
      expect(collected, 0);
      final third = await tester.startGesture(
        f.center(tester) - const Offset(0, 100),
      );
      await third.moveBy(const Offset(0, 170));
      await tester.pump(const Duration(milliseconds: 300));
      await third.up();
      expect(collected, 1);
      swipe.dispose();
      await f.dispose(tester);
    },
  );

  testWidgets('drag callbacks may remove themselves or retire their target', (
    tester,
  ) async {
    final f = _Fixture();
    await f.mount(tester);
    final calls = <String>[];
    late ReaderDragListener listener;
    listener = ReaderDragListener(
      onStart: (_) {
        calls.add('start');
        f.replace();
      },
      onMove: (_) => calls.add('move'),
      onCancel: () => calls.add('cancel'),
      onEnd: () => calls.add('end'),
    );
    f.port!.addDragListener(listener);
    final pointer = await tester.startGesture(f.center(tester));
    await pointer.moveBy(const Offset(0, 30));
    await tester.pump(const Duration(milliseconds: 300));
    await pointer.up();
    expect(calls, ['start', 'cancel']);
    await f.dispose(tester);
  });

  testWidgets(
    'retry suppression consumes the original pointer and clears a pending tap',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      await tester.tapAt(f.center(tester));
      f.port!.ignoreNextTap();
      await tester.pump(const Duration(milliseconds: 300));
      expect(f.calls, isEmpty);
      await f.mount(
        tester,
        child: Builder(
          builder: (context) => Listener(
            onPointerDown: (_) =>
                ReaderTapScope.maybeOf(context)!.ignoreNextTap(),
            child: const ColoredBox(color: Colors.blue),
          ),
        ),
      );
      await tester.tapAt(f.center(tester));
      await tester.pump(const Duration(milliseconds: 300));
      expect(f.calls, isEmpty);
      expect(f.pauses, isEmpty);
      await f.dispose(tester);
    },
  );

  testWidgets('old context menu actions cannot act on a replacement target', (
    tester,
  ) async {
    final f = _Fixture();
    await f.mount(tester);
    await tester.tapAt(f.center(tester), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    f.replace();
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsNothing);
    expect(f.calls, isEmpty);
    await f.dispose(tester);
  });

  testWidgets(
    'current context menu still opens settings after its route pops',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      await tester.tapAt(f.center(tester), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(f.calls, ['settings']);
      await f.dispose(tester);
    },
  );

  testWidgets(
    'pointer scroll stops automatic reading and preserves control zoom',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      tester.binding.handlePointerEvent(
        PointerScrollEvent(
          position: f.center(tester),
          scrollDelta: const Offset(0, 20),
        ),
      );
      expect(f.calls, ['stop']);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      tester.binding.handlePointerEvent(
        PointerScrollEvent(
          position: f.center(tester),
          scrollDelta: const Offset(0, -20),
        ),
      );
      expect(f.calls, ['stop', 'stop', 'wheel previous']);
      await f.dispose(tester);
    },
  );

  testWidgets('a failing drag completion still releases its pointer pause', (
    tester,
  ) async {
    final f = _Fixture();
    await f.mount(tester);
    f.port!.addDragListener(
      ReaderDragListener(onEnd: () => throw StateError('drag callback')),
    );
    final pointer = await tester.startGesture(f.center(tester));
    await pointer.moveBy(const Offset(0, 30));
    await tester.pump(const Duration(milliseconds: 300));
    await pointer.up();
    expect(tester.takeException(), isA<StateError>());
    expect(f.pauses, isEmpty);
    await f.dispose(tester);
  });
}
