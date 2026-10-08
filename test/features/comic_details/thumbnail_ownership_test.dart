import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_manager/window_manager.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/comic_details/thumbnails.dart';
import 'package:venera_next/features/comic_source/types.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/network/request_scope.dart';

Widget _preview(ComicThumbnailLoader load, {Key? key}) => Scaffold(
  body: CustomScrollView(
    slivers: [
      ComicThumbnails(
        key: key,
        comicId: 'book',
        sourceKey: 'source',
        initialThumbnails: const [],
        loadComicThumbnail: load,
        readPage: (_) {},
      ),
    ],
  ),
);

void main() {
  const channel = MethodChannel('window_manager');
  setUp(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => false),
  );
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  testWidgets(
    'removed preview remains with its original application until the loader settles',
    (tester) async {
      final registry = SelectionTaskRegistry();
      final pending = Completer<Res<List<String>>>();
      late RequestScope scope;
      await tester.pumpWidget(
        MaterialApp(
          home: SelectionTasksScope(
            registry: registry,
            child: _preview((_, _) {
              scope = RequestScope.current!;
              return pending.future;
            }),
          ),
        ),
      );
      await tester.pumpWidget(const SizedBox());
      var closed = false;
      final closing = registry.closeAndWait().then((_) => closed = true);
      await tester.pump();
      expect(closed, isFalse);
      expect(scope.isCancelled, isTrue);
      pending.completeError(StateError('retired preview'));
      await tester.pump();
      await closing;
      expect(closed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('registry replacement retains both original request owners', (
    tester,
  ) async {
    final oldRegistry = SelectionTaskRegistry(),
        newRegistry = SelectionTaskRegistry();
    final old = Completer<Res<List<String>>>(),
        next = Completer<Res<List<String>>>();
    var calls = 0;
    final child = _preview(
      (_, _) => ++calls == 1 ? old.future : next.future,
      key: GlobalKey(),
    );
    Widget host(SelectionTaskRegistry registry) => MaterialApp(
      home: SelectionTasksScope(registry: registry, child: child),
    );
    await tester.pumpWidget(host(oldRegistry));
    await tester.pumpWidget(host(newRegistry));
    expect(calls, 2);
    var oldClosed = false;
    final closing = oldRegistry.closeAndWait().then((_) => oldClosed = true);
    next.complete(const Res([]));
    await tester.pump();
    await newRegistry.closeAndWait();
    expect(oldClosed, isFalse);
    old.complete(const Res(['retired']));
    await tester.pump();
    await closing;
    expect(find.text('1'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'a native window waits cancelled preview and permits explicit retry after another close failure',
    (tester) async {
      final pending = Completer<Res<List<String>>>();
      var calls = 0, exits = 0;
      var fail = true;
      late WindowFrameController frame;
      Future<void> barrier() async {
        if (fail) throw StateError('other owner');
      }

      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => WindowFrame(child!, onExit: () => exits++),
          home: Builder(
            builder: (context) {
              frame = WindowFrame.of(context);
              frame.addExitTask(barrier);
              return _preview(
                (_, _) =>
                    ++calls == 1 ? pending.future : Future.value(const Res([])),
              );
            },
          ),
        ),
      );
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();
      await tester.pump();
      expect(exits, 0);
      expect(frame.isClosing, isTrue);
      pending.complete(const Res(['stale']));
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isA<StateError>());
      expect(frame.isClosing, isFalse);
      expect(find.text('1'), findsNothing);
      final retry = find.descendant(
        of: find.byType(ComicThumbnails),
        matching: find.text('Retry'),
      );
      expect(retry, findsOneWidget);
      await tester.tap(retry);
      await tester.pump();
      await tester.pump();
      expect(calls, 2);
      fail = false;
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();
      await tester.pump();
      await tester.pump();
      expect(exits, 1);
      expect(calls, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'mounting during a reversible window close defers its first request until recovery',
    (tester) async {
      final visible = ValueNotifier(false);
      final barrier = Completer<void>();
      var calls = 0;
      late WindowFrameController frame;
      final preview = _preview((_, _) async {
        calls++;
        return const Res([]);
      });
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => WindowFrame(child!, onExit: () {}),
          home: Builder(
            builder: (context) {
              frame = WindowFrame.of(context);
              return ValueListenableBuilder<bool>(
                valueListenable: visible,
                builder: (_, show, _) => show ? preview : const SizedBox(),
              );
            },
          ),
        ),
      );
      frame.addExitTask(() => barrier.future);
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();
      await tester.pump();
      visible.value = true;
      await tester.pump();
      expect(calls, 0);
      barrier.completeError(StateError('retry close'));
      await tester.pump();
      expect(tester.takeException(), isA<StateError>());
      await tester.pump();
      await tester.pump();
      expect(calls, 1);
      await tester.pumpWidget(const SizedBox());
      visible.dispose();
    },
  );
  testWidgets(
    'closed application does not start initial or replacement loaders',
    (tester) async {
      final registry = SelectionTaskRegistry();
      await registry.closeAndWait();
      var calls = 0;
      for (var i = 0; i < 2; i++) {
        await tester.pumpWidget(
          MaterialApp(
            home: SelectionTasksScope(
              registry: registry,
              child: _preview((_, _) async {
                calls++;
                return const Res([]);
              }),
            ),
          ),
        );
        await tester.pump();
      }
      expect(calls, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
